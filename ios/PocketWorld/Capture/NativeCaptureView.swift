import AVFoundation
import SwiftUI
import UIKit

struct NativeCaptureView: View {
    let sessionID: String?
    let onSaved: (CapturedVideo) -> Void
    let onCancel: () -> Void
    @StateObject private var camera = NativeCameraController()
    @State private var stamps: Set<Int> = []

    private let guides = [
        ("站稳看一眼", "让同一组物体留在画面里，先稳定拍几秒。", "viewfinder"),
        ("慢慢换个位置", "向侧面走一两步，保持相邻画面重叠。", "figure.walk"),
        ("照顾低处", "缓慢降低手机，补上地面和物体底部。", "arrow.down.right")
    ]

    init(sessionID: String? = nil, onSaved: @escaping (CapturedVideo) -> Void,
         onCancel: @escaping () -> Void) {
        self.sessionID = sessionID
        self.onSaved = onSaved
        self.onCancel = onCancel
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            CameraPreview(session: camera.session).ignoresSafeArea()
            LinearGradient(colors: [.black.opacity(0.6), .clear, .black.opacity(0.8)],
                           startPoint: .top, endPoint: .bottom).ignoresSafeArea()
            VStack(spacing: 16) {
                HStack {
                    Button(camera.isRecording ? "保存并退出" : "返回") {
                        if camera.isRecording { camera.stopRecording() }
                        else { onCancel() }
                    }
                    .disabled(camera.isSaving)
                    Spacer()
                    Label("风景邮票", systemImage: "camera.macro")
                }
                .font(.headline)
                if let message = camera.interruptionMessage { Text(message).font(.callout) }
                Spacer()
                if camera.denied {
                    VStack(spacing: 14) {
                        Image(systemName: "camera.fill").font(.largeTitle)
                        Text("需要相机，才能带回一小片风景。")
                        Button("前往设置开启相机") {
                            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                        }.buttonStyle(.borderedProminent)
                        Text("只使用后置相机，不录音。也可以返回任务选择外部扫描。")
                            .font(.footnote).multilineTextAlignment(.center)
                    }.padding().background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 24))
                }
                if let error = camera.errorMessage {
                    Text(error).font(.callout).padding()
                        .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 16))
                }
                Spacer()
                VStack(alignment: .leading, spacing: 10) {
                    Text("三枚探索印章").font(.headline)
                    ForEach(Array(guides.enumerated()), id: \.offset) { index, guide in
                        Button {
                            if camera.isRecording { stamps.insert(index) }
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: stamps.contains(index) ? "checkmark.seal.fill" : guide.2)
                                    .font(.title2).frame(width: 34)
                                    .foregroundStyle(stamps.contains(index) ? .mint : .white)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(guide.0).font(.subheadline.bold())
                                    Text(guide.1).font(.caption).foregroundStyle(.white.opacity(0.8))
                                }
                                Spacer(minLength: 0)
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(!camera.isRecording)
                    }
                    Text("完成动作后点亮印章。这是你的确认，尚未自动检测覆盖质量。")
                        .font(.caption2).foregroundStyle(.white.opacity(0.7))
                }
                .padding(16).background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 22))
                HStack(spacing: 26) {
                    VStack(alignment: .leading, spacing: 3) {
                        if let start = camera.recordingStartedAt, camera.isRecording {
                            Text(start, style: .timer).monospacedDigit().font(.title3.bold())
                        } else { Text("约 60—90 秒").font(.subheadline.bold()) }
                        Text("避开路人 · 注意脚下").font(.caption)
                    }
                    Spacer()
                    Button {
                        if camera.isRecording { camera.stopRecording() }
                        else { stamps.removeAll(); camera.startRecording() }
                    } label: {
                        ZStack {
                            Circle().stroke(.white, lineWidth: 4).frame(width: 76, height: 76)
                            if camera.isSaving { ProgressView().tint(.white) }
                            else if camera.isRecording {
                                RoundedRectangle(cornerRadius: 6).fill(.red).frame(width: 30, height: 30)
                            } else { Circle().fill(.red).frame(width: 62, height: 62) }
                        }
                    }
                    .accessibilityLabel(camera.isRecording ? "停止并保存录像" : "开始录像")
                    .disabled(!camera.ready || camera.isSaving)
                }
            }
            .padding(22).foregroundStyle(.white)
        }
        .interactiveDismissDisabled(camera.isRecording || camera.isSaving)
        .onAppear { camera.sessionID = sessionID; camera.onSaved = onSaved; camera.prepare() }
        .onDisappear { camera.shutdown() }
    }
}

private final class PreviewSurface: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    override func layoutSubviews() {
        super.layoutSubviews()
        if let connection = previewLayer.connection, connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90
        }
    }
}

private struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    func makeUIView(context: Context) -> PreviewSurface {
        let view = PreviewSurface()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }
    func updateUIView(_ uiView: PreviewSurface, context: Context) {}
    static func dismantleUIView(_ uiView: PreviewSurface, coordinator: ()) {
        uiView.previewLayer.session = nil
    }
}
