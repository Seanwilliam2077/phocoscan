import Foundation
import simd

/// Cameras already converted by the producer into the exact model's coordinate frame.
/// This is an explicit file contract; neither missing poses nor cross-model alignment are inferred.
struct SceneCameraPath: Codable, Equatable, Sendable {
    let version: Int
    let coordinateSystem: String
    let matrixLayout: String
    let scale: String
    let frames: [SceneCameraFrame]

    var duration: Double {
        guard let first = frames.first, let last = frames.last else { return 0 }
        return last.timeSeconds - first.timeSeconds
    }

    func validated() throws -> SceneCameraPath {
        guard version == 1, coordinateSystem == "opengl_camera_to_world",
              matrixLayout == "row-major", scale == "unknown",
              !frames.isEmpty, frames.count <= 10_000 else {
            throw SceneCameraError.invalidContract
        }
        var previousTime: Double?
        for frame in frames {
            try frame.validate()
            if let previousTime, frame.timeSeconds <= previousTime {
                throw SceneCameraError.invalidTimeline
            }
            previousTime = frame.timeSeconds
        }
        return self
    }

    /// Interpolate orientation and position, without rotating or normalizing the SH model data.
    /// Explicit segment changes, long gaps and very large orientation jumps are cuts.
    func sample(progress: Double) -> SceneCameraSample? {
        guard let first = frames.first, let last = frames.last else { return nil }
        guard frames.count > 1, duration > 0 else { return first.sample }
        let clamped = progress.isFinite ? min(1, max(0, progress)) : 0
        let time = first.timeSeconds + clamped * duration
        if time <= first.timeSeconds { return first.sample }
        if time >= last.timeSeconds { return last.sample }
        var low = 0
        var high = frames.count - 1
        while high - low > 1 {
            let middle = (low + high) / 2
            if frames[middle].timeSeconds <= time { low = middle } else { high = middle }
        }
        let a = frames[low]
        let b = frames[high]
        let interval = b.timeSeconds - a.timeSeconds
        let t = Float((time - a.timeSeconds) / interval)
        let aSample = a.sample
        let bSample = b.sample
        let aRotation = simd_quatf(aSample.worldFromCamera)
        let bRotation = simd_quatf(bSample.worldFromCamera)
        guard a.segmentId == b.segmentId, interval <= 2,
              abs(simd_dot(aRotation.vector, bRotation.vector)) >= 0.7071067 else {
            return t < 0.5 ? aSample : bSample
        }
        let rotation = simd_slerp(aRotation, bRotation, t)
        var pose = simd_float4x4(rotation)
        pose.columns.3 = aSample.worldFromCamera.columns.3 * (1 - t)
            + bSample.worldFromCamera.columns.3 * t
        pose.columns.3.w = 1
        // Intrinsics are interpolated in normalized image coordinates, allowing different sizes.
        let width = aSample.width
        let height = aSample.height
        func mix(_ x: Float, _ y: Float) -> Float { x * (1 - t) + y * t }
        return SceneCameraSample(worldFromCamera: pose, width: width, height: height,
            fx: mix(aSample.fx / width, bSample.fx / bSample.width) * width,
            fy: mix(aSample.fy / height, bSample.fy / bSample.height) * height,
            cx: mix(aSample.cx / width, bSample.cx / bSample.width) * width,
            cy: mix(aSample.cy / height, bSample.cy / bSample.height) * height)
    }
}

struct SceneCameraFrame: Codable, Equatable, Sendable {
    let sourceFrame: String
    let timeSeconds: Double
    let width: Int
    let height: Int
    let fx: Double
    let fy: Double
    let cx: Double
    let cy: Double
    let cameraToWorld: [Double]
    let segmentId: Int?

