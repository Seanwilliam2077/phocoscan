import Foundation
import simd

/// Crops a 3DGS to the object or person anchored while scanning (the plan's "背景裁剪 / 只保留人物和
/// 脚下一小块地面"). A result's cameras (`cameras.json`, in the model's own frame and scale) and the
/// phone's ARKit poses (`frames.jsonl`, metres) describe the same video frames, so a similarity
/// transform fitted between their camera centres maps the anchor into the model. Nothing is cropped
/// when too few frames match or the fit is poor: the crop is a view option, never a claim of accuracy.
struct SplatCrop: Equatable, Sendable {
    /// Region to keep, in ARKit world coordinates (gravity-aligned, metres).
    enum Region: Equatable, Sendable {
        /// An object and a margin of the surface it stands on.
        case box(center: SIMD3<Float>, halfExtents: SIMD3<Float>, yaw: Float)
        /// A standing person and the floor under their feet.
        case cylinder(axis: SIMD2<Float>, radius: Float, bottom: Float, top: Float)
    }

    let region: Region
    /// model = scale · rotation · arkit + translation
    let rotation: simd_float3x3
    let scale: Float
    let translation: SIMD3<Float>
    /// RMS alignment residual in metres (camera centres and points at the subject's distance).
    let fitError: Float
    let matchedCameras: Int

    /// One camera of either source: video time, centre and viewing direction.
    struct Pose: Sendable {
        let time: Double
        let center: SIMD3<Float>
        let forward: SIMD3<Float>
    }

    /// Near-transparent splats add haze around the subject; they are dropped with the background.
    static let minOpacity: Float = 0.02
    static let emptyMessage = "裁剪后没有剩下的高斯点，已改为显示全景。"
    static let minMatches = 4
    static let maxCentreDisagreement: Float = 0.5

    func toARKit(_ model: SIMD3<Float>) -> SIMD3<Float> {
        rotation.transpose * (model - translation) / scale
    }

    func keeps(position: SIMD3<Float>, opacity: Float) -> Bool {
        opacity >= Self.minOpacity && contains(arkit: toARKit(position))
    }

    func contains(arkit p: SIMD3<Float>) -> Bool {
        switch region {
        case let .box(center, half, yaw):
            let d = p - center
            let c = cos(-yaw), s = sin(-yaw)
            let local = SIMD3(c * d.x + s * d.z, d.y, -s * d.x + c * d.z)
            return abs(local.x) <= half.x && abs(local.y) <= half.y && abs(local.z) <= half.z
        case let .cylinder(axis, radius, bottom, top):
            return p.y >= bottom && p.y <= top && simd_length(SIMD2(p.x, p.z) - axis) <= radius
        }
    }

    /// The region kept for an anchored target: the object box widened by a third (plus 5 cm) with
    /// a little of the ground under it; a 55 cm column around a person from just under the floor
    /// to 15 cm above the head.
    static func region(for target: ScanTargetBox) -> Region {
        let base = target.baseCenter, size = target.simdSize
        if target.isPerson {
            return .cylinder(axis: SIMD2(target.center[0], target.center[2]), radius: 0.55,
                             bottom: base.y - 0.04, top: base.y + size.y + 0.15)
        }
        let half = SIMD3(size.x * 0.65 + 0.05, size.y * 0.6 + 0.04, size.z * 0.65 + 0.05)
        // Bottom 4 cm below the base keeps the contact with the table or floor.
        let bottom = base.y - 0.04, top = base.y + size.y * 1.15 + 0.04
        return .box(center: SIMD3(base.x, (bottom + top) / 2, base.z),
                    halfExtents: SIMD3(half.x, (top - bottom) / 2, half.z), yaw: target.yawRadians)
    }

    /// The alignment must be well inside the region's margin: 15 cm around a person; for an
    /// object a third of its smallest horizontal half-width, at least 4 cm.
    static func tolerance(for region: Region) -> Float {
        switch region {
        case .cylinder: return 0.15
        case let .box(_, half, _): return max(0.04, min(half.x, half.z) / 3)
        }
    }

