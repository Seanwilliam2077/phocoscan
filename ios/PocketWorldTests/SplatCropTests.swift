import XCTest
import simd
@testable import PocketWorld

/// Cropping a 3DGS to the anchored subject (camera alignment, regions) and the orbit-video
/// templates. Synthetic cameras and points only.
final class SplatCropTests: XCTestCase {
    func testAnchoredOrbitUsesRecordedGravityAndFitsPortraitViewport() throws {
        let rotation = simd_float3x3(simd_quatf(angle: .pi/2, axis: SIMD3(0,0,1)))
        let translation = SIMD3<Float>(5,-2,1)
        let crop = SplatCrop(region: .box(center: .zero, halfExtents: SIMD3(0.2,0.4,0.1), yaw: 0),
                             rotation: rotation, scale: 3, translation: translation, fitError: 0, matchedCameras: 20)
        var camera = matrix_identity_float4x4
        camera.columns.3 = SIMD4(3 * (rotation * SIMD3<Float>(0,0.3,1.5)) + translation, 1)
        let orbit = try XCTUnwrap(crop.orbit(firstCamera: camera))
        XCTAssertEqual(simd_distance(orbit.target, translation), 0, accuracy: 1e-5)
        XCTAssertEqual(simd_distance(orbit.modelToUpright * (rotation * SIMD3<Float>(0,1,0)), SIMD3(0,1,0)), 0, accuracy: 1e-5)
        let viewRotation = simd_float3x3(simd_quatf(angle: orbit.pitch(flipped: false), axis: SIMD3(1,0,0)))
            * simd_float3x3(simd_quatf(angle: orbit.yaw(flipped: false), axis: SIMD3(0,1,0)))
        for aspect: Float in [0.46, 0.75, 1.78] {
            let distance = orbit.distance(aspect: aspect)
            for x: Float in [-0.2,0.2] { for y: Float in [-0.4,0.4] { for z: Float in [-0.1,0.1] {
                let local = viewRotation * (3 * SIMD3(x,y,z)) - SIMD3(0,0,distance)
                XCTAssertLessThan(abs(local.x / -local.z), tan(Float.pi/6) * aspect)
                XCTAssertLessThan(abs(local.y / -local.z), tan(Float.pi/6))
            } } }
        }
    }

    /// ARKit cameras around the origin at chest height, looking at the body centre, one per 1/30 s.
    private func orbit(_ count: Int = 40, radius: Float = 1.2, arc: Float = 2 * .pi) -> [SplatCrop.Pose] {
        (0..<count).map { i in
            let a = Float(i) / Float(count) * arc
            let center = SIMD3(radius * sin(a), 1.3 + 0.1 * sin(3 * a), radius * cos(a))
            return SplatCrop.Pose(time: Double(i) / 30, center: center, forward: simd_normalize(SIMD3(0, 0.85, 0) - center))
        }
    }
    /// The same cameras as a reconstruction would report them, in its own frame.
    private func inModel(_ poses: [SplatCrop.Pose], timeOffset: Double = 0, noise: Float = 0) -> [SplatCrop.Pose] {
        poses.enumerated().map { i, pose in
            let jitter = noise * SIMD3(sin(Float(i) * 1.7), cos(Float(i) * 2.3), sin(Float(i) * 0.7))
            return SplatCrop.Pose(time: pose.time + timeOffset, center: model(pose.center + jitter), forward: rotation * pose.forward)
        }
    }

    private let rotation = simd_float3x3(simd_quatf(angle: 0.9, axis: simd_normalize(SIMD3<Float>(0.3, 1, -0.2))))
    private let scale: Float = 3.7
    private let translation = SIMD3<Float>(4, -2, 0.5)
    private func model(_ p: SIMD3<Float>) -> SIMD3<Float> { scale * (rotation * p) + translation }

