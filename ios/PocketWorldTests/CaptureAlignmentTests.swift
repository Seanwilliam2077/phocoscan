import XCTest
import CoreGraphics
import simd
@testable import PocketWorld

final class CaptureAlignmentTests: XCTestCase {
    private let k = simd_float3x3(SIMD3<Float>(500,0,0),SIMD3<Float>(0,500,0),SIMD3<Float>(500,500,1))
    private let resolution = CGSize(width:1000,height:1000)
    func testCalibrationNeedsActualStableFramesAndValidIntrinsics() {
        var state = CaptureCameraReadiness()
        for i in 0...7 { state.update(normal:true,intrinsics:k,resolution:resolution,transform:matrix_identity_float4x4,features:40,timestamp:Double(i)*0.1) }
        XCTAssertFalse(state.ready)
        state.update(normal:true,intrinsics:k,resolution:resolution,transform:matrix_identity_float4x4,features:40,timestamp:0.9)
        XCTAssertTrue(state.ready)
        state.update(normal:false,intrinsics:k,resolution:resolution,transform:matrix_identity_float4x4,features:40,timestamp:1)
        XCTAssertFalse(state.ready)
        state.update(normal:true,intrinsics:k,resolution:resolution,transform:matrix_identity_float4x4,features:2,timestamp:1.1)
        XCTAssertEqual(state.state,.needsTexture)
        var invalid=k;invalid[0][0] = .nan
        state.update(normal:true,intrinsics:invalid,resolution:resolution,transform:matrix_identity_float4x4,features:40,timestamp:1.2)
        XCTAssertEqual(state.state,.invalidCamera)
    }
    func testClockGapsAndExcessiveMotionCannotFinishCalibration() {
        var state=CaptureCameraReadiness()
        state.update(normal:true,intrinsics:k,resolution:resolution,transform:matrix_identity_float4x4,features:40,timestamp:0)
        state.update(normal:true,intrinsics:k,resolution:resolution,transform:matrix_identity_float4x4,features:40,timestamp:8)
        XCTAssertFalse(state.ready,"waiting without camera frames isn't calibration")
        var pose=matrix_identity_float4x4;pose.columns.3.x=0.1
        state.update(normal:true,intrinsics:k,resolution:resolution,transform:pose,features:40,timestamp:8.1)
        XCTAssertEqual(state.state,.movingTooFast)
    }
    func testProjectionUsesDisplayCropAndPortraitRotation() throws {
        let center=try XCTUnwrap(CaptureFraming.project(SIMD3(0,0,-1),cameraToWorld:matrix_identity_float4x4,intrinsics:k,resolution:resolution,display:.identity))
        XCTAssertEqual(center.x,0.5,accuracy:1e-6);XCTAssertEqual(center.y,0.5,accuracy:1e-6)
        let rotated=CGAffineTransform(a:0,b:1,c:-1,d:0,tx:1,ty:0)
        let p=try XCTUnwrap(CaptureFraming.project(SIMD3(0.4,0,-1),cameraToWorld:matrix_identity_float4x4,intrinsics:k,resolution:resolution,display:rotated))
        XCTAssertEqual(p.x,0.5,accuracy:1e-6);XCTAssertEqual(p.y,0.7,accuracy:1e-6)
        XCTAssertEqual(CaptureFraming.direction(p),.down)
        let crop=CGAffineTransform(a:2,b:0,c:0,d:1,tx:-0.5,ty:0)
        let cropped=try XCTUnwrap(CaptureFraming.project(SIMD3(0.6,0,-1),cameraToWorld:matrix_identity_float4x4,intrinsics:k,resolution:resolution,display:crop))
        XCTAssertGreaterThan(cropped.x,1,"outside the cropped phone screen even when in sensor frame")
        XCTAssertNil(CaptureFraming.project(SIMD3(0,0,1),cameraToWorld:matrix_identity_float4x4,intrinsics:k,resolution:resolution,display:.identity))
    }
    func testDeviationImmediatelyRejectsFramesButDebouncesWarningAndRecovery() {
        var monitor=CaptureFraming()
        monitor.update(points:[CGPoint(x:0.5,y:0.5)],normal:true,timestamp:0)
        XCTAssertTrue(monitor.acceptsKeyframe)
        monitor.update(points:[CGPoint(x:1.1,y:0.5)],normal:true,timestamp:0.1)
        XCTAssertFalse(monitor.acceptsKeyframe);XCTAssertFalse(monitor.needsRecovery)
        monitor.update(points:[CGPoint(x:1.1,y:0.5)],normal:true,timestamp:0.3)
        monitor.update(points:[CGPoint(x:1.1,y:0.5)],normal:true,timestamp:0.51)
        XCTAssertEqual(monitor.state,.outside(.right))
        monitor.update(points:[CGPoint(x:0.5,y:0.5)],normal:true,timestamp:0.6)
        XCTAssertFalse(monitor.acceptsKeyframe);XCTAssertTrue(monitor.reacquiring);XCTAssertNil(monitor.correction)
        monitor.update(points:[CGPoint(x:0.5,y:0.5)],normal:true,timestamp:0.8)
        monitor.update(points:[CGPoint(x:0.5,y:0.5)],normal:true,timestamp:1.06)
        XCTAssertTrue(monitor.acceptsKeyframe);XCTAssertEqual(monitor.state,.aligned)
    }
    func testVisiblePortraitHeadDoesNotRequireWaistInFrameAndTrackingLossStopsFrames() {
        var monitor=CaptureFraming()
        monitor.update(points:[CGPoint(x:0.5,y:1.4),CGPoint(x:0.5,y:0.45)],normal:true,timestamp:0)
        XCTAssertTrue(monitor.acceptsKeyframe);XCTAssertEqual(monitor.marker,CGPoint(x:0.5,y:0.45))
        monitor.update(points:[CGPoint(x:0.5,y:0.45)],normal:false,timestamp:0.1)
        XCTAssertFalse(monitor.acceptsKeyframe);XCTAssertEqual(monitor.state,.tracking)
    }
    func testBehindCameraHasNoInventedLeftArrow() {
        var monitor=CaptureFraming()
        monitor.update(points:[],normal:true,timestamp:0)
        monitor.update(points:[],normal:true,timestamp:0.2)
        monitor.update(points:[],normal:true,timestamp:0.41)
        XCTAssertTrue(monitor.needsRecovery);XCTAssertNil(monitor.correction)
    }