    /// Pairs result cameras with ARKit cameras by video time (±3 ms) and fits a similarity to the
    /// camera centres plus one point ahead of each camera at the subject's distance; the second
    /// set fixes the rotation even when the phone moved only a little.
    static func make(target: ScanTargetBox, cameras: [Pose], arkit: [Pose]) -> SplatCrop? {
        let sorted = arkit.sorted { $0.time < $1.time }
        var pairs: [(arkit: Pose, model: Pose)] = []
        for camera in cameras {
            var low = 0, high = sorted.count - 1, best: Int?
            while low <= high {
                let middle = (low + high) / 2
                if best == nil || abs(sorted[middle].time - camera.time) < abs(sorted[best!].time - camera.time) { best = middle }
                if sorted[middle].time < camera.time { low = middle + 1 } else { high = middle - 1 }
            }
            if let best, abs(sorted[best].time - camera.time) <= 0.003 { pairs.append((sorted[best], camera)) }
        }
        guard pairs.count >= minMatches else { return nil }
        let a = pairs.map(\.arkit.center), b = pairs.map(\.model.center)
        let ma = a.reduce(.zero, +) / Float(a.count), mb = b.reduce(.zero, +) / Float(b.count)
        let spreadA = a.reduce(0) { $0 + simd_length_squared($1 - ma) }, spreadB = b.reduce(0) { $0 + simd_length_squared($1 - mb) }
        guard spreadA > 1e-8, spreadB > 0 else { return nil }
        let roughScale = sqrt(spreadB / spreadA)
        let distances = a.map { simd_length($0 - target.simdCenter) }.sorted()
        let depth = min(3, max(0.3, distances[distances.count / 2]))
        let from = a + pairs.map { $0.arkit.center + depth * $0.arkit.forward }
        let to = b + pairs.map { $0.model.center + roughScale * depth * $0.model.forward }
        guard let fit = fitSimilarity(from: from, to: to) else { return nil }
        // Under that fit the camera centres must roughly agree too, measured against the result
        // cameras' own spread (real results: 0.2–0.35), so noise cannot hide behind a large scale.
        let centreResidual = zip(a, b).reduce(Float(0)) {
            $0 + simd_length_squared(fit.scale * (fit.rotation * $1.0) + fit.translation - $1.1)
        }
        guard sqrt(centreResidual / spreadB) <= maxCentreDisagreement else { return nil }
        let residual = sqrt(zip(from, to).reduce(Float(0)) {
            $0 + simd_length_squared(fit.scale * (fit.rotation * $1.0) + fit.translation - $1.1)
        } / Float(from.count)) / fit.scale
        let region = region(for: target)
        guard residual.isFinite, residual <= tolerance(for: region) else { return nil }
        return SplatCrop(region: region, rotation: fit.rotation, scale: fit.scale,
                         translation: fit.translation, fitError: residual, matchedCameras: pairs.count)
    }

