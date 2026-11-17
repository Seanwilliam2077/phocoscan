import Foundation
import simd

/// Free-orbit range derived from the cameras that actually captured a model, so the viewer starts
/// from a real capture viewpoint and cannot swing round to sides that were never photographed.
///
/// Rules (reference values for a real capture are asserted in `OrbitLimitsTests`):
/// - distance: `[0.3, 1.5] ×` half the diagonal of the camera-centre bounding box;
/// - polar / azimuth: the spread of the cameras' viewing directions, in three.js `Spherical`
///   convention for the reversed view direction (`polar = acos(y)` from +Y, `azimuth = atan2(x, z)`);
///   the azimuth range opens at the largest gap and is unlimited when that gap is under 30°;
/// - orbit target: on the first camera's optical axis, at the depth where the capture rays converge
///   (least squares), falling back to the camera's distance from the origin.
///
/// The camera path is already in the model frame (`opengl_camera_to_world`), so nothing is rotated
/// or rescaled here; `flipped` evaluates the same cameras in the viewer's 180°-about-Z "flip" frame.
struct OrbitLimits: Equatable, Sendable {
    struct Angles: Equatable, Sendable {
        var minPolar: Double
        var maxPolar: Double
        /// `nil` when the cameras cover the full circle.
        var azimuth: ClosedRange<Double>?
        /// Angles of the first camera, inside the ranges above.
        var initialPolar: Double
        var initialAzimuth: Double
    }

    static let fullCircleGap = Double.pi / 6
    static let minDistanceFactor = 0.3
    static let maxDistanceFactor = 1.5

    let minDistance: Double
    let maxDistance: Double
    /// World-space orbit centre (independent of the flip).
    let target: SIMD3<Double>
    /// Distance from the first camera to `target`, within the distance limits.
    let initialDistance: Double
    let upright: Angles
    let flipped: Angles

    func angles(flipped isFlipped: Bool) -> Angles { isFlipped ? flipped : upright }

    init?(path: SceneCameraPath) {
        self.init(frames: path.frames)
    }

    init?(frames: [SceneCameraFrame]) {
        let poses = frames.map(Self.pose)
        guard let first = poses.first else { return nil }

        var boxMin = SIMD3<Double>(repeating: .infinity)
        var boxMax = SIMD3<Double>(repeating: -.infinity)
        for pose in poses {
            boxMin = simd_min(boxMin, pose.position)
            boxMax = simd_max(boxMax, pose.position)
        }
        let radius = simd_distance(boxMin, boxMax) / 2
        // A single viewpoint (or a tripod sweep) gives no meaningful orbit range.
        guard radius.isFinite, radius > 1e-6 else { return nil }
        minDistance = radius * Self.minDistanceFactor
        maxDistance = radius * Self.maxDistanceFactor

        var depth = Self.convergenceDepth(poses) ?? simd_length(first.position)
        if !depth.isFinite || depth <= 0 { depth = simd_length(first.position) }
        depth = min(maxDistance, max(minDistance, depth))
        initialDistance = depth
        target = first.position + first.forward * depth

        guard let upright = Self.angles(poses.map(\.backward)),
              let flipped = Self.angles(poses.map { SIMD3(-$0.backward.x, -$0.backward.y, $0.backward.z) }) else {
            return nil
        }
        self.upright = upright
        self.flipped = flipped
    }

    // MARK: - Renderer orbit parameters
    //
    // `PocketSplatRenderer` places the free-orbit camera at
    // `target + d · (−cos p · sin y, sin p, cos p · cos y)`, so for a direction with polar φ and
    // azimuth θ: pitch = π/2 − φ and yaw = −θ.

    /// Pitch range in radians, widened by `margin` and kept inside the viewer's ±1.45 rad.
    func pitchRange(flipped isFlipped: Bool, margin: Double) -> ClosedRange<Float> {
        let a = angles(flipped: isFlipped)
        let low = max(-1.45, .pi / 2 - a.maxPolar - margin)
        let high = min(1.45, .pi / 2 - a.minPolar + margin)
        return Float(min(low, high))...Float(max(low, high))
    }

