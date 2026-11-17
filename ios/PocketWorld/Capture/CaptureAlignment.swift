import CoreGraphics
import simd

/// Consecutive camera samples, including roll. A clock gap never counts as stability.
struct CaptureMotion {
    private var previous: (time: Double, pose: simd_float4x4)?
    private(set) var speed: Float?
    private(set) var turn: Float?
    var steady: Bool { allows(speed: 0.18, turn: 0.35) }
    func allows(speed maxSpeed: Float, turn maxTurn: Float) -> Bool {
        guard let speed, let turn else { return false }
        return speed <= maxSpeed && turn <= maxTurn
    }
    mutating func update(pose: simd_float4x4, timestamp: Double) {
        speed = nil; turn = nil
        guard timestamp.isFinite, Self.valid(pose) else { previous = nil; return }
        defer { previous = (timestamp, pose) }
        guard let previous else { return }
        let dt = timestamp - previous.time
        guard dt > 0, dt <= 0.3 else { return }
        let delta = pose.columns.3 - previous.pose.columns.3
        speed = simd_length(SIMD3(delta.x, delta.y, delta.z)) / Float(dt)
        let rotation = simd_quatf(pose) * simd_quatf(previous.pose).inverse
        turn = 2 * atan2(simd_length(rotation.imag), abs(rotation.real)) / Float(dt)
    }
    static func valid(_ pose: simd_float4x4) -> Bool {
        guard (0..<4).allSatisfy({ c in (0..<4).allSatisfy { pose[c][$0].isFinite } }) else { return false }
        let r = simd_float3x3((0..<3).map { SIMD3(pose[$0].x, pose[$0].y, pose[$0].z) })
        return (0..<3).allSatisfy { abs(simd_length(r[$0]) - 1) < 0.01 }
            && abs(simd_determinant(r) - 1) < 0.01
            && abs(pose[0].w) + abs(pose[1].w) + abs(pose[2].w) < 0.001
            && abs(pose[3].w - 1) < 0.001
    }
}

/// Readiness of the actual camera stream. ARKit supplies calibrated intrinsics;
/// this checks they are usable and that world tracking has settled, not a new lens fit.
struct CaptureCameraReadiness: Equatable {
    enum State: Equatable { case locating, needsTexture, movingTooFast, invalidCamera, ready }
    private(set) var state: State = .locating
    private var settledSince: Double?
    private var motion = CaptureMotion()
    private var previousCamera: (resolution: CGSize, focal: SIMD2<Float>)?
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.state == rhs.state }
    var ready: Bool { state == .ready }
    var hint: String {
        switch state {
        case .locating: return "缓慢移动手机"
        case .needsTexture: return "对准有纹理的区域"
        case .movingTooFast: return "放慢，保持画面稳定"
        case .invalidCamera: return "等待相机就绪"
        case .ready: return "对准主体，按下开始"
        }
    }
    mutating func update(normal: Bool, intrinsics: simd_float3x3, resolution: CGSize,
                         transform: simd_float4x4, features: Int?, timestamp: Double) {
        motion.update(pose: transform, timestamp: timestamp)
        let valid = timestamp.isFinite && CaptureMotion.valid(transform)
            && (0..<3).allSatisfy { c in (0..<3).allSatisfy { intrinsics[c][$0].isFinite } }
            && intrinsics[0][0] > 0 && intrinsics[1][1] > 0
            && resolution.width.isFinite && resolution.height.isFinite && resolution.width > 0 && resolution.height > 0
            && intrinsics[2][0] >= 0 && intrinsics[2][0] < Float(resolution.width)
            && intrinsics[2][1] >= 0 && intrinsics[2][1] < Float(resolution.height)
        guard valid else { state = .invalidCamera; settledSince = nil; previousCamera = nil; motion = CaptureMotion(); return }
        let focal = SIMD2(intrinsics[0][0], intrinsics[1][1])
        if let previousCamera, previousCamera.resolution != resolution
            || max(abs(focal.x / previousCamera.focal.x - 1), abs(focal.y / previousCamera.focal.y - 1)) > 0.02 {
            settledSince = nil
        }
        previousCamera = (resolution, focal)
        guard normal else { state = .locating; settledSince = nil; return }
        guard features.map({ $0 >= 20 }) ?? true else { state = .needsTexture; settledSince = nil; return }
        guard motion.speed != nil else { state = .locating; settledSince = nil; return }
        guard motion.allows(speed: 0.4, turn: 0.7) else { state = .movingTooFast; settledSince = nil; return }
        if settledSince == nil { settledSince = timestamp }
        state = timestamp - settledSince! >= 0.8 ? .ready : .locating
    }
}

