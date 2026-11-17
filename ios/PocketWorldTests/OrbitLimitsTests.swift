import XCTest
import simd
@testable import PocketWorld

/// Orbit range from capture cameras. The reference values come from a real 83-camera capture
/// (`Fixtures/sample-capture-cameras.json`); the other cases are synthetic camera layouts.
final class OrbitLimitsTests: XCTestCase {
    // MARK: - Real capture reference

    /// A 3DGS `cameras.json` entry (OpenCV axes, `rotation` = camera-to-world, row-major;
    /// `position` = camera centre) converted to the frame the reference values were logged in:
    /// world rotated 180° about Z, OpenGL camera axes, i.e. `diag(−1,−1,1) · [R | C] · diag(1,−1,−1)`.
    private func referenceFrames() throws -> [SceneCameraFrame] {
        struct Camera: Decodable {
            let width: Int, height: Int, fx: Double, fy: Double
            let position: [Double], rotation: [[Double]]
        }
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "sample-capture-cameras", withExtension: "json"))
        let cameras = try JSONDecoder().decode([Camera].self, from: Data(contentsOf: url))
        return cameras.enumerated().map { index, camera in
            let r = camera.rotation, c = camera.position, worldFlip: [Double] = [-1, -1, 1]
            var m = [Double](repeating: 0, count: 16)
            for row in 0..<3 {
                m[row * 4 + 0] = worldFlip[row] * r[row][0]
                m[row * 4 + 1] = worldFlip[row] * -r[row][1]
                m[row * 4 + 2] = worldFlip[row] * -r[row][2]
                m[row * 4 + 3] = worldFlip[row] * c[row]
            }
            m[15] = 1
            return SceneCameraFrame(sourceFrame: "\(index)", timeSeconds: Double(index), width: camera.width,
                                    height: camera.height, fx: camera.fx, fy: camera.fy,
                                    cx: Double(camera.width) / 2, cy: Double(camera.height) / 2,
                                    cameraToWorld: m, segmentId: nil)
        }
    }

    func testMatchesReferenceValuesForRealCapture() throws {
        let frames = try referenceFrames()
        XCTAssertEqual(frames.count, 83)
        // The converted cameras satisfy the app's own camera-path contract.
        let path = try SceneCameraPath(version: 1, coordinateSystem: "opengl_camera_to_world",
                                       matrixLayout: "row-major", scale: "unknown", frames: frames).validated()

        let limits = try XCTUnwrap(OrbitLimits(path: path))
        XCTAssertEqual(limits.minDistance, 0.22114891992352703, accuracy: 1e-9)
        XCTAssertEqual(limits.maxDistance, 1.1057445996176352, accuracy: 1e-9)
        XCTAssertEqual(limits.upright.minPolar, 1.2368757650736595, accuracy: 1e-9)
        XCTAssertEqual(limits.upright.maxPolar, 1.328367485333579, accuracy: 1e-9)
        let azimuth = try XCTUnwrap(limits.upright.azimuth)
        XCTAssertEqual(azimuth.lowerBound, 1.5426825228708116, accuracy: 1e-9)
        XCTAssertEqual(azimuth.upperBound, 4.757025193580466, accuracy: 1e-9)

        // The free orbit starts inside its own limits.
        XCTAssertTrue(limits.pitchRange(flipped: false, margin: 0).contains(limits.initialPitch(flipped: false)))
        let yaw = try XCTUnwrap(limits.yawRange(flipped: false, margin: 0))
        XCTAssertTrue(yaw.contains(limits.initialYaw(flipped: false)))
        XCTAssertTrue(limits.distanceScaleRange.contains(1))
    }

    // MARK: - Synthetic layouts

    /// OpenGL camera-to-world (row-major) for a camera at `position` looking at `target`.
    private func frame(at position: SIMD3<Double>, lookingAt target: SIMD3<Double>, index: Int) -> SceneCameraFrame {
        let z = simd_normalize(position - target)
        let x = simd_normalize(simd_cross(SIMD3(0, 1, 0), z))
        let y = simd_cross(z, x)
        let m = [x.x, y.x, z.x, position.x, x.y, y.y, z.y, position.y, x.z, y.z, z.z, position.z, 0, 0, 0, 1]
        return SceneCameraFrame(sourceFrame: "\(index)", timeSeconds: Double(index), width: 1920, height: 1440,
                                fx: 1500, fy: 1500, cx: 960, cy: 720, cameraToWorld: m, segmentId: nil)
    }

    private func arc(degrees: StrideThrough<Double>, height: Double = 0.3,
                     target: SIMD3<Double> = .zero) -> [SceneCameraFrame] {
        degrees.enumerated().map { index, angle in
            let a = angle * .pi / 180
            return frame(at: target + SIMD3(sin(a), height, cos(a)), lookingAt: target, index: index)
        }
    }

    func testFullCircleHasNoYawLimitAndFindsTheTarget() throws {
        let target = SIMD3<Double>(0.4, -0.2, 1.5)
        let limits = try XCTUnwrap(OrbitLimits(frames: arc(degrees: stride(from: 0, through: 350, by: 10), target: target)))
        XCTAssertNil(limits.upright.azimuth)
        XCTAssertNil(limits.yawRange(flipped: false, margin: 0))
        XCTAssertLessThan(simd_distance(limits.target, target), 1e-6)
        XCTAssertEqual(limits.initialDistance, sqrt(1.09), accuracy: 1e-6)
    }

    func testHalfArcLimitsYawAndStartsAtTheFirstCamera() throws {
        let limits = try XCTUnwrap(OrbitLimits(frames: arc(degrees: stride(from: 0, through: 180, by: 10))))
        let azimuth = try XCTUnwrap(limits.upright.azimuth)
        XCTAssertEqual(azimuth.lowerBound, 0, accuracy: 1e-9)
        XCTAssertEqual(azimuth.upperBound, .pi, accuracy: 1e-9)

        let yaw = try XCTUnwrap(limits.yawRange(flipped: false, margin: 0))
        XCTAssertEqual(Double(yaw.lowerBound), -.pi, accuracy: 1e-6)
        XCTAssertEqual(Double(yaw.upperBound), 0, accuracy: 1e-6)
        XCTAssertEqual(Double(limits.initialYaw(flipped: false)), 0, accuracy: 1e-6)

        // All cameras share one height, so pitch is pinned to it (asin(0.3 / |p|)).
        let pitch = limits.pitchRange(flipped: false, margin: 0)
        XCTAssertEqual(Double(pitch.lowerBound), asin(0.3 / sqrt(1.09)), accuracy: 1e-6)
        XCTAssertEqual(Double(pitch.upperBound), asin(0.3 / sqrt(1.09)), accuracy: 1e-6)

        // The renderer's orbit position for the initial angles reproduces camera 0's direction.
        let p = Double(limits.initialPitch(flipped: false)), y = Double(limits.initialYaw(flipped: false))
        let direction = SIMD3(-cos(p) * sin(y), sin(p), cos(p) * cos(y))
        XCTAssertLessThan(simd_distance(direction, simd_normalize(SIMD3(0, 0.3, 1))), 1e-6)
    }

    func testFlipEvaluatesTheMirroredFrame() throws {
        let limits = try XCTUnwrap(OrbitLimits(frames: arc(degrees: stride(from: 0, through: 180, by: 10))))
        // Cameras above the target become cameras below it in the flipped view.
        XCTAssertEqual(Double(limits.initialPitch(flipped: true)), -Double(limits.initialPitch(flipped: false)), accuracy: 1e-6)
        XCTAssertNotNil(limits.yawRange(flipped: true, margin: 0))
    }

    func testMarginWidensRangesButStaysInsideViewerPitch() throws {
        let limits = try XCTUnwrap(OrbitLimits(frames: arc(degrees: stride(from: 0, through: 180, by: 10))))
        let margin = 10.0 * .pi / 180
        let tight = limits.pitchRange(flipped: false, margin: 0)
        let wide = limits.pitchRange(flipped: false, margin: margin)
        XCTAssertEqual(Double(wide.lowerBound), Double(tight.lowerBound) - margin, accuracy: 1e-6)
        XCTAssertLessThanOrEqual(limits.pitchRange(flipped: false, margin: 3).upperBound, 1.45)
        XCTAssertGreaterThanOrEqual(limits.pitchRange(flipped: false, margin: 3).lowerBound, -1.45)
    }

    func testSingleViewpointGivesNoLimits() {
        let frames = (0..<5).map { frame(at: SIMD3(0, 0, 1), lookingAt: .zero, index: $0) }
        XCTAssertNil(OrbitLimits(frames: frames))
    }
}


final class RoamingCameraTests: XCTestCase {
    func testMovementUsesCameraOrientationAndKeepsIntrinsics() {
        let source = SceneCameraSample(worldFromCamera: matrix_identity_float4x4,
            width: 640, height: 480, fx: 500, fy: 500, cx: 320, cy: 240)
        var camera = SceneRoamingCamera(origin: source)
        camera.move(right: 0, forward: 2)
        XCTAssertEqual(camera.sample.worldFromCamera.columns.3.z, -2, accuracy: 1e-5)
        camera.look(yaw: .pi / 2, pitch: 0)
        camera.move(right: 0, forward: 1)
        XCTAssertEqual(camera.sample.worldFromCamera.columns.3.x, -1, accuracy: 1e-5)
        XCTAssertEqual(camera.sample.fx, source.fx)
        XCTAssertEqual(camera.sample.worldFromCamera.columns.3.w, 1)
        camera.look(yaw: 0, pitch: 10)
        XCTAssertLessThan(camera.pitch, .pi / 2)
        camera.move(right: .nan, forward: 0)
        XCTAssertTrue(camera.offset.x.isFinite)
    }
}
