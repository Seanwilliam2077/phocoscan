import XCTest
import simd
@testable import PocketWorld

final class NextPositionGuidanceTests: XCTestCase {
    private let target = ScanTargetBox(center: SIMD3<Float>(0, 1, 0), size: SIMD3<Float>(0.4, 0.5, 0.4), yawRadians: 0, source: "test")
    private func camera(_ p: SIMD3<Float>) -> simd_float4x4 {
        let z = simd_normalize(p - target.simdCenter)
        let x = simd_normalize(simd_cross(SIMD3<Float>(0, 1, 0), z)), y = simd_cross(z, x)
        return simd_float4x4(SIMD4(x, 0), SIMD4(y, 0), SIMD4(z, 0), SIMD4(p, 1))
    }
    func testArrivalAllowsAStillKeyframeButDoesNotBypassBlurOrSpeed() {
        var selector = KeyframeSelector(policy: .forMode(.object))
        let pose = matrix_identity_float4x4
        selector.accept(transform: pose, timestamp: 0)
        XCTAssertNotNil(selector.poseGate(transform: pose, timestamp: 0.2))
        XCTAssertNil(selector.poseGate(transform: pose, timestamp: 0.4, captureWaypoint: true))
        XCTAssertEqual(selector.sharpnessGate(sharpness: 0, transform: pose, timestamp: 0.4), .blurry)
        var moved = pose; moved.columns.3.x = 1
        XCTAssertEqual(selector.poseGate(transform: moved, timestamp: 0.5, captureWaypoint: true), .tooFast)
    }

    func testSavedFrameRequiredAndWaypointDoesNotChaseThePhone() throws {
        var planner = SubjectStepPlanner()
        let pose = camera(SIMD3(0, 1, 1))
        XCTAssertEqual(planner.update(transform: pose, target: target, timestamp: 1)?.motion, .hold)
        planner.recordSaved(transform: pose, target: target, timestamp: 1)
        let next = try XCTUnwrap(planner.update(transform: pose, target: target, timestamp: 2))
        XCTAssertEqual(simd_distance(next.position, SIMD3(0, 1, 1)), 0.18, accuracy: 0.001)
        let moved = camera(SIMD3(0.02, 1, 1))
        XCTAssertEqual(planner.update(transform: moved, target: target, timestamp: 3)?.position, next.position)
        let arrived = camera(next.position)
        XCTAssertEqual(planner.update(transform: arrived, target: target, timestamp: 4)?.motion, .hold)
        XCTAssertEqual(planner.update(transform: arrived, target: target, timestamp: 5)?.position, next.position)
        planner.recordSaved(transform: arrived, target: target, timestamp: 1.5) // old callback
        XCTAssertEqual(planner.update(transform: arrived, target: target, timestamp: 6)?.position, next.position)
        planner.recordSaved(transform: arrived, target: target, timestamp: 6)
        XCTAssertNotEqual(planner.update(transform: arrived, target: target, timestamp: 7)?.position, next.position)
    }
    func testTrackingLossAndWorldJumpSuppressStaleWaypoints() throws {
        var planner = SubjectStepPlanner()
        let pose = camera(SIMD3(0, 1, 1))
        planner.recordSaved(transform: pose, target: target, timestamp: 1)
        let old = try XCTUnwrap(planner.update(transform: pose, target: target, timestamp: 2))
        XCTAssertNil(planner.update(transform: pose, target: target, timestamp: 3, trackingNormal: false))
        let moved = camera(SIMD3(0.25, 1, 1))
        XCTAssertNotEqual(planner.update(transform: moved, target: target, timestamp: 4)?.position, old.position)
        XCTAssertNil(planner.update(transform: camera(SIMD3(2, 1, 1)), target: target, timestamp: 5))
    }
    func testWalkDirectionsUseGravityEvenWithPortraitPhoneRoll() {
        let pose = camera(SIMD3(0, 1, 1))
        var rolled = pose; rolled.columns.0 = pose.columns.1; rolled.columns.1 = -pose.columns.0
        XCTAssertEqual(SubjectStepPlanner.motion(to: SIMD3(0.2, 1, 1), from: rolled), .right)
        XCTAssertEqual(SubjectStepPlanner.motion(to: SIMD3(0, 1.2, 1), from: rolled), .up)
        let opposite = camera(SIMD3(0, 1, -1))
        XCTAssertEqual(SubjectStepPlanner.motion(to: SIMD3(0.2, 1, -1), from: opposite), .left)
    }
    func testPersonAllowsUpperBodyInFrameAndKeepsSingleStableStep() throws {
        let person = ScanTargetBox(center: SIMD3<Float>(0, 0.85, 0), size: SIMD3<Float>(0.6, 1.7, 0.45), yawRadians: 0, source: "test", subject: "person")
        var pose = matrix_identity_float4x4; pose.columns.3 = SIMD4(0, 1.65, 0.7, 1)
        var planner = SubjectStepPlanner()
        planner.recordSaved(transform: pose, target: person, timestamp: 1)
        let next = try XCTUnwrap(planner.update(transform: pose, target: person, timestamp: 2))
        XCTAssertFalse(next.arrived)
        XCTAssertEqual(planner.update(transform: pose, target: person, timestamp: 3)?.position, next.position)
    }
    func testSpaceStepsRequireSavedViewsAndDetectNoNewFrames() {
        var guide = SpaceGuidance(), coverage = ScanCoverage()
        guide.update(transform: matrix_identity_float4x4, timestamp: 0)
        for i in 0..<6 {
            var pose = matrix_identity_float4x4; pose.columns.3.x = Float(i) * 0.2
            guide.update(transform: pose, timestamp: Double(i))
            guide.recordSaved(transform: pose, timestamp: Double(i))
        }
        XCTAssertEqual(guide.action(coverage: coverage, elapsed: 6).text, "镜头稍抬高，补拍上方")
        var up = simd_float4x4(simd_quatf(angle: 0.35, axis: SIMD3(1,0,0))); up.columns.3.x = 1
        guide.update(transform: up, timestamp: 6) // aiming alone does not count
        XCTAssertFalse(guide.upperSaved)
        guide.recordSaved(transform: up, timestamp: 6)
        XCTAssertTrue(guide.upperSaved)
        XCTAssertEqual(guide.action(coverage: coverage, elapsed: 7).symbol, "arrow.down")
        guide.update(transform: up, timestamp: 12)
        XCTAssertTrue(guide.action(coverage: coverage, elapsed: 12).warning)
        coverage.distanceFromStart = 2
        guide.recordSaved(transform: up, timestamp: 12)
        XCTAssertEqual(guide.action(coverage: coverage, elapsed: 65).text, "沿原路回到起点")
    }
}