    private let person = ScanTargetBox(center: SIMD3(0, 0.85, 0), size: SIMD3(0.6, 1.7, 0.45),
                                       yawRadians: 0, source: "lidar", subject: "person")
    private let mug = ScanTargetBox(center: SIMD3(0, 0.80, 0), size: SIMD3(0.10, 0.12, 0.10),
                                    yawRadians: 0.4, source: "lidar")

    func testFitRecoversAScaledRotatedModelFrame() throws {
        let arkit = orbit().map(\.center)
        let fit = try XCTUnwrap(SplatCrop.fitSimilarity(from: arkit, to: arkit.map { model($0) }))
        XCTAssertEqual(fit.scale, scale, accuracy: 1e-3)
        XCTAssertLessThan(fit.error, 1e-4)
        XCTAssertLessThan(simd_length(fit.translation - translation), 1e-3)
        for column in 0..<3 { XCTAssertLessThan(simd_length(fit.rotation[column] - rotation[column]), 1e-4) }
        // Cameras along one straight line cannot fix the rotation.
        let line = (0..<10).map { SIMD3<Float>(Float($0) * 0.1, 1.3, 0) }
        XCTAssertNil(SplatCrop.fitSimilarity(from: line, to: line.map { model($0) }))
    }

    func testCropMatchesCamerasByTimeAndRejectsPoorFits() throws {
        let arkit = orbit()
        // The result registered every third frame; its timestamps carry float noise.
        let cameras = inModel(arkit.enumerated().filter { $0.offset % 3 == 0 }.map(\.element), timeOffset: 0.0005)
        let crop = try XCTUnwrap(SplatCrop.make(target: person, cameras: cameras, arkit: arkit))
        XCTAssertEqual(crop.matchedCameras, cameras.count)
        XCTAssertLessThan(simd_length(crop.toARKit(model(SIMD3(0.2, 1.0, -0.1))) - SIMD3(0.2, 1.0, -0.1)), 1e-3)

        XCTAssertNil(SplatCrop.make(target: person, cameras: Array(cameras.prefix(3)), arkit: arkit), "too few matches")
        XCTAssertNil(SplatCrop.make(target: person, cameras: inModel(arkit, timeOffset: 0.02), arkit: arkit), "times from another clip")
        var scrambled = cameras
        scrambled.swapAt(0, 7); scrambled.swapAt(2, 9)
        let mixed = zip(cameras, scrambled).map { SplatCrop.Pose(time: $0.0.time, center: $0.1.center, forward: $0.1.forward) }
        XCTAssertNil(SplatCrop.make(target: person, cameras: mixed, arkit: arkit), "cameras that do not agree")
    }

    /// Like the real results on the A10: the phone moved only ~16 cm while turning toward the
    /// subject, and reconstructed cameras are off by a few centimetres. Directions keep the fit.
    func testSmallBaselineWithCentimetreNoiseStillAligns() throws {
        let arkit = orbit(50, radius: 0.9, arc: 0.18)
        let crop = try XCTUnwrap(SplatCrop.make(target: person, cameras: inModel(arkit, noise: 0.02), arkit: arkit))
        XCTAssertLessThan(crop.fitError, 0.05)
        XCTAssertLessThan(simd_length(crop.toARKit(model(SIMD3(0, 1.6, 0))) - SIMD3(0, 1.6, 0)), 0.1, "the head maps to the head")
        XCTAssertNil(SplatCrop.make(target: person, cameras: inModel(arkit, noise: 0.4), arkit: arkit), "decimetre-scale disagreement")
    }