struct CaptureFraming: Equatable {
    enum State: Equatable { case aligned, edge(AimCorrection), outside(AimCorrection?), tracking }
    private(set) var state: State = .aligned
    private(set) var marker: CGPoint? // normalized display coordinates, after crop/orientation
    private(set) var acceptsKeyframe = false
    private var outsideSince: Double?
    private var recoveredSince: Double?
    private var lastTime: Double?
    private var returnedToFrame = false
    var needsRecovery: Bool {
        switch state { case .outside, .tracking: return true; default: return false }
    }
    var reacquiring: Bool { returnedToFrame && needsRecovery }
    var correction: AimCorrection? {
        if reacquiring { return nil }
        switch state { case .edge(let direction): return direction; case .outside(let direction): return direction; default: return nil }
    }
    static func project(_ world: SIMD3<Float>, cameraToWorld: simd_float4x4,
                        intrinsics: simd_float3x3, resolution: CGSize, display: CGAffineTransform) -> CGPoint? {
        guard resolution.width > 0, resolution.height > 0 else { return nil }
        let p = cameraToWorld.inverse * SIMD4(world, 1)
        guard p.x.isFinite, p.y.isFinite, p.z.isFinite, p.z < -0.02 else { return nil }
        let sensor = CGPoint(x: CGFloat(intrinsics[0][0] * p.x / -p.z + intrinsics[2][0]) / resolution.width,
                             y: CGFloat(intrinsics[1][1] * -p.y / -p.z + intrinsics[2][1]) / resolution.height)
        let point = sensor.applying(display)
        return point.x.isFinite && point.y.isFinite ? point : nil
    }
    mutating func update(points: [CGPoint], normal: Bool, timestamp: Double, steady: Bool = true) {
        let points = points.filter { $0.x.isFinite && $0.y.isFinite }
        guard timestamp.isFinite, normal else {
            state = .tracking; marker = nil; acceptsKeyframe = false; outsideSince = nil; recoveredSince = nil; lastTime = nil; returnedToFrame = false; return
        }
        if let lastTime, timestamp <= lastTime || timestamp - lastTime > 0.5 {
            outsideSince = nil; recoveredSince = nil
            state = .tracking
        }
        lastTime = timestamp
        let inside: (CGPoint, CGFloat) -> Bool = { p, margin in
            p.x >= margin && p.x <= 1-margin && p.y >= margin && p.y <= 1-margin
        }
        // A person's head/body segment may fill the frame; don't require the waist centre.
        let closest = points.min { hypot($0.x-0.5, $0.y-0.5) < hypot($1.x-0.5, $1.y-0.5) }
        marker = closest
        let usable = points.contains { inside($0, 0.06) }
        returnedToFrame = usable
        guard usable else {
            acceptsKeyframe = false; recoveredSince = nil
            if outsideSince == nil { outsideSince = timestamp }
            if timestamp - outsideSince! >= 0.4 {
                state = .outside(closest.map(Self.direction))
            }
            return
        }
        outsideSince = nil
        if needsRecovery {
            guard steady else { recoveredSince = nil; acceptsKeyframe = false; return }
            if recoveredSince == nil { recoveredSince = timestamp }
            guard timestamp - recoveredSince! >= 0.45 else { acceptsKeyframe = false; return }
        }
        recoveredSince = nil; acceptsKeyframe = true
        state = points.contains { inside($0, 0.17) } ? .aligned : .edge(Self.direction(closest!))
    }
    static func direction(_ p: CGPoint) -> AimCorrection {
        let x = p.x-0.5, y = p.y-0.5
        if abs(x) > abs(y) { return x < 0 ? .left : .right }
        return y < 0 ? .up : .down
    }
}
