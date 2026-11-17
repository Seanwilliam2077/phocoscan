import Accelerate
import CoreVideo
import Foundation
import Vision
import simd

/// Picks the training keyframes from the live ARKit stream, on the phone, while
/// recording. A frame is kept only when
///   1. the phone is not moving or turning too fast (pose-derived speed gate),
///   2. it is far enough from the last keyframe (baseline gate: translation or rotation),
///   3. it is not blurrier than the recent frames (Laplacian variance of the luma),
/// and the per-mode count stays inside the plan's range. Pure value type; one queue.
struct KeyframeSelector {
    struct Policy: Equatable {
        /// Baseline gate against the last keyframe.
        var minTranslation: Float
        var minRotationDegrees: Float
        /// Never two keyframes closer in time than this.
        var minInterval: Double
        /// Speed gate (instantaneous, from consecutive poses).
        var maxSpeed: Float
        var maxTurnDegrees: Float
        /// Target range for the whole scan; `count.upperBound` is a hard cap.
        var count: ClosedRange<Int>

        static func forMode(_ mode: ScanMode) -> Policy {
            switch mode {
            case .object:   // orbit at ~1 m: one keyframe per ~3° of the orbit
                return Policy(minTranslation: 0.05, minRotationDegrees: 3, minInterval: 0.15,
                              maxSpeed: 0.5, maxTurnDegrees: 60, count: 150...300)
            case .space:    // free walk: denser, larger scenes
                return Policy(minTranslation: 0.06, minRotationDegrees: 3.5, minInterval: 0.12,
                              maxSpeed: 0.6, maxTurnDegrees: 60, count: 300...600)
            case .portrait: // two rounds within about a minute
                return Policy(minTranslation: 0.06, minRotationDegrees: 4, minInterval: 0.2,
                              maxSpeed: 0.5, maxTurnDegrees: 50, count: 120...250)
            }
        }
    }

    enum Decision: Equatable {
        case keep
        /// Gates that rejected the frame; counted in `meta.json`.
        case tooFast, tooClose, blurry, full
    }

    let policy: Policy
    private(set) var keptCount = 0
    private(set) var rejectedFast = 0
    private(set) var rejectedBlurry = 0
    private var last: (position: SIMD3<Float>, forward: SIMD3<Float>, time: Double)?
    private var previous: (position: SIMD3<Float>, forward: SIMD3<Float>, time: Double)?
    /// Recent sharpness values of frames that passed the pose gates.
    private var recentSharpness: [Float] = []
    /// When the baseline gate first opened for the frame now being waited on.
    private var gateOpenedAt: Double?

    init(policy: Policy) { self.policy = policy }