    func testPersonKeepsTheBodyAndTheFloorUnderTheFeet() throws {
        let crop = try XCTUnwrap(SplatCrop.make(target: person, cameras: inModel(orbit()), arkit: orbit()))
        func keeps(_ p: SIMD3<Float>, opacity: Float = 0.8) -> Bool { crop.keeps(position: model(p), opacity: opacity) }
        XCTAssertTrue(keeps(SIMD3(0.1, 1.6, 0.05)), "head")
        XCTAssertTrue(keeps(SIMD3(0.3, 0.0, 0.2)), "floor next to the feet")
        XCTAssertFalse(keeps(SIMD3(1.0, 0.0, 0)), "floor a metre away")
        XCTAssertFalse(keeps(SIMD3(0, 2.4, 0)), "ceiling")
        XCTAssertFalse(keeps(SIMD3(0.1, 1.2, 0), opacity: 0.01), "near-transparent haze")
    }

    func testObjectKeepsItsContactWithTheTable() {
        let region = SplatCrop.region(for: mug)
        let crop = SplatCrop(region: region, rotation: matrix_identity_float3x3, scale: 1, translation: .zero,
                             fitError: 0, matchedCameras: 10)
        XCTAssertTrue(crop.contains(arkit: SIMD3(0, 0.80, 0)))
        XCTAssertTrue(crop.contains(arkit: SIMD3(0.06, 0.73, 0)), "table top just outside the mug")
        XCTAssertFalse(crop.contains(arkit: SIMD3(0.3, 0.74, 0)), "rest of the table")
        XCTAssertFalse(crop.contains(arkit: SIMD3(0, 0.5, 0)), "under the table")
        XCTAssertFalse(crop.contains(arkit: SIMD3(0, 1.1, 0)), "above")
    }

    func testJacobiSolvesASymmetricMatrix() {
        let result = SplatCrop.symmetricEigen([[2, 1, 0], [1, 2, 0], [0, 0, 5]])
        XCTAssertEqual(result.values.sorted(), [1, 3, 5].map(Double.init), accuracy: 1e-9)
    }

    // MARK: Video templates

    func testVideoTemplatesFollowTheScanMode() {
        let center = OrbitPose(yaw: 0.2, pitch: 0.1, distanceScale: 1, panOffset: .zero, flipUp: false)
        XCTAssertEqual(OrbitVideo.Style(mode: "portrait"), .portrait)
        XCTAssertEqual(OrbitVideo.Style(mode: "space"), .flythrough)
        XCTAssertEqual(OrbitVideo.Style(mode: nil), .orbit)

        let full = OrbitVideo.poses(style: .orbit, center: center, yawRange: nil, frameCount: 180)
        XCTAssertEqual(full.count, 180)
        XCTAssertEqual(full.last!.yaw - full.first!.yaw, 2 * .pi, accuracy: 1e-4, "a full turn")
        let arc = OrbitVideo.poses(style: .orbit, center: center, yawRange: -0.5...0.9, frameCount: 181)
        XCTAssertEqual(arc.map(\.yaw).min()!, -0.5, accuracy: 1e-3)
        XCTAssertEqual(arc.map(\.yaw).max()!, 0.9, accuracy: 1e-3)
        XCTAssertEqual(arc.first!.yaw, arc.last!.yaw, accuracy: 1e-3, "sweeps the captured arc and back")

        let portrait = OrbitVideo.poses(style: .portrait, center: center, yawRange: nil, frameCount: 180)
        XCTAssertEqual(portrait[50].distanceScale, 1)
        XCTAssertEqual(portrait.last!.distanceScale, 0.65, accuracy: 1e-4, "ends closer to the person")
        let space = OrbitVideo.poses(style: .flythrough, center: center, yawRange: nil, frameCount: 180)
        XCTAssertGreaterThan(space.first!.distanceScale, space.last!.distanceScale, "drifts forward")
        XCTAssertLessThan(abs(space.map(\.yaw).max()! - space.map(\.yaw).min()!), 0.4)
    }
}

private func XCTAssertEqual(_ a: [Double], _ b: [Double], accuracy: Double, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(a.count, b.count, file: file, line: line)
    for (x, y) in zip(a, b) { XCTAssertEqual(x, y, accuracy: accuracy, file: file, line: line) }
}