    func testRollingThePhoneCannotCountAsStableCalibration() {
        var state = CaptureCameraReadiness()
        for i in 0...12 {
            let roll = simd_float4x4(simd_quatf(angle: Float(i) * 0.15, axis: SIMD3(0,0,1)))
            state.update(normal:true,intrinsics:k,resolution:resolution,transform:roll,features:40,timestamp:Double(i)*0.1)
        }
        XCTAssertEqual(state.state,.movingTooFast)
    }

    func testChangedCameraParametersRequireFreshStableFrames() {
        var state = CaptureCameraReadiness()
        for i in 0...12 { state.update(normal:true,intrinsics:k,resolution:resolution,transform:matrix_identity_float4x4,features:40,timestamp:Double(i)*0.1) }
        XCTAssertTrue(state.ready)
        var changed=k;changed[0][0] *= 1.1
        state.update(normal:true,intrinsics:changed,resolution:resolution,transform:matrix_identity_float4x4,features:40,timestamp:1.3)
        XCTAssertFalse(state.ready)
        state.update(normal:true,intrinsics:k,resolution:CGSize(width:CGFloat.infinity,height:1000),transform:matrix_identity_float4x4,features:40,timestamp:1.4)
        XCTAssertEqual(state.state,.invalidCamera)
    }

    func testReturningToFrameWhileMovingDoesNotResumeTraining() {
        var monitor = CaptureFraming()
        monitor.update(points:[],normal:false,timestamp:0)
        for i in 1...10 { monitor.update(points:[CGPoint(x:0.5,y:0.5)],normal:true,timestamp:Double(i)*0.1,steady:false) }
        XCTAssertTrue(monitor.reacquiring)
        XCTAssertFalse(monitor.acceptsKeyframe)
        XCTAssertNil(monitor.correction)
        for i in 11...16 { monitor.update(points:[CGPoint(x:0.5,y:0.5)],normal:true,timestamp:Double(i)*0.1,steady:true) }
        XCTAssertTrue(monitor.acceptsKeyframe)
    }

    func testMotionRejectsGapsAndInvalidPoses() {
        var motion = CaptureMotion()
        motion.update(pose:matrix_identity_float4x4,timestamp:0)
        XCTAssertFalse(motion.steady)
        motion.update(pose:matrix_identity_float4x4,timestamp:0.1)
        XCTAssertTrue(motion.steady)
        motion.update(pose:matrix_identity_float4x4,timestamp:1)
        XCTAssertFalse(motion.steady)
        var invalid=matrix_identity_float4x4;invalid[0][0] = 2
        motion.update(pose:invalid,timestamp:1.1)
        XCTAssertFalse(motion.steady)
    }
}