    /// Cheap pose-only check, run on every frame before any pixel work. Returns nil
    /// when the frame may become a keyframe and its sharpness should be measured.
    mutating func poseGate(transform: simd_float4x4, timestamp: Double, captureWaypoint: Bool = false) -> Decision? {
        let position = SIMD3(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
        let forward = Self.forward(transform)
        defer { previous = (position, forward, timestamp) }
        if keptCount >= policy.count.upperBound { return .full }
        if let previous {
            let dt = timestamp - previous.time
            if dt > 0.005 && dt < 0.5 {
                let speed = simd_length(position - previous.position) / Float(dt)
                let turn = Self.degrees(forward, previous.forward) / Float(dt)
                if speed > policy.maxSpeed || turn > policy.maxTurnDegrees {
                    rejectedFast += 1
                    return .tooFast
                }
            }
        }
        guard let last else { return nil } // the first steady frame is always a candidate
        if timestamp - last.time < policy.minInterval { return .tooClose }
        let moved = simd_length(position - last.position) >= policy.minTranslation
        let turned = Self.degrees(forward, last.forward) >= policy.minRotationDegrees
        // At a recommended position, permit a fresh still frame even if the last
        // passing frame was just outside its tolerance. Speed, spacing, sharpness
        // and frame-count limits still apply; a saved frame advances the waypoint.
        guard moved || turned || captureWaypoint else {
            gateOpenedAt = nil
            return .tooClose
        }
        if gateOpenedAt == nil { gateOpenedAt = timestamp }
        return nil
    }

    /// Second stage for frames that passed `poseGate`: blur check against the recent
    /// candidates. The bar drops over 0.5 s so a long blurry stretch still yields
    /// its sharpest-looking frames rather than a gap.
    mutating func sharpnessGate(sharpness: Float, transform: simd_float4x4, timestamp: Double) -> Decision {
        // A blank, clipped or textureless view must not pass merely because all
        // recent candidates were equally poor. Luma here is measured on 0...255.
        guard sharpness.isFinite, sharpness > 1 else { rejectedBlurry += 1; return .blurry }
        recentSharpness.append(sharpness)
        if recentSharpness.count > 30 { recentSharpness.removeFirst(recentSharpness.count - 30) }
        if recentSharpness.count >= 5 {
            let median = recentSharpness.sorted()[recentSharpness.count / 2]
            let waited = gateOpenedAt.map { timestamp - $0 } ?? 0
            let factor = Float(max(0.45, 0.8 - waited * 0.7))
            if sharpness < median * factor {
                rejectedBlurry += 1
                return .blurry
            }
        }
        accept(transform: transform, timestamp: timestamp)
        return .keep
    }

    /// Marks a frame as kept (used directly when no image is available, e.g. tests).
    mutating func accept(transform: simd_float4x4, timestamp: Double) {
        last = (SIMD3(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z),
                Self.forward(transform), timestamp)
        gateOpenedAt = nil
        keptCount += 1
    }

    static func forward(_ t: simd_float4x4) -> SIMD3<Float> {
        let back = SIMD3(t.columns.2.x, t.columns.2.y, t.columns.2.z)
        let length = simd_length(back)
        return length > 0 ? -back / length : SIMD3(0, 0, -1)
    }

    static func degrees(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
        acos(min(1, max(-1, simd_dot(a, b)))) * 180 / .pi
    }
}

/// Sharpness of a camera frame: variance of the Laplacian of the luma plane over the
/// central 60% of the image, computed with vImage (fast in every build configuration).
/// Higher is sharper; only meaningful relative to other frames of the same scan.
final class SharpnessMeter {
    private var floatBuffer: [Float] = []
    private var laplacian: [Float] = []