    /// Yaw range in radians on the same branch as `initialYaw`, or `nil` when unlimited.
    func yawRange(flipped isFlipped: Bool, margin: Double) -> ClosedRange<Float>? {
        let a = angles(flipped: isFlipped)
        guard let azimuth = a.azimuth else { return nil }
        let span = azimuth.upperBound - azimuth.lowerBound + 2 * margin
        guard span < 2 * .pi else { return nil }
        return Float(-azimuth.upperBound - margin)...Float(-azimuth.lowerBound + margin)
    }

    func initialPitch(flipped isFlipped: Bool) -> Float {
        Float(.pi / 2 - angles(flipped: isFlipped).initialPolar)
    }

    func initialYaw(flipped isFlipped: Bool) -> Float {
        Float(-angles(flipped: isFlipped).initialAzimuth)
    }

    /// `distanceScale` range relative to `initialDistance`.
    var distanceScaleRange: ClosedRange<Float> {
        Float(minDistance / initialDistance)...Float(maxDistance / initialDistance)
    }

    // MARK: - Helpers

    private struct Pose {
        let position: SIMD3<Double>
        /// Camera +Z in OpenGL convention, i.e. pointing back out of the image.
        let backward: SIMD3<Double>
        var forward: SIMD3<Double> { -backward }
    }

    /// Row-major `cameraToWorld` (OpenGL camera axes) → camera centre and unit backward axis.
    private static func pose(_ frame: SceneCameraFrame) -> Pose {
        let m = frame.cameraToWorld
        let z = SIMD3(m[2], m[6], m[10])
        let length = simd_length(z)
        return Pose(position: SIMD3(m[3], m[7], m[11]), backward: length > 0 ? z / length : SIMD3(0, 0, 1))
    }

    private static func angles(_ directions: [SIMD3<Double>]) -> Angles? {
        guard let first = directions.first else { return nil }
        func spherical(_ v: SIMD3<Double>) -> (polar: Double, azimuth: Double) {
            var theta = atan2(v.x, v.z)
            if theta < 0 { theta += 2 * .pi }
            return (acos(min(1, max(-1, v.y))), theta)
        }
        let values = directions.map(spherical)
        guard let minPolar = values.map(\.polar).min(), let maxPolar = values.map(\.polar).max(),
              minPolar.isFinite, maxPolar.isFinite else { return nil }

        // Open the azimuth circle at its largest gap.
        var azimuths = values.map(\.azimuth).sorted()
        var maxGapIndex = 0
        var maxGap = azimuths[0] - (azimuths[azimuths.count - 1] - 2 * .pi)
        for i in 1..<azimuths.count {
            let gap = azimuths[i] - azimuths[i - 1]
            if gap > maxGap {
                maxGap = gap
                maxGapIndex = i
            }
        }
        if maxGapIndex > 0 {
            for i in maxGapIndex..<azimuths.count { azimuths[i] -= 2 * .pi }
        }
        let firstAngles = spherical(first)
        var initialAzimuth = firstAngles.azimuth
        var azimuthRange: ClosedRange<Double>?
        if maxGap >= fullCircleGap, let low = azimuths.min(), let high = azimuths.max() {
            azimuthRange = low...high
            // Put the first camera on the same branch as the range.
            if initialAzimuth > high + 1e-9 { initialAzimuth -= 2 * .pi }
        }
        return Angles(minPolar: max(0, minPolar), maxPolar: min(.pi, maxPolar), azimuth: azimuthRange,
                      initialPolar: firstAngles.polar, initialAzimuth: initialAzimuth)
    }

    /// Depth along the first camera's axis of the point closest (least squares) to all optical axes,
    /// or `nil` when the axes are close to parallel or the point is not in front of most cameras.
    private static func convergenceDepth(_ poses: [Pose]) -> Double? {
        guard poses.count >= 2, let first = poses.first else { return nil }
        var a = simd_double3x3()
        var b = SIMD3<Double>.zero
        for pose in poses {
            let d = pose.forward
            let projector = matrix_identity_double3x3 - simd_double3x3(columns: (d * d.x, d * d.y, d * d.z))
            a += projector
            b += projector * pose.position
        }
        let n = Double(poses.count)
        guard abs(a.determinant) / (n * n * n) > 1e-4 else { return nil }
        let point = a.inverse * b
        let inFront = poses.filter { simd_dot(point - $0.position, $0.forward) > 0 }.count
        guard Double(inFront) >= 0.8 * n else { return nil }
        return simd_dot(point - first.position, first.forward)
    }
}
