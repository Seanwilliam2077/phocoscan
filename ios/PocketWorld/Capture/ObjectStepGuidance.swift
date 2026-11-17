import simd

/// One suggested camera position in the capture's ARKit world. It is not a route,
/// an obstacle-free location, or a claim that unseen surfaces were captured.
struct SubjectStepGuidance: Equatable {
    enum Motion { case left, right, up, down, forward, backward, hold }
    let position: SIMD3<Float>
    let motion: Motion
    let arrived: Bool
}

/// Short, straight steps chosen from actual saved viewing directions, not 10° bins.
/// A waypoint stays fixed until a usable JPEG is saved there or the user moves away.
struct SubjectStepPlanner {
    private var center: SIMD3<Float>?
    private var savedDirections: [SIMD3<Float>] = []
    private var waypoint: SIMD3<Float>?
    private var waypointTime: Double = 0
    private var origin: SIMD3<Float>?
    private var lastPosition: SIMD3<Float>?
    private var tolerance: Float = 0.04

    mutating func suspend() {
        waypoint = nil; origin = nil; lastPosition = nil
    }

    func needsSavedView(transform: simd_float4x4) -> Bool {
        guard let waypoint, Self.valid(transform) else { return false }
        return simd_distance(Self.position(transform), waypoint) <= tolerance
    }

    mutating func recordSaved(transform: simd_float4x4, target: ScanTargetBox, timestamp: Double) {
        guard Self.valid(transform), Self.finite(target.simdCenter), timestamp.isFinite else { return }
        setTarget(target.simdCenter)
        let camera = Self.position(transform), ray = camera - target.simdCenter
        guard simd_length(ray) > 0.12, Self.facesTarget(transform, target) else { return }
        let direction = simd_normalize(ray)
        if savedDirections.last.map({ simd_dot($0, direction) < 0.9999 }) ?? true {
            savedDirections.append(direction)
            if savedDirections.count > 256 { savedDirections.removeFirst() }
        }
        if let waypoint, timestamp >= waypointTime, simd_distance(camera, waypoint) <= tolerance {
            self.waypoint = nil
            origin = nil
        }
    }

    mutating func update(transform: simd_float4x4, target: ScanTargetBox, timestamp: Double,
                         trackingNormal: Bool = true) -> SubjectStepGuidance? {
        guard trackingNormal, Self.valid(transform), Self.finite(target.simdCenter), timestamp.isFinite else {
            suspend(); return nil
        }
        setTarget(target.simdCenter)
        let camera = Self.position(transform)
        if let lastPosition, simd_distance(camera, lastPosition) > 0.6 {
            suspend(); self.lastPosition = camera; return nil
        }
        lastPosition = camera
        guard Self.facesTarget(transform, target) else { return nil }
        let radial = camera - target.simdCenter
        let flat = SIMD3(radial.x, 0, radial.z)
        guard simd_length(flat) > 0.12 else { suspend(); return nil }
        // First record the current view before asking for parallax.
        guard !savedDirections.isEmpty else {
            return SubjectStepGuidance(position: camera, motion: .hold, arrived: true)
        }
        let step = min(0.28, max(0.08, simd_length(radial) * 0.18))
        // Respect a different path chosen by the user; do not pull them back to an old point.
        if let origin, simd_distance(camera, origin) > max(0.35, step * 2) { waypoint = nil }
        if waypoint == nil {
            let tangent = simd_normalize(SIMD3(flat.z, 0, -flat.x))
            let offsets = [tangent * step, -tangent * step, SIMD3<Float>(0, step * 0.85, 0), SIMD3<Float>(0, -step * 0.85, 0)]
            var best: (point: SIMD3<Float>, score: Float)?
            for (index, offset) in offsets.enumerated() {
                let candidate = camera + offset
                guard candidate.y > target.baseCenter.y + 0.05, candidate.y < target.baseCenter.y + max(1.0, target.simdSize.y + 0.35) else { continue }
                let direction = simd_normalize(candidate - target.simdCenter)
                let novelty = savedDirections.map { 1 - simd_dot($0, direction) }.min() ?? 0
                // Stable tie break only; no forced full orbit or prescribed radius.
                let score = novelty + Float(4 - index) * 0.00001
                if best == nil || score > best!.score { best = (candidate, score) }
            }
            guard let best else { return nil }
            waypoint = best.point; origin = camera; waypointTime = timestamp
            tolerance = min(0.065, max(0.025, step * 0.25))
        }
        guard let waypoint else { return nil }
        let arrived = simd_distance(camera, waypoint) <= tolerance
        return SubjectStepGuidance(position: waypoint,
                                  motion: arrived ? .hold : Self.motion(to: waypoint, from: transform), arrived: arrived)
    }

    private mutating func setTarget(_ target: SIMD3<Float>) {
        if center != target { self = SubjectStepPlanner(); center = target }
    }
    private static func position(_ m: simd_float4x4) -> SIMD3<Float> { SIMD3(m.columns.3.x, m.columns.3.y, m.columns.3.z) }
    private static func finite(_ v: SIMD3<Float>) -> Bool { v.x.isFinite && v.y.isFinite && v.z.isFinite }
    private static func valid(_ m: simd_float4x4) -> Bool {
        (0..<4).allSatisfy { c in (0..<4).allSatisfy { m[c][$0].isFinite } }
            && simd_length(SIMD3(m.columns.0.x, m.columns.0.y, m.columns.0.z)) > 0.9
            && simd_length(SIMD3(m.columns.2.x, m.columns.2.y, m.columns.2.z)) > 0.9
    }
    private static func facesTarget(_ m: simd_float4x4, _ target: ScanTargetBox) -> Bool {
        let center = target.simdCenter
        if let axis = target.bodyAxis {
            return (0...4).contains { i in
                facesPoint(m, SIMD3(center.x, axis.lowerBound + Float(i) / 4 * (axis.upperBound - axis.lowerBound), center.z))
            }
        }
        return facesPoint(m, center)
    }
    private static func facesPoint(_ m: simd_float4x4, _ target: SIMD3<Float>) -> Bool {
        let toTarget = target - position(m)
        guard simd_length(toTarget) > 0.12 else { return false }
        let forward = -SIMD3(m.columns.2.x, m.columns.2.y, m.columns.2.z)
        return simd_dot(simd_normalize(toTarget), simd_normalize(forward)) > cos(32 * Float.pi / 180)
    }
    static func motion(to point: SIMD3<Float>, from camera: simd_float4x4) -> SubjectStepGuidance.Motion {
        let delta = point - position(camera)
        // ARKit image axes rotate with the phone. Walking directions stay gravity-aligned.
        let backward = SIMD3(camera.columns.2.x, 0, camera.columns.2.z)
        guard simd_length(backward) > 0.01 else { return delta.y >= 0 ? .up : .down }
        let back = simd_normalize(backward)
        let right = simd_cross(SIMD3<Float>(0, 1, 0), back)
        let x = simd_dot(delta, right), y = delta.y, z = simd_dot(delta, -back)
        if abs(x) >= max(abs(y), abs(z)) { return x >= 0 ? .right : .left }
        if abs(y) >= abs(z) { return y >= 0 ? .up : .down }
        return z >= 0 ? .forward : .backward
    }
}
