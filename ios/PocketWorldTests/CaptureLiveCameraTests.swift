import ARKit
import AVFoundation
import SwiftUI
import XCTest
@testable import PocketWorld

/// Explicit, attended, on-phone acceptance only. Uses the production capture view
/// and recorder. Nothing is uploaded; only this test's UUID is deleted at the end.
@MainActor final class CaptureLiveCameraTests: XCTestCase {
    func testLiveCalibrationDeviationAndRecovery() async throws {
        guard ProcessInfo.processInfo.environment["POCKETWORLD_LIVE_CAMERA_TEST"] == "1" else {
            throw XCTSkip("Opt in with POCKETWORLD_LIVE_CAMERA_TEST=1; requires an attended, unlocked iPhone.")
        }
        guard ARWorldTrackingConfiguration.isSupported,
              AVCaptureDevice.authorizationStatus(for:.video) == .authorized else {
            throw XCTSkip("Requires the real camera and existing camera permission.")
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let window = try XCTUnwrap(scene.windows.first { $0.isKeyWindow })
        var presenter = try XCTUnwrap(window.rootViewController)
        while let next = presenter.presentedViewController { presenter = next }
        let recorder = ARScanRecorder(), anchor = ScanAnchorController(), prompt = CameraProbePrompt()
        let id = UUID()
        var saved: URL?, cancelled = false
        let screen = ARScanCaptureView(onSaved:{ saved = $0 },onCancel:{ cancelled = true },recorder:recorder,anchor:anchor)
            .overlay(alignment:.top) { CameraProbeBanner(prompt:prompt).padding(.top,70) }
        let host = UIHostingController(rootView:screen)
        host.modalPresentationStyle = .fullScreen
        host.overrideUserInterfaceStyle = .dark
        await withCheckedContinuation { continuation in presenter.present(host,animated:false) { continuation.resume() } }
        var failure: Error?
        do {
            prompt.text = "实拍检查 1/3\n对准物体，缓慢移动手机完成定位"
            try await wait(30, "Camera did not reach stable tracking") { recorder.cameraReadiness.ready || cancelled }
            try require(!cancelled,"User cancelled live check")
            prompt.text = "正在锁定画面中心的物体\n请保持对准"
            try await wait(15,"No real surface at the centre") { anchor.placeAtCenter() }
            let target = try XCTUnwrap(anchor.target)
            let frame = try XCTUnwrap(recorder.session.currentFrame)
            let viewport = host.view.bounds.size
            let actual = try XCTUnwrap(CaptureFraming.project(target.simdCenter,cameraToWorld:frame.camera.transform,
                intrinsics:frame.camera.intrinsics,resolution:frame.camera.imageResolution,
                display:frame.displayTransform(for:.portrait,viewportSize:viewport)))
            let reference = frame.camera.projectPoint(target.simdCenter,orientation:.portrait,viewportSize:viewport)
            XCTAssertEqual(actual.x * viewport.width,reference.x,accuracy:1.0)
            XCTAssertEqual(actual.y * viewport.height,reference.y,accuracy:1.0)
            print("LIVE_CAMERA calibration_ready=true projection_matches_arkit=true")
            recorder.setTarget(target)
            recorder.start(captureID:id,mode:.object)
            try await wait(10,"Recording/framing did not become ready") { recorder.state == .recording && recorder.frameCount >= 8 && recorder.framing.acceptsKeyframe }
            prompt.text = "实拍检查 2/3\n缓慢向右转手机，让主体离开画面"
            try await wait(30,"Subject did not leave the actual screen") {
                if case .outside = recorder.framing.state { return true }
                return false
            }
            XCTAssertFalse(recorder.framing.acceptsKeyframe)
            let outsideCount = recorder.frameCount
            print("LIVE_CAMERA outside_detected=true training_frames_paused=true")
            prompt.text = "实拍检查 3/3\n按箭头找回主体，然后停稳"
            try await wait(30,"Subject did not recover to stable framing") { !recorder.framing.needsRecovery && recorder.framing.acceptsKeyframe }
            XCTAssertGreaterThan(recorder.frameCount,outsideCount,"Original video continues while training frames pause")
            prompt.text = "检查通过\n正在清理本次测试素材"
            print("LIVE_CAMERA recovered=true original_video_continuous=true")
        } catch { failure = error; prompt.text = "检查结束\n正在清理本次测试素材" }
        recorder.stop()
        try? await wait(30,"Recorder did not finish") { recorder.state != .recording && recorder.state != .saving && recorder.state != .requestingPermission }
        recorder.pausePreview()
        await withCheckedContinuation { continuation in host.dismiss(animated:false) { continuation.resume() } }
        if recorder.state != .saving && recorder.state != .recording {
            let root = try ARScanRecorder.packagesDirectory()
            for suffix in [".scan", ".partial"] {
                let folder = root.appendingPathComponent(id.uuidString.lowercased() + suffix)
                if FileManager.default.fileExists(atPath:folder.path) { try FileManager.default.removeItem(at:folder) }
            }
            if saved != nil { print("LIVE_CAMERA temporary_capture_removed=true") }
        } else { XCTFail("Capture still saving; preserved temporary data for recovery") }
        if let failure { throw failure }
    }

    private func wait(_ seconds: Double, _ message: String, until ready: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !ready() {
            guard Date() < deadline else { throw ProbeError(message:message) }
            try await Task.sleep(for:.milliseconds(100))
        }
    }
    private func require(_ condition: Bool, _ message: String) throws { if !condition { throw ProbeError(message:message) } }
    private struct ProbeError: LocalizedError { let message: String; var errorDescription:String? { message } }
}

@MainActor private final class CameraProbePrompt: ObservableObject { @Published var text = "正在打开真实相机" }
private struct CameraProbeBanner: View {
    @ObservedObject var prompt: CameraProbePrompt
    var body: some View {
        Text(prompt.text).font(.subheadline.weight(.semibold)).multilineTextAlignment(.center)
            .foregroundStyle(.white).padding(14).background(.black.opacity(0.75),in:RoundedRectangle(cornerRadius:18))
            .padding(.horizontal,20).allowsHitTesting(false)
    }
}