    fileprivate func validate() throws {
        guard !sourceFrame.isEmpty, sourceFrame.utf8.count <= 512,
              timeSeconds.isFinite, timeSeconds >= 0,
              width > 0, width <= 32_768, height > 0, height <= 32_768,
              fx.isFinite, fy.isFinite, cx.isFinite, cy.isFinite,
              fx > 0, fy > 0, fx <= 1_000_000, fy <= 1_000_000,
              abs(cx) <= Double(width) * 4, abs(cy) <= Double(height) * 4,
              cameraToWorld.count == 16,
              cameraToWorld.allSatisfy({ $0.isFinite && abs($0) <= 100_000_000 }) else {
            throw SceneCameraError.invalidCamera
        }
        guard abs(cameraToWorld[12]) < 0.00001, abs(cameraToWorld[13]) < 0.00001,
              abs(cameraToWorld[14]) < 0.00001, abs(cameraToWorld[15] - 1) < 0.00001 else {
            throw SceneCameraError.invalidCamera
        }
        let pose = sample.worldFromCamera
        let x = SIMD3(pose.columns.0.x, pose.columns.0.y, pose.columns.0.z)
        let y = SIMD3(pose.columns.1.x, pose.columns.1.y, pose.columns.1.z)
        let z = SIMD3(pose.columns.2.x, pose.columns.2.y, pose.columns.2.z)
        guard abs(simd_length_squared(x) - 1) < 0.02,
              abs(simd_length_squared(y) - 1) < 0.02,
              abs(simd_length_squared(z) - 1) < 0.02,
              abs(simd_dot(x, y)) < 0.02, abs(simd_dot(x, z)) < 0.02,
              abs(simd_dot(y, z)) < 0.02,
              abs(simd_dot(simd_cross(x, y), z) - 1) < 0.02 else {
            throw SceneCameraError.invalidCamera
        }
    }

    fileprivate var sample: SceneCameraSample {
        let m = cameraToWorld.map { Float($0) }
        // simd matrices take columns, whereas the interchange contract stores rows.
        let pose = simd_float4x4(columns: (
            SIMD4(m[0], m[4], m[8], m[12]), SIMD4(m[1], m[5], m[9], m[13]),
            SIMD4(m[2], m[6], m[10], m[14]), SIMD4(m[3], m[7], m[11], m[15])))
        return SceneCameraSample(worldFromCamera: pose, width: Float(width), height: Float(height),
            fx: Float(fx), fy: Float(fy), cx: Float(cx), cy: Float(cy))
    }
}

struct SceneCameraSample: Sendable {
    let worldFromCamera: simd_float4x4
    let width: Float
    let height: Float
    let fx: Float
    let fy: Float
    let cx: Float
    let cy: Float
}

enum SceneCameraError: LocalizedError {
    case invalidContract, invalidCamera, invalidTimeline
    var errorDescription: String? {
        switch self {
        case .invalidContract: return "相机轨迹的格式或坐标约定不受支持。"
        case .invalidCamera: return "相机参数无效，无法可靠定位此模型的观察视角。"
        case .invalidTimeline: return "相机轨迹时间顺序无效，无法播放游览。"
        }
    }
}

/// A freely movable camera starting at a verified captured pose. Units stay in the model's
/// frame: cloud reconstructions are not assumed to have metric scale or collision geometry.
struct SceneRoamingCamera {
    let origin: SceneCameraSample
    var yaw: Float = 0
    var pitch: Float = 0
    var offset = SIMD3<Float>.zero

    var sample: SceneCameraSample {
        var pose = origin.worldFromCamera
            * simd_float4x4(simd_quatf(angle: yaw, axis: SIMD3(0, 1, 0)))
            * simd_float4x4(simd_quatf(angle: pitch, axis: SIMD3(1, 0, 0)))
        pose.columns.3 = origin.worldFromCamera.columns.3 + SIMD4(offset, 0)
        return SceneCameraSample(worldFromCamera: pose, width: origin.width, height: origin.height,
                                 fx: origin.fx, fy: origin.fy, cx: origin.cx, cy: origin.cy)
    }

    mutating func look(yaw: Float, pitch: Float) {
        guard yaw.isFinite, pitch.isFinite else { return }
        self.yaw = yaw
        self.pitch = min(.pi * 0.47, max(-.pi * 0.47, pitch))
    }

    mutating func move(right: Float, up: Float = 0, forward: Float) {
        guard right.isFinite, up.isFinite, forward.isFinite else { return }
        let delta = sample.worldFromCamera * SIMD4(right, up, -forward, 0)
        offset += SIMD3(delta.x, delta.y, delta.z)
    }
}