    func measure(_ image: CVPixelBuffer) -> Float? {
        guard CVPixelBufferGetPlaneCount(image) >= 1 else { return nil }
        CVPixelBufferLockBaseAddress(image, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(image, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(image, 0) else { return nil }
        let width = CVPixelBufferGetWidthOfPlane(image, 0)
        let height = CVPixelBufferGetHeightOfPlane(image, 0)
        let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(image, 0)
        return Self.measure(luma: base, width: width, height: height, rowBytes: rowBytes,
                            floatBuffer: &floatBuffer, laplacian: &laplacian)
    }

    /// Exposed for tests with synthetic images.
    static func measure(luma base: UnsafeMutableRawPointer, width: Int, height: Int, rowBytes: Int,
                        floatBuffer: inout [Float], laplacian: inout [Float]) -> Float? {
        let cropW = width * 3 / 5, cropH = height * 3 / 5
        guard cropW > 8, cropH > 8 else { return nil }
        let x0 = (width - cropW) / 2, y0 = (height - cropH) / 2
        var source = vImage_Buffer(data: base.advanced(by: y0 * rowBytes + x0), height: vImagePixelCount(cropH),
                                   width: vImagePixelCount(cropW), rowBytes: rowBytes)
        let count = cropW * cropH
        if floatBuffer.count != count { floatBuffer = [Float](repeating: 0, count: count) }
        if laplacian.count != count { laplacian = [Float](repeating: 0, count: count) }
        let kernel: [Float] = [0, 1, 0, 1, -4, 1, 0, 1, 0]
        var result: Float?
        floatBuffer.withUnsafeMutableBufferPointer { floats in
            laplacian.withUnsafeMutableBufferPointer { output in
                var asFloat = vImage_Buffer(data: floats.baseAddress, height: vImagePixelCount(cropH),
                                            width: vImagePixelCount(cropW), rowBytes: cropW * 4)
                var filtered = vImage_Buffer(data: output.baseAddress, height: vImagePixelCount(cropH),
                                             width: vImagePixelCount(cropW), rowBytes: cropW * 4)
                guard vImageConvert_Planar8toPlanarF(&source, &asFloat, 255, 0, vImage_Flags(kvImageNoFlags)) == kvImageNoError,
                      vImageConvolve_PlanarF(&asFloat, &filtered, nil, 0, 0, kernel, 3, 3, 0,
                                             vImage_Flags(kvImageEdgeExtend)) == kvImageNoError else { return }
                var mean: Float = 0, meanSquare: Float = 0
                vDSP_meanv(output.baseAddress!, 1, &mean, vDSP_Length(count))
                vDSP_measqv(output.baseAddress!, 1, &meanSquare, vDSP_Length(count))
                result = max(0, meanSquare - mean * mean)
            }
        }
        return result
    }
}

/// Person mode: is the subject holding still? Body joints found by Vision in sampled
/// frames become world rays (ARKit pose + intrinsics). Rays from different angles are
/// intersected (least squares) to a fixed joint position; when new rays keep missing
/// that point by more than `threshold`, the subject has moved. Needs ≥ 20° of orbit
/// before it can judge. Pure value type; no image access.
struct SubjectStillnessTracker {
    typealias Ray = (origin: SIMD3<Float>, direction: SIMD3<Float>)
    /// Distance between a new ray and the established joint position that counts as movement.
    static let threshold: Float = 0.08
    /// Consecutive off samples before reporting movement (filters single bad detections).
    static let sustain = 2

    private struct Joint {
        var a = simd_float3x3()
        var b = SIMD3<Float>(repeating: 0)
        var firstDirection: SIMD3<Float>?
        var minCos: Float = 1
        var rays = 0
        var point: SIMD3<Float>?

        mutating func add(origin: SIMD3<Float>, direction d: SIMD3<Float>) {
            let p = matrix_identity_float3x3 - simd_float3x3(columns: (d * d.x, d * d.y, d * d.z))
            a += p; b += p * origin; rays += 1
            if let firstDirection { minCos = min(minCos, simd_dot(firstDirection, d)) } else { firstDirection = d }
            if rays >= 4, minCos < cos(20 * Float.pi / 180), abs(a.determinant) > 1e-5 {
                let candidate = a.inverse * b
                if candidate.x.isFinite && candidate.y.isFinite && candidate.z.isFinite { point = candidate }
            }
        }
    }

    private var joints: [String: Joint] = [:]
    private var offStreak = 0
    private(set) var isMoving = false
    /// Largest ray–joint distance in the latest sample (meters), for diagnostics.
    private(set) var lastResidual: Float = 0
    private(set) var samples = 0

    /// One Vision sample: rays (world origin + unit direction) per joint name.
    mutating func add(rays: [String: Ray]) {
        guard !rays.isEmpty else { return }
        samples += 1
        var worst: Float = 0
        var judged = false
        for (name, ray) in rays {
            var joint = joints[name] ?? Joint()
            if let point = joint.point {
                let distance = Self.distance(from: point, toRay: ray.origin, ray.direction)
                worst = max(worst, distance)
                judged = true
                // Only rays consistent with a still subject refine the joint.
                if distance < Self.threshold { joint.add(origin: ray.origin, direction: ray.direction) }
            } else {
                joint.add(origin: ray.origin, direction: ray.direction)
            }
            joints[name] = joint
        }
        lastResidual = worst
        guard judged else { return }
        offStreak = worst > Self.threshold ? offStreak + 1 : 0
        isMoving = offStreak >= Self.sustain
        if offStreak >= Self.resetAfter {
            // The subject settled into a new pose: start a new reference from here on.
            joints = [:]
            offStreak = 0
            isMoving = false
        }
    }

    /// Off samples in a row after which the old reference is dropped (about 2 s).
    static let resetAfter = 8

    /// Triangulated joint positions (world), once established.
    var jointPoints: [String: SIMD3<Float>] { joints.compactMapValues(\.point) }

    static func distance(from point: SIMD3<Float>, toRay origin: SIMD3<Float>, _ direction: SIMD3<Float>) -> Float {
        let v = point - origin
        let along = max(0, simd_dot(v, direction))
        return simd_length(v - direction * along)
    }

    /// Horizontal distance by which a ray passes a vertical axis at `axis` (x, z).
    static func horizontalMiss(origin: SIMD3<Float>, direction: SIMD3<Float>, axis: SIMD2<Float>) -> Float {
        let d = SIMD2(direction.x, direction.z)
        let to = axis - SIMD2(origin.x, origin.z)
        guard simd_length(d) > 1e-4 else { return simd_length(to) }
        let n = simd_normalize(d)
        guard simd_dot(n, to) > 0 else { return simd_length(to) } // behind the camera
        return abs(n.x * to.y - n.y * to.x)
    }

    /// World ray through a pixel of the captured (landscape sensor) image.
    static func ray(pixel: SIMD2<Float>, intrinsics k: simd_float3x3, cameraToWorld t: simd_float4x4) -> Ray {
        // ARKit camera: +x right, +y up, -z forward; image v grows downward.
        let local = SIMD3((pixel.x - k[2][0]) / k[0][0], -(pixel.y - k[2][1]) / k[1][1], -1)
        let world = simd_make_float3(t * SIMD4(local, 0))
        return (SIMD3(t.columns.3.x, t.columns.3.y, t.columns.3.z), simd_normalize(world))
    }

    /// Vision returns normalized points (origin bottom-left) in the upright image for
    /// orientation `.right` (phone held upright, back camera). Map back to the sensor
    /// image (width × height, landscape, origin top-left).
    static func sensorPixel(visionPoint p: CGPoint, sensorWidth: Int, sensorHeight: Int) -> SIMD2<Float> {
        SIMD2(Float(1 - p.y) * Float(sensorWidth), Float(1 - p.x) * Float(sensorHeight))
    }
}

/// Vision checks for person mode on one camera frame: body joints (as world rays, for
/// `SubjectStillnessTracker`) and whether a frontal face is visible up close.
enum PersonVision {
    struct Result {
        /// One entry per detected person: joint name → world ray.
        var bodies: [[String: SubjectStillnessTracker.Ray]] = []
        var frontalFace = false
    }

    /// A face this large (share of the upright image height) and this frontal counts.
    static let minFaceHeight: CGFloat = 0.07
    static let maxFaceYaw: Float = 0.35   // radians, about 20°

    static func analyze(_ image: CVPixelBuffer, intrinsics: simd_float3x3, cameraToWorld: simd_float4x4,
                        checkFace: Bool) -> Result {
        let width = CVPixelBufferGetWidth(image), height = CVPixelBufferGetHeight(image)
        let bodyRequest = VNDetectHumanBodyPoseRequest()
        let faceRequest = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cvPixelBuffer: image, orientation: .right)
        var result = Result()
        guard (try? handler.perform(checkFace ? [bodyRequest, faceRequest] : [bodyRequest])) != nil else { return result }
        for observation in bodyRequest.results ?? [] {
            var rays: [String: SubjectStillnessTracker.Ray] = [:]
            for (joint, name) in [(VNHumanBodyPoseObservation.JointName.neck, "neck"), (.root, "root")] {
                guard let point = try? observation.recognizedPoint(joint), point.confidence > 0.3 else { continue }
                let pixel = SubjectStillnessTracker.sensorPixel(visionPoint: point.location,
                                                                sensorWidth: width, sensorHeight: height)
                rays[name] = SubjectStillnessTracker.ray(pixel: pixel, intrinsics: intrinsics, cameraToWorld: cameraToWorld)
            }
            if !rays.isEmpty { result.bodies.append(rays) }
        }
        if checkFace {
            result.frontalFace = (faceRequest.results ?? []).contains { face in
                guard face.boundingBox.height >= minFaceHeight, let yaw = face.yaw?.floatValue else { return false }
                return abs(yaw) <= maxFaceYaw && abs(face.pitch?.floatValue ?? 0) <= 0.45
            }
        }
        return result
    }
}
