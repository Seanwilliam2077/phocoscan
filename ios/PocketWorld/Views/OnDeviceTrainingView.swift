import SwiftUI
import simd

/// 本机重建: one row on the scan page to train a 3DGS on this iPhone and open it.
struct OnDeviceTrainingCard: View {
    let captureID: String
    let title: String
    let embedded: Bool
    @ObservedObject private var training = OnDeviceTrainingStore.shared
    @State private var confirm = false
    @State private var confirmDiscard = false
    @State private var confirmRetrain = false
    @State private var viewedResult: OnDeviceTrainingStore.Result?

    init(captureID: String, title: String, embedded: Bool = false) {
        self.captureID = captureID
        self.title = title
        self.embedded = embedded
    }

    private var phase: OnDeviceTrainingStore.Phase? { training.phases[captureID] }
    private var result: OnDeviceTrainingStore.Result? { training.result(captureID: captureID) }
    private var isRunning: Bool {
        switch phase {
        case .preparing, .training, .saving: return true
        default: return false
        }
    }

    var body: some View {
        Group {
            if embedded {
                content.padding(12)
                    .background(Theme.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            } else {
                Card { content }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("local.entry")
        .contextMenu { resultActions }
        .alert("重新进行本机重建？", isPresented: $confirmRetrain) {
            Button("取消", role: .cancel) {}
            Button("重新训练") { Task { await training.restart(captureID: captureID) } }
        } message: {
            Text(training.hasProgress(captureID)
                 ? "放弃本次未完成的进度，从头训练。原素材和已完成的结果会保留。"
                 : "使用原素材重新训练。当前结果仍可查看，完成后也会保留为上一版。")
        }
        .alert("放弃这次训练进度？", isPresented: $confirmDiscard) {
            Button("保留", role: .cancel) {}
            Button("放弃进度", role: .destructive) { Task { await training.cancelIfTraining(captureID: captureID) } }
        } message: { Text("已完成的 3DGS 和原始素材会保留。") }
        .alert("在这台手机上训练 3DGS？", isPresented: $confirm) {
            Button("取消", role: .cancel) {}
            Button("开始") { training.start(captureID: captureID) }
        } message: {
            Text("用这次扫描的清晰关键帧、手机记录的相机位置和 LiDAR 点云，在手机 GPU 上训练，耗时取决于扫描规模，不上传任何数据。训练时手机会发热。锁屏或切后台会保存进度，回来继续。")
        }
        .fullScreenCover(item: $viewedResult) { result in
            LocalTrainingViewer(captureID: captureID, title: title, result: result) { viewedResult = nil }
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "iphone.gen3")
                    .font(.body.weight(.semibold)).foregroundStyle(result != nil ? Theme.accent : Theme.tertiary)
                    .frame(width: 40, height: 40)
                    .background(Theme.surfaceHigh, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text("本机重建").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.text)
                    Text(subtitle).font(.caption).foregroundStyle(failed ? Theme.danger : Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .contentTransition(.numericText())
                }
                Spacer(minLength: 8)
                action
                if result != nil || training.hasProgress(captureID) {
                    Menu { resultActions } label: {
                        Image(systemName: "ellipsis").font(.body.weight(.semibold))
                            .foregroundStyle(Theme.secondary).frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("本机结果选项")
                    .accessibilityIdentifier("local.options")
                }
            }
            if case let .training(progress, _, _) = phase {
                ProgressView(value: progress).tint(Theme.accent)
                Text("锁屏自动暂停，回来继续。").font(.caption2).foregroundStyle(Theme.tertiary)
            }
        }
    }

    @ViewBuilder private var resultActions: some View {
        if result != nil {
            Button { confirmRetrain = true } label: { Label("重新训练", systemImage: "arrow.clockwise") }
                .disabled((training.isTraining && !isRunning) || !OnDeviceTrainingStore.canTrain(captureID: captureID))
                .accessibilityIdentifier("local.retrain")
        }
        if let previous = training.previousResult(captureID: captureID) {
            Button { viewedResult = previous } label: { Label("查看上一版", systemImage: "clock.arrow.circlepath") }
                .accessibilityIdentifier("local.previous")
        }
        if training.hasProgress(captureID) {
            Button(role: .destructive) { confirmDiscard = true } label: { Label("放弃训练进度", systemImage: "xmark.circle") }
        }
    }

    private var failed: Bool { if case .failed = phase { return true } else { return false } }

    private var subtitle: String {
        switch phase {
        case .preparing: return "正在准备关键帧…"
        case let .training(progress, secondsLeft, hot):
            var text = "训练中 \(Int(progress * 100))%"
            if let secondsLeft { text += secondsLeft >= 60 ? " · 剩约 \(Int((Double(secondsLeft) / 60).rounded(.up))) 分钟" : " · 剩不到 1 分钟" }
            if hot { text += " · 手机较热，已放慢" }
            return text
        case .saving: return "正在保存…"
        case .paused(let progress): return "已暂停 \(Int(progress * 100))% · 进度已保留"
        case .failed(let message): return message
        case nil:
            if let result {
                return "可以查看 · 用时 \(max(1, Int((Double(result.seconds) / 60).rounded()))) 分钟 · \(result.gaussians.formatted()) 个高斯点"
            }
            return OnDeviceTrainingStore.canTrain(captureID: captureID)
                ? "本机 · 无需上传"
                : OnDeviceTrainingStore.scanFolder(captureID).flatMap { TrainingDataset.unavailableReason(scanFolder: $0) } ?? "这台设备不支持本机训练"
        }
    }

    @ViewBuilder private var action: some View {
        if isRunning {
            HStack(spacing: 12) {
                if result != nil {
                    Button { viewedResult = result } label: { Image(systemName: "eye").foregroundStyle(Theme.text) }
                        .accessibilityLabel("查看已有结果").accessibilityIdentifier("local.open")
                }
                GhostButton(title: "暂停", tint: Theme.text) { training.pause() }
            }
        } else if training.hasProgress(captureID) {
            HStack(spacing: 12) {
                if result != nil {
                    Button { viewedResult = result } label: { Image(systemName: "eye").foregroundStyle(Theme.text) }
                        .accessibilityLabel("查看已有结果").accessibilityIdentifier("local.open")
                }
                GhostButton(title: "继续", tint: Theme.text) { training.start(captureID: captureID) }
                    .disabled(training.isTraining)
            }
        } else if result != nil {
            GhostButton(title: "查看", tint: Theme.text) { viewedResult = result }
                .accessibilityIdentifier("local.open")
        } else {
            GhostButton(title: failed ? "重试" : "生成", tint: Theme.text) { confirm = true }
                .disabled(training.isTraining || !OnDeviceTrainingStore.canTrain(captureID: captureID))
                .opacity(training.isTraining || !OnDeviceTrainingStore.canTrain(captureID: captureID) ? 0.5 : 1)
        }
    }
}

/// Full-screen viewer for the 本机重建 result. Its frame is the ARKit world, so the anchored
/// subject crops exactly (no alignment needed).
struct LocalTrainingViewer: View {
    let captureID: String
    let title: String
    let result: OnDeviceTrainingStore.Result
    let onClose: () -> Void
    @State private var cameras: SceneCameraPath?
    @State private var crop: SplatCrop?
    @State private var style = OrbitVideo.Style.orbit
    @State private var loaded = false
    @State private var presented = false

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            if loaded {
                GaussianSceneView(url: result.model, cameraPath: cameras,
                                  onFailure: { _ in presented = false }, onReady: { presented = true },
                                  crop: crop, videoStyle: style, showsTitle: false, subjectURL: result.subjectModel)
                    .ignoresSafeArea()
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("local.rendered." + result.model.deletingLastPathComponent().lastPathComponent)
                    .accessibilityValue(presented ? "已显示" : "加载中")
            } else {
                ProgressView().controlSize(.large).tint(.white)
            }
            VStack {
                HStack {
                    GlassIconButton(symbol: "xmark", label: "关闭", size: 40) { onClose() }
                    Spacer()
                    VStack(spacing: 2) {
                        Text(title).font(.subheadline.weight(.semibold))
                        Text("本机重建").font(.caption).foregroundStyle(.white.opacity(0.7))
                    }
                    .foregroundStyle(.white)
                    Spacer()
                    ShareLink(item: result.model) {
                        Image(systemName: "square.and.arrow.up").font(.body.weight(.semibold)).foregroundStyle(.white)
                            .frame(width: 40, height: 40).background(.ultraThinMaterial, in: Circle())
                            .environment(\.colorScheme, .dark)
                    }
                    .accessibilityLabel("分享 3DGS 文件")
                }
                .padding(.horizontal, 16).padding(.top, 8)
                Spacer()
            }
        }
        .task(id: result.id) {
            loaded = false; presented = false; cameras = nil; crop = nil
            let folder = OnDeviceTrainingStore.scanFolder(captureID)
            let path = (try? Data(contentsOf: result.cameras)).flatMap { try? JSONDecoder().decode(SceneCameraPath.self, from: $0) }
            let analysis = folder.flatMap { ScanAnalysis.load(from: $0) }
            cameras = path
            style = OrbitVideo.Style(mode: analysis?.mode)
            if let target = analysis?.targetBox {
                crop = SplatCrop(region: SplatCrop.region(for: target), rotation: matrix_identity_float3x3, scale: 1,
                                 translation: .zero, fitError: 0, matchedCameras: path?.frames.count ?? 0)
            }
            loaded = true
        }
    }
}
