import SwiftUI

/// Secondary validation library. Every item is an actual private server asset,
/// clearly separated from captures recorded by this iPhone.
struct ReconstructionStudyListView: View {
    @ObservedObject var cloud: CaptureV2UploadStore
    @Environment(\.dismiss) private var dismiss
    @State private var studies: [ReconstructionStudy] = []
    @State private var isLoading = false
    @State private var error: String?
    @State private var loadGeneration = UUID()
    @State private var loadedDestination: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("同一段外部 RGB 视频的真实重建结果，用于检查手机显示。不会计入成长记录，也不代表本机完成了扫描。")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                if isLoading { ProgressView("正在读取结果") }
                if let error {
                    Section {
                        Text(error).foregroundStyle(.red)
                        Button("重新读取") { Task { await refresh() } }.disabled(isLoading)
                    }
                }
                ForEach(studies) { study in
                    NavigationLink {
                        ReconstructionStudyDetailView(study: study, cloud: cloud)
                    } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(study.title).font(.headline)
                            Text(study.variants.map(\.title).joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary)
                            Text("外部视频 · 已有真实结果")
                                .font(.caption).foregroundStyle(.secondary)
                        }.padding(.vertical, 5)
                    }
                }
                if studies.isEmpty && !isLoading && error == nil {
                    ContentUnavailableView("暂无对照结果", systemImage: "cube.transparent",
                        description: Text("此账号还没有发布的测试模型。连接设置中的服务器后，由操作者导入本次真实的快速版和高质量版结果。"))
                }
                if let account = cloud.reconstructionAccountID {
                    Section {
                        Text(account).font(.caption.monospaced()).textSelection(.enabled)
                    } header: {
                        Text("测试账号编号")
                    } footer: {
                        Text("操作者可据此把结果分配给本账号；这里不显示登录令牌。")
                    }
                }
            }
            .navigationTitle("重建对照")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() } } }
            .refreshable { await refresh() }
            .task(id: cloud.connectedDestination) { await refresh() }
        }
    }

    @MainActor private func refresh() async {
        let generation = UUID()
        loadGeneration = generation
        let destination = cloud.connectedDestination
        if loadedDestination != destination {
            studies = []
            loadedDestination = destination
        }
        isLoading = true; error = nil
        defer { if generation == loadGeneration { isLoading = false } }
        do {
            let result = try await cloud.reconstructionStudies()
            try Task.checkCancellation()
            guard generation == loadGeneration, destination == cloud.connectedDestination else { return }
            studies = result
        } catch is CancellationError {
        } catch {
            guard generation == loadGeneration, destination == cloud.connectedDestination else { return }
            studies = []
            self.error = error.localizedDescription
        }
    }
}

private struct ReconstructionStudyDetailView: View {
    let study: ReconstructionStudy
    @State private var originalDestination: String?
    @ObservedObject var cloud: CaptureV2UploadStore
    @State private var requestedVariantID: String
    @State private var active: PreparedReconstructionVariant?
    @State private var lastPresented: PreparedReconstructionVariant?
    @State private var presentedVariantID: String?
    @State private var renderAttempt = UUID()
    @State private var renderFailure: String?
    @State private var isDownloading = false
    @State private var error: String?
    @State private var retryID = 0

    init(study: ReconstructionStudy, cloud: CaptureV2UploadStore) {
        self.study = study
        self.cloud = cloud
        _originalDestination = State(initialValue: cloud.connectedDestination)
        _requestedVariantID = State(initialValue: study.variants.first(where: { $0.role == "preview" })?.id
            ?? study.variants.first?.id ?? "")
    }

    private var requested: ReconstructionVariant? { study.variants.first { $0.id == requestedVariantID } }
    private var loadKey: String { "\(cloud.connectedDestination ?? "")/\(requestedVariantID)/\(retryID)" }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 9) {
                Picker("结果版本", selection: $requestedVariantID) {
                    ForEach(study.variants) { variant in Text(variant.title).tag(variant.id) }
                }.pickerStyle(.segmented)
                if let requested {
                    Text("\(requested.sizeLabel) · \(requested.pointCount.formatted()) 个高斯 · SH\(requested.shDegree)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if isDownloading {
                    ProgressView("正在下载并校验所选版本…").font(.caption)
                } else if let active, presentedVariantID != active.variant.id, renderFailure == nil {
                    Text("文件已校验，正在等待首帧显示…").font(.caption).foregroundStyle(.secondary)
                }
                if let active, requestedVariantID != active.variant.id {
                    Text("当前画面仍为\(active.variant.title)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let error {
                    HStack(alignment: .top) {
                        Text(error).font(.caption).foregroundStyle(.red)
                        Spacer()
                        Button("重试") { retryID += 1 }.disabled(isDownloading)
                    }
                }
                Text("外部视频对照 · 每个版本使用自己的重建相机；切换后回到该版本起点。")
                    .font(.caption2).foregroundStyle(.secondary)
            }.padding()
            if let active {
                let attempt = renderAttempt
                GaussianSceneView(url: active.modelURL, cameraPath: active.cameras,
                    onFailure: { handleRenderFailure($0, failed: active, attempt: attempt) },
                    onReady: { handlePresented(active, attempt: attempt) })
                    .id(attempt)
            } else {
                ContentUnavailableView("准备查看真实结果", systemImage: "cube.transparent",
                    description: Text("下载与校验完成后显示模型。高质量版保留完整 SH3 信息。"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(study.title)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: loadKey) { await openRequested() }
    }

    @MainActor private func openRequested() async {
        guard let requested else { return }
        let key = loadKey
        guard originalDestination == cloud.connectedDestination else {
            active = nil; lastPresented = nil; presentedVariantID = nil
            isDownloading = false
            error = ReconstructionStudyError.changedServer.localizedDescription
            return
        }
        isDownloading = true; error = nil
        defer { if key == loadKey { isDownloading = false } }
        do {
            let result = try await cloud.prepareReconstruction(study: study, variant: requested)
            try Task.checkCancellation()
            guard key == loadKey else { return }
            presentedVariantID = nil
            renderFailure = nil
            renderAttempt = UUID()
            active = result
        } catch is CancellationError {
        } catch {
            guard key == loadKey else { return }
            // Retain the last verified model on network or checksum failures.
            self.error = error.localizedDescription
        }
    }

    @MainActor private func handlePresented(_ result: PreparedReconstructionVariant, attempt: UUID) {
        guard attempt == renderAttempt, originalDestination == cloud.connectedDestination else { return }
        presentedVariantID = result.variant.id
        lastPresented = result
        renderFailure = nil
    }

    @MainActor private func handleRenderFailure(_ message: String,
                                                failed: PreparedReconstructionVariant, attempt: UUID) {
        guard attempt == renderAttempt, originalDestination == cloud.connectedDestination else { return }
        renderFailure = message
        presentedVariantID = nil
        error = "\(failed.variant.title)打开失败：\(message)"
        // Keep only the verified file reference, not both models' GPU resources.
        // Do not auto-retry a failed restoration of the same version.
        if let previous = lastPresented, previous.variant.id != failed.variant.id {
            error = "\(failed.variant.title)打开失败，正在恢复\(previous.variant.title)：\(message)"
            renderFailure = nil
            renderAttempt = UUID()
            active = previous
        }
    }
}