    /// Least-squares similarity `to ≈ s·R·from + t` (Horn's quaternion method: always a proper
    /// rotation). Nil when the points are too close to a line to fix the rotation.
    static func fitSimilarity(from: [SIMD3<Float>], to: [SIMD3<Float>])
        -> (rotation: simd_float3x3, scale: Float, translation: SIMD3<Float>, error: Float)? {
        guard from.count == to.count, from.count >= 3 else { return nil }
        let a = from.map { SIMD3<Double>($0) }, b = to.map { SIMD3<Double>($0) }
        let n = Double(a.count)
        let ma = a.reduce(.zero, +) / n, mb = b.reduce(.zero, +) / n
        let ca = a.map { $0 - ma }, cb = b.map { $0 - mb }
        var spreadA = 0.0
        var covariance = [[Double]](repeating: [0, 0, 0], count: 3), shape = covariance
        for (x, y) in zip(ca, cb) {
            spreadA += simd_length_squared(x)
            for i in 0..<3 { for j in 0..<3 { covariance[i][j] += x[i] * y[j]; shape[i][j] += x[i] * x[j] } }
        }
        guard spreadA > 1e-9 else { return nil }
        // Points along one line leave the rotation about that line undetermined.
        let extents = symmetricEigen(shape).values.sorted(by: >)
        guard extents.count == 3, extents[1] > extents[0] * 1e-3 else { return nil }
        let s = covariance
        let horn: [[Double]] = [
            [s[0][0] + s[1][1] + s[2][2], s[1][2] - s[2][1], s[2][0] - s[0][2], s[0][1] - s[1][0]],
            [s[1][2] - s[2][1], s[0][0] - s[1][1] - s[2][2], s[0][1] + s[1][0], s[2][0] + s[0][2]],
            [s[2][0] - s[0][2], s[0][1] + s[1][0], -s[0][0] + s[1][1] - s[2][2], s[1][2] + s[2][1]],
            [s[0][1] - s[1][0], s[2][0] + s[0][2], s[1][2] + s[2][1], -s[0][0] - s[1][1] + s[2][2]],
        ]
        let eigen = symmetricEigen(horn)
        guard let top = eigen.values.indices.max(by: { eigen.values[$0] < eigen.values[$1] }) else { return nil }
        let q = eigen.vectors[top]
        let quaternion = simd_quatd(ix: q[1], iy: q[2], iz: q[3], r: q[0]).normalized
        let rotation = simd_double3x3(quaternion)
        let scale = zip(ca, cb).reduce(0.0) { $0 + simd_dot($1.1, rotation * $1.0) } / spreadA
        guard scale.isFinite, scale > 1e-9 else { return nil }
        let translation = mb - scale * (rotation * ma)
        let residual = zip(a, b).reduce(0.0) { $0 + simd_length_squared(scale * (rotation * $1.0) + translation - $1.1) }
        // Relative to the target points' own spread, so a wrongly inflated scale cannot hide it.
        let spreadB = cb.reduce(0.0) { $0 + simd_length_squared($1) }
        guard spreadB > 1e-18 else { return nil }
        let error = sqrt(residual / spreadB)
        let r = simd_float3x3(SIMD3<Float>(rotation.columns.0), SIMD3<Float>(rotation.columns.1), SIMD3<Float>(rotation.columns.2))
        return (r, Float(scale), SIMD3<Float>(translation), Float(error))
    }

    /// Cyclic Jacobi for a small symmetric matrix: eigenvalues and (row) eigenvectors.
    static func symmetricEigen(_ input: [[Double]]) -> (values: [Double], vectors: [[Double]]) {
        let n = input.count
        var a = input
        var v = (0..<n).map { i in (0..<n).map { $0 == i ? 1.0 : 0.0 } }
        for _ in 0..<50 {
            var off = 0.0
            for i in 0..<n { for j in (i + 1)..<n { off += a[i][j] * a[i][j] } }
            if off < 1e-20 { break }
            for p in 0..<n {
                for q in (p + 1)..<n where abs(a[p][q]) > 1e-300 {
                    let theta = (a[q][q] - a[p][p]) / (2 * a[p][q])
                    let t = (theta >= 0 ? 1.0 : -1.0) / (abs(theta) + sqrt(theta * theta + 1))
                    let c = 1 / sqrt(t * t + 1), s = t * c
                    for k in 0..<n {
                        let akp = a[k][p], akq = a[k][q]
                        a[k][p] = c * akp - s * akq; a[k][q] = s * akp + c * akq
                    }
                    for k in 0..<n {
                        let apk = a[p][k], aqk = a[q][k]
                        a[p][k] = c * apk - s * aqk; a[q][k] = s * apk + c * aqk
                    }
                    for k in 0..<n {
                        let vkp = v[k][p], vkq = v[k][q]
                        v[k][p] = c * vkp - s * vkq; v[k][q] = s * vkp + c * vkq
                    }
                }
            }
        }
        return ((0..<n).map { a[$0][$0] }, (0..<n).map { column in (0..<n).map { v[$0][column] } })
    }

    // MARK: Loading from a scan

    private struct ARKitFrame: Decodable {
        let videoPTSSeconds: Double
        let cameraToWorldARKit: [[Float]]
        let trackingState: String
    }

    /// The crop for a result of the scan in `scanFolder`, or nil (no anchor, older scan, poor fit).
    static func load(scanFolder: URL, cameraPath: SceneCameraPath) -> SplatCrop? {
        guard let target = ScanAnalysis.load(from: scanFolder)?.targetBox,
              let data = try? Data(contentsOf: scanFolder.appendingPathComponent("frames.jsonl")) else { return nil }
        let decoder = JSONDecoder()
        // Both sources use camera-to-world with the camera looking down -Z (ARKit / OpenGL).
        let arkit: [Pose] = data.split(separator: 0x0a).compactMap { line in
            guard let frame = try? decoder.decode(ARKitFrame.self, from: Data(line)), frame.trackingState == "normal",
                  frame.cameraToWorldARKit.count == 4, frame.cameraToWorldARKit.allSatisfy({ $0.count == 4 }) else { return nil }
            let m = frame.cameraToWorldARKit
            return Pose(time: frame.videoPTSSeconds, center: SIMD3(m[0][3], m[1][3], m[2][3]),
                        forward: -simd_normalize(SIMD3(m[0][2], m[1][2], m[2][2])))
        }
        let cameras: [Pose] = cameraPath.frames.map { frame in
            let m = frame.cameraToWorld.map { Float($0) }
            return Pose(time: frame.timeSeconds, center: SIMD3(m[3], m[7], m[11]),
                        forward: -simd_normalize(SIMD3(m[2], m[6], m[10])))
        }
        return make(target: target, cameras: cameras, arkit: arkit)
    }
}

extension SplatCrop {
    /// Presentation only: preserve file coordinates/SH while making recorded gravity upright.
    /// The capture-camera travel radius is not the subject radius, especially for short arcs.
    struct Orbit: Equatable, Sendable {
        let target: SIMD3<Float>
        let radius: Float
        let modelToUpright: simd_float3x3
        let backward: SIMD3<Float>
        func yaw(flipped: Bool) -> Float { -atan2(flipped ? -backward.x : backward.x, backward.z) }
        func pitch(flipped: Bool) -> Float { asin(min(1, max(-1, flipped ? -backward.y : backward.y))) }
        func distance(aspect: Float) -> Float {
            let halfAngle = min(Float.pi / 6, atan(tan(Float.pi / 6) * max(0.01, aspect)))
            return radius / sin(halfAngle) * 1.15
        }
        func gravityFrames(_ path: SceneCameraPath) -> [SceneCameraFrame] {
            path.frames.map { frame in
                let m = frame.cameraToWorld
                let rows = (0..<4).map { r in SIMD4<Float>((0..<4).map { Float(m[r*4+$0]) }) }
                var align = matrix_identity_float4x4
                for i in 0..<3 { align[i] = SIMD4(modelToUpright[i], 0) }
                let pose = align * simd_float4x4(rows: rows)
                return SceneCameraFrame(sourceFrame: frame.sourceFrame, timeSeconds: frame.timeSeconds,
                    width: frame.width, height: frame.height, fx: frame.fx, fy: frame.fy, cx: frame.cx, cy: frame.cy,
                    cameraToWorld: (0..<4).flatMap { r in (0..<4).map { Double(pose[$0][r]) } }, segmentId: frame.segmentId)
            }
        }
    }
    func orbit(firstCamera: simd_float4x4) -> Orbit? {
        let center: SIMD3<Float>, radius: Float
        switch region {
        case let .box(c, half, _): center = c; radius = simd_length(half)
        case let .cylinder(axis, r, bottom, top):
            center = SIMD3(axis.x, (bottom+top)/2, axis.y)
            radius = sqrt(r*r + pow((top-bottom)/2, 2))
        }
        let target = scale * (rotation * center) + translation
        let camera = SIMD3(firstCamera.columns.3.x, firstCamera.columns.3.y, firstCamera.columns.3.z)
        let delta = rotation.transpose * (camera-target)
        guard scale > 0, radius > 0, simd_length(delta) > 1e-5 else { return nil }
        return Orbit(target: target, radius: scale*radius, modelToUpright: rotation.transpose,
                     backward: simd_normalize(delta))
    }
}
