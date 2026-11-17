import SwiftUI

/// The 3DGS versions of one verified scan: 快速预览 (feed-forward), 精细重建 (SfM → 3DGS) and
/// 位姿版 (trained in the cloud with the scan's ARKit poses). Nothing is generated until the
/// user asks for a version; each one is started, shown and retried on its own.
struct NativeReconstructionPanel: View {
    let captureID: String
    @ObservedObject var store: NativeReconstructionStore
    var title = "扫描"
    var subtitle = ""
    @Environment(\.scenePhase) private var scenePhase
    var sourceReady = true
    var showsHeading = true
    var includesLocalTraining = false
    var onShowGuide: (() -> Void)? = nil
    @State private var viewing: VersionDestination?
    private struct VersionDestination: Identifiable { let id: String }
    @State private var showConfirm = false
    @State private var retryTaskID: String?
    /// What the confirm alert is about: a role, or "both" on servers that cannot start one alone.
    @State private var confirmRole = "preview"
    private var result: NativeReconstruction? { store.result(captureID: captureID) }
    /// Generation stays disabled on older servers to avoid starting unselected versions.
    private var onlyBothTogether: Bool { result == nil && store.isConnected && !store.canSelectVersions }
    private var pollKey: String {
        [store.scopeKey ?? "", store.isConnected ? "online" : "offline",
         scenePhase == .active ? "active" : "background", sourceReady ? "verified" : "local",
         result?.tasks.map { $0.id + ":" + $0.status }.joined(separator: ",") ?? "none"].joined(separator: "/")
    }

    var body: some View {
        Card {
            if showsHeading {
                HStack {
                    Text(includesLocalTraining ? "3DGS 重建" : "云端重建").font(.headline).foregroundStyle(Theme.text)
                    Spacer()
                    if store.isBusy(captureID) { ProgressView().controlSize(.small).tint(Theme.accent) }
                    if let onShowGuide {
                        Button(action: onShowGuide) {
                            Image(systemName: "questionmark.circle").frame(width: 44, height: 44)
                        }.tint(Theme.secondary).accessibilityLabel("如何选择重建方式")
                    }
                }
            }
            if onlyBothTogether && sourceReady {
                Text("服务器更新后可单独生成所选版本。")
                    .font(.caption).foregroundStyle(Theme.secondary)
            }
            VStack(spacing: 10) {
                ForEach(NativeVersionRequest.videoRoles, id: \.self) { role in
                    if let task = result?.task(role: role) { taskRow(task) }
                    else { generateRow(role) }
                }
                if includesLocalTraining {
                    OnDeviceTrainingCard(captureID: captureID, title: title, embedded: true)
                }
            }
            if let task = result?.task(role: "arkit") { taskRow(task) }
            else {
                DisclosureGroup("位姿辅助重建") { arkitTrainingRow }
                    .font(.caption).foregroundStyle(Theme.secondary)
            }
            if store.keyframeUploadRoles[captureID] == "refined", let progress = store.keyframeUploadProgress[captureID] {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(progress == 0 ? "正在准备主体素材" : "正在上传主体素材 \(Int(progress * 100))%")
                        .font(.caption).foregroundStyle(Theme.secondary)
                }
            }
            if let error = store.errors[captureID] {
                Label(error, systemImage: "exclamationmark.circle.fill")
                    .font(.caption).foregroundStyle(Theme.danger)
            }
            if store.hasPendingRetry(captureID) {
                Text("重试请求已保存在本机，恢复连接后继续，不会重复创建任务。")
                    .font(.caption).foregroundStyle(Theme.tertiary)
            }
            if !store.isConnected && sourceReady {
                Text("离线时保留上次结果，连接服务器后继续。")
                    .font(.caption).foregroundStyle(Theme.tertiary)
            }
        }
        .task(id: pollKey) {
            guard sourceReady, store.isConnected, scenePhase == .active else { return }
            await store.refresh(captureID: captureID)
            while !Task.isCancelled && store.isConnected && scenePhase == .active {
                guard store.result(captureID: captureID)?.isPending == true
                        || store.hasPendingRetry(captureID) || store.hasPendingVersionRequest(captureID)
                        || store.hasPendingArkitTraining(captureID) else { break }
                do { try await Task.sleep(nanoseconds: 5_000_000_000) } catch { break }
                if !Task.isCancelled { await store.refresh(captureID: captureID) }
            }
        }
        .alert(retryTaskID != nil ? "重试\(NativeRoleName.long(confirmRole))？" : "生成\(NativeRoleName.long(confirmRole))？",
               isPresented: $showConfirm) {
            Button("取消", role: .cancel) { retryTaskID = nil }
            Button("同意并开始") {
                let role = confirmRole
                let failedID = retryTaskID
                retryTaskID = nil
                Task {
                    if let failedID {
                        await store.retry(captureID: captureID, failedTaskID: failedID)
                        return
                    }
                    switch role {
                    case "arkit": store.beginArkitTraining(captureID: captureID)
                    case "both": await store.generate(captureID: captureID, roles: NativeVersionRequest.videoRoles)
                    default: await store.generate(captureID: captureID, roles: [role])
                    }
                }
            }
        } message: {
            Text(confirmMessage)
        }
        .fullScreenCover(item: $viewing) { destination in
            NativeReconstructionViewer(captureID: captureID, store: store, title: title,
                                       subtitle: subtitle, initialRole: destination.id) { viewing = nil }
        }
    }

    private func taskRow(_ task: NativeReconstructionTask) -> some View {
        VariantRow(task: task, retryEnabled: store.isConnected && !store.isBusy(captureID),
                   downloaded: task.result.map { store.isDownloaded($0.id) } ?? false,
                   downloadError: task.result.flatMap { store.downloadErrors[$0.id] },
                   onOpen: { viewing = VersionDestination(id: task.role) }) {
            confirmRole = task.role
            retryTaskID = task.id
            showConfirm = true
        }
    }
}

/// User-facing names of the three results. The algorithms stay in the data
/// (`gs_worldmirror2`, SfM → `gs_mcmc`, `gs_mcmc_arkit_prior`); the app shows these.
enum NativeRoleName {
    static func order(_ role: String) -> Int { ["preview": 0, "refined": 1, "arkit": 2][role] ?? 3 }
    static func long(_ role: String) -> String {
        switch role {
        case "refined": return "精细重建"
        case "arkit": return "位姿版"
        default: return "快速预览"
        }
    }
    static func short(_ role: String) -> String {
        switch role {
        case "refined": return "精细"
        case "arkit": return "位姿"
        default: return "快速"
        }
    }
    static func symbol(_ role: String) -> String {
        ["preview": "bolt.fill", "arkit": "location.viewfinder"][role] ?? "sparkles"
    }
}

extension NativeReconstructionPanel {
    /// This scan has the keyframe package (recorded after the keyframe update) and the server
    /// trains the 位姿版 from it.
    var usesKeyframes: Bool { store.trainsFromKeyframes && hasKeyframePackage }
    private var hasKeyframePackage: Bool {
        guard let folder = try? ARScanRecorder.packagesDirectory().appendingPathComponent(captureID + ".scan") else { return false }
        return FileManager.default.fileExists(atPath: folder.appendingPathComponent("capture/transforms.json").path)
    }
    var isPortraitScan: Bool {
        guard let folder = try? ARScanRecorder.packagesDirectory().appendingPathComponent(captureID + ".scan") else { return false }
        return ScanAnalysis.load(from: folder)?.mode == ScanMode.portrait.rawValue
    }

    /// What the user agrees to in the confirm alert, per version.
    var confirmMessage: String {
        let terms = "不会重复增加成长；本次不授予模型训练许可。"
        switch confirmRole {
        case "arkit":
            return usesKeyframes
                ? "先上传这次扫描里最多 64 张清晰关键帧\(isPortraitScan ? "和人物遮罩" : "")，再在 A10 服务器上用它们和手机记录的 ARKit 相机位置训练位姿版 3DGS。只生成这一个版本，\(terms)"
                : "在 A10 服务器上，用这次扫描已核验的原片和手机记录的 ARKit 相机位置（作为位置先验）训练位姿版 3DGS。只生成这一个版本，\(terms)"
        case "both":
            return "这台服务器不能单独选择版本：会用这次已核验的原片与相机信息，分别生成快速预览和精细重建 3DGS。两份结果\(terms)"
        case "refined":
            return "用这次已核验的原片与相机信息，在服务器上生成精细重建 3DGS，耗时比快速预览长。只生成这一个版本，\(terms)"
        default:
            return "用这次已核验的原片与相机信息，在服务器上生成快速预览 3DGS。只生成这一个版本，\(terms)"
        }
    }

    /// 快速预览 or 精细重建 that has not been asked for yet.
    func generateRow(_ role: String) -> some View {
        let pending = store.isVersionRequested(captureID, role: role)
        return VersionOptionRow(
            role: role,
            caption: !sourceReady ? "上传采集数据后可生成"
                : !store.isConnected ? "连接服务器后可生成"
                : !store.canSelectVersions ? "服务器暂不支持单独生成"
                : role == "refined" ? "云端 · 细节优先" : "云端 · 速度优先",
            buttonTitle: pending ? "继续" : "生成",
            enabled: sourceReady && store.canSelectVersions && !store.isBusy(captureID)) {
                if pending { Task { await store.generate(captureID: captureID, roles: [role]) } }
                else { confirmRole = role; showConfirm = true }
            }
    }

    /// 位姿版, trained in the cloud from the scan's own ARKit poses (and its keyframes, when the
    /// scan has them). It can be the only version of a scan.
    var arkitTrainingRow: some View {
        // Without a reconstruction yet, the server must be able to open one with no other version.
        let available = sourceReady && store.canTrainArkitInCloud && (result != nil || store.canSelectVersions)
        let pending = store.hasPendingArkitTraining(captureID)
        let uploading = store.keyframeUploadRoles[captureID] == "arkit" ? store.keyframeUploadProgress[captureID] : nil
        return VersionOptionRow(
            role: "arkit",
            caption: uploading.map { "正在上传关键帧 \(Int($0 * 100))%" }
                ?? (!sourceReady ? "上传采集数据后可生成" : !available ? (store.isConnected ? "服务器暂不支持" : "连接服务器后可生成")
                    : usesKeyframes ? "用手机关键帧和相机位置训练" : "用手机记录的相机位置训练"),
            buttonTitle: uploading != nil ? "暂停" : pending ? "继续" : "生成",
            enabled: uploading != nil || available && !store.isBusy(captureID)) {
                if uploading != nil { store.pauseKeyframeUpload(captureID: captureID) }
                else if pending { store.beginArkitTraining(captureID: captureID) }
                else { confirmRole = "arkit"; showConfirm = true }
            }
    }
}

/// A version that does not exist yet: its name, one line about it and a 生成 button.
private struct VersionOptionRow: View {
    let role: String
    let caption: String
    let buttonTitle: String
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: NativeRoleName.symbol(role))
                .font(.body.weight(.semibold)).foregroundStyle(Theme.tertiary)
                .frame(width: 40, height: 40)
                .background(Theme.surfaceHigh, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(NativeRoleName.long(role)).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.text)
                Text(caption).font(.caption).foregroundStyle(Theme.secondary)
                    .contentTransition(.numericText())
            }
            Spacer()
            GhostButton(title: buttonTitle, tint: Theme.text, action: action)
                .disabled(!enabled).opacity(enabled ? 1 : 0.5)
        }
        .padding(12)
        .background(Theme.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct VariantRow: View {
    let task: NativeReconstructionTask
    let retryEnabled: Bool
    let downloaded: Bool
    var downloadError: String? = nil
    let onOpen: () -> Void
    let onRetry: () -> Void

    private var statusText: String {
        if task.status == "ready" { return downloaded ? "已下载 · 可离线查看" : downloadError ?? "已生成 · 打开时下载" }
        return task.statusLabel
    }

    private var isPreview: Bool { task.role == "preview" }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: NativeRoleName.symbol(task.role))
                .font(.body.weight(.semibold))
                .foregroundStyle(isPreview ? Theme.accentEnd : Theme.accent)
                .frame(width: 40, height: 40)
                .background(Theme.surfaceHigh, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(NativeRoleName.long(task.role)).font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.text)
                Text(statusText).font(.caption)
                    .foregroundStyle(task.canRetry ? Theme.danger : Theme.secondary)
            }
            Spacer()
            if task.isPending {
                ProgressView().controlSize(.small).tint(Theme.accent)
            } else if task.status == "ready" {
                GhostButton(title: downloadError == nil ? "查看" : "重新下载", tint: Theme.text, action: onOpen)
                    .accessibilityLabel("查看\(NativeRoleName.long(task.role))结果")
                    .accessibilityHint(downloadError == nil ? "" : "只重新下载已有结果，不会重新训练")
                    .accessibilityIdentifier("version.open." + task.role)
            } else if task.canRetry {
                GhostButton(title: "重试", tint: Theme.text, action: onRetry)
                    .disabled(!retryEnabled).opacity(retryEnabled ? 1 : 0.5)
            }
        }
        .padding(12)
        .background(Theme.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

/// Shared selection state: the picker and attended device acceptance use the same
/// transition. A completed Metal frame must belong to the currently requested role.
@MainActor final class NativeViewerSelection: ObservableObject {
    @Published var role: String { didSet { if role != oldValue { displayedResultID = nil } } }
    @Published private(set) var displayedResultID: String?
    init(role: String) { self.role = role }
    func clear() { displayedResultID = nil }
    func presented(role: String, resultID: String) {
        guard role == self.role else { return }
        displayedResultID = resultID
    }
}

/// Full-screen viewer: the model fills the screen, controls float on top.
struct NativeReconstructionViewer: View {
    let captureID: String
    @ObservedObject var store: NativeReconstructionStore
    let title: String
    let subtitle: String
    let onClose: () -> Void
    @Environment(\.scenePhase) private var scenePhase
    @State private var confirmGeneration: GenerationChoice?
    private struct GenerationChoice { let role: String; let failedTaskID: String? }
    @State private var sheetHeight: CGFloat = 220
    @State private var exportURL: URL?
    @State private var originalScope: String?
    @StateObject private var selection: NativeViewerSelection
    private var requestedRole: String {
        get { selection.role }
        nonmutating set { selection.role = newValue }
    }
    @State private var originalExport: URL?
    @State private var exportingOriginal = false
    @State private var active: PreparedReconstructionVariant?
    @State private var presentedID: String?
    @State private var renderAttempt = UUID()
    @State private var renderFailure: String?
    @State private var isLoading = false
    @State private var error: String?
    @State private var retry = 0
    /// Crop to the anchored subject for the result on screen (computed off the main thread).
    @State private var crop: SplatCrop?
    @State private var cropFor: String?
    private var scanFolder: URL? { try? ARScanRecorder.packagesDirectory().appendingPathComponent(captureID + ".scan") }
    private var videoStyle: OrbitVideo.Style { OrbitVideo.Style(mode: scanFolder.flatMap { ScanAnalysis.load(from: $0) }?.mode) }
    init(captureID: String, store: NativeReconstructionStore, title: String, subtitle: String,
         initialRole: String? = nil, selection: NativeViewerSelection? = nil, onClose: @escaping () -> Void) {
        self.captureID = captureID; self.store = store; self.onClose = onClose
        self.title = title; self.subtitle = subtitle
        _originalScope = State(initialValue: store.scopeKey)
        // Open on a version that is ready (快速预览 first), else on the first one that exists.
        let tasks = (store.result(captureID: captureID)?.tasks ?? [])
            .sorted { NativeRoleName.order($0.role) < NativeRoleName.order($1.role) }
        _selection = StateObject(wrappedValue: selection ?? NativeViewerSelection(role: NativeViewerVersionAction.initialRole(preferred: initialRole, tasks: tasks)))
    }
    private var result: NativeReconstruction? { store.result(captureID: captureID) }
    private var roles: [String] { NativeViewerVersionAction.roles(in: result) }
    private var versionAction: NativeViewerVersionAction {
        .selected(role: requestedRole, in: result, requested: store.isVersionRequested(captureID, role: requestedRole))
    }
    private var needsSync: Bool {
        result?.isPending == true || store.hasPendingVersionRequest(captureID)
            || store.hasPendingRetry(captureID) || store.hasPendingArkitTraining(captureID)
    }
    private var requested: ReconstructionVariant? { result?.task(role: requestedRole)?.result }
    private var loadKey: String { "\(store.scopeKey ?? "")/\(requestedRole)/\(requested?.id ?? "pending")/\(requested?.sha256 ?? "")/\(retry)" }
    private var pollKey: String { "\(store.scopeKey ?? "")/\(store.isConnected)/\(scenePhase == .active)/\(needsSync)" }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            if let active, active.variant.role == requestedRole, cropFor == active.variant.id {
                let attempt = renderAttempt
                GaussianSceneView(url: active.modelURL, cameraPath: active.cameras,
                    onFailure: { failed($0, result: active, attempt: attempt) },
                    onReady: { presented(active, attempt: attempt) },
                    bottomInset: sheetHeight,
                    onPoster: { ScanPosterStore.shared.save($0, captureID: captureID) },
                    crop: crop, videoStyle: videoStyle).id(attempt)
                    .ignoresSafeArea()
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("rendered." + active.variant.id)
                    .accessibilityValue(presentedID == active.variant.id ? "已显示" : "加载中")
            } else if active != nil {
                ProgressView().controlSize(.large).tint(.white).padding(.bottom, sheetHeight)
            } else {
                VStack(spacing: 14) {
                    if isLoading {
                        ProgressView().controlSize(.large).tint(.white)
                        Text("正在下载并校验 3DGS…").font(.subheadline).foregroundStyle(Theme.secondary)
                    } else {
                        Image(systemName: "cube.transparent").font(.system(size: 44)).foregroundStyle(Theme.tertiary)
                        Text(result?.task(role: requestedRole)?.statusLabel ?? "尚未生成\(NativeRoleName.long(requestedRole))")
                            .font(.headline).foregroundStyle(Theme.text)
                        Text(versionAction == .generate ? "点击下方按钮开始" : "生成完成后会显示在这里。")
                            .font(.subheadline).foregroundStyle(Theme.secondary)
                            .multilineTextAlignment(.center)
                    }
                }
                .padding(.horizontal, 32)
                .padding(.bottom, sheetHeight)
            }
            VStack(spacing: 0) {
                topBar
                Spacer()
                bottomSheet
            }
        }
        .task(id: loadKey) { await openRequested() }
        .task(id: active?.variant.id) { exportURL = active.flatMap(makeExportCopy); originalExport = nil }
        .task(id: active?.variant.id) {
            // Fit the result's cameras to this scan's ARKit poses once per result.
            guard let active, let folder = scanFolder else { cropFor = active?.variant.id; crop = nil; return }
            let cameras = active.cameras
            let value = await Task.detached(priority: .userInitiated) { SplatCrop.load(scanFolder: folder, cameraPath: cameras) }.value
            guard !Task.isCancelled, self.active?.variant.id == active.variant.id, requestedRole == active.variant.role else { return }
            crop = value
            cropFor = active.variant.id
        }
        .task(id: pollKey) {
            guard store.isConnected, scenePhase == .active, originalScope == store.scopeKey else { return }
            await store.refresh(captureID: captureID)
            while !Task.isCancelled && store.isConnected && scenePhase == .active
                    && originalScope == store.scopeKey && needsSync {
                do { try await Task.sleep(nanoseconds: 5_000_000_000) } catch { break }
                if !Task.isCancelled { await store.refresh(captureID: captureID) }
            }
        }
        .alert("生成\(NativeRoleName.long(confirmGeneration?.role ?? requestedRole))？",
               isPresented: Binding(get: { confirmGeneration != nil }, set: { if !$0 { confirmGeneration = nil } })) {
            Button("取消", role: .cancel) { confirmGeneration = nil }
            Button("开始生成") {
                guard let choice = confirmGeneration else { return }
                confirmGeneration = nil
                Task {
                    if let taskID = choice.failedTaskID { await store.retry(captureID: captureID, failedTaskID: taskID) }
                    else { await store.generate(captureID: captureID, roles: [choice.role]) }
                }
            }
        } message: {
            Text("使用这次扫描已上传的素材，只生成所选版本。已有结果会保留。")
        }
    }

    private var topBar: some View {
        VStack(spacing: 10) {
            HStack {
                GlassIconButton(symbol: "chevron.down", label: "关闭", size: 40, action: onClose)
                Spacer()
                if let active, active.variant.role == requestedRole {
                    ShareLink(item: exportURL ?? active.modelURL) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                            .frame(width: 40, height: 40)
                            .background(.ultraThinMaterial, in: Circle())
                            .environment(\.colorScheme, .dark)
                    }
                    .accessibilityLabel("分享 3DGS 文件")
                }
            }
            if let active, active.variant.role == requestedRole, presentedID != active.variant.id, renderFailure == nil {
                banner(icon: "hourglass", text: "文件已校验，正在等待首帧…", tint: Theme.accent)
            }
            if active != nil && !store.isConnected {
                banner(icon: "wifi.slash", text: "离线查看：手机上已校验的副本", tint: Theme.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    /// Result identity, version switch and export action.
    private var bottomSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Capsule().fill(.white.opacity(0.25)).frame(width: 36, height: 5)
                .frame(maxWidth: .infinity)
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.headline).foregroundStyle(Theme.text).lineLimit(1)
                    Text(detailLine).font(.caption).foregroundStyle(Theme.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
            }
            if roles.count > 1 { variantPicker }
            selectedVersionControls
            if let message = store.errors[captureID] {
                Text(message).font(.caption).foregroundStyle(Theme.danger)
            }
            if let error {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning)
                    Text(error).font(.caption).foregroundStyle(.white)
                    Spacer(minLength: 4)
                    Button("重新打开") { retry += 1 }
                        .font(.caption.weight(.semibold))
                        .disabled(isLoading)
                }
                .padding(12)
                .background(Theme.surfaceHigh, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            if let active, active.variant.role == requestedRole {
                ShareLink(item: exportURL ?? active.modelURL) {
                    GradientLabel(title: "导出 3DGS", symbol: "square.and.arrow.up")
                }
                .buttonStyle(.plain)
                if active.variant.mobile != nil {
                    if let originalExport { ShareLink("导出原始 PLY", item: originalExport) }
                    else {
                        Button(exportingOriginal ? "正在下载原始文件…" : "下载原始 PLY（保留完整 SH）") {
                            exportingOriginal = true
                            Task {
                                defer { exportingOriginal = false }
                                do {
                                    let url = try await ReconstructionSync.shared.cloud.imageAPI.originalNativeResult(active.variant, captureID: captureID)
                                    if self.active?.variant.id == active.variant.id { originalExport = url }
                                }
                                catch { if self.active?.variant.id == active.variant.id { self.error = error.localizedDescription } }
                            }
                        }.disabled(exportingOriginal)
                    }
                }
                Text("导出当前显示的\(NativeRoleName.long(active.variant.role)) · \(active.modelURL.pathExtension.uppercased()) 文件，已通过完整性校验")
                    .font(.caption2).foregroundStyle(Theme.tertiary)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background {
            UnevenRoundedRectangle(topLeadingRadius: 28, topTrailingRadius: 28, style: .continuous)
                .fill(Theme.surface)
                .overlay(UnevenRoundedRectangle(topLeadingRadius: 28, topTrailingRadius: 28, style: .continuous)
                    .stroke(Theme.stroke))
                .ignoresSafeArea(edges: .bottom)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { sheetHeight = $0 }
    }

    @ViewBuilder private var selectedVersionControls: some View {
        switch versionAction {
        case .generate, .resume:
            GradientButton(title: (versionAction == .resume ? "继续生成" : "生成") + NativeRoleName.long(requestedRole),
                           symbol: NativeRoleName.symbol(requestedRole),
                           isEnabled: store.canSelectVersions && !store.isBusy(captureID)) {
                if versionAction == .resume { let role = requestedRole; Task { await store.generate(captureID: captureID, roles: [role]) } }
                else { confirmGeneration = GenerationChoice(role: requestedRole, failedTaskID: nil) }
            }
            if !store.canSelectVersions {
                Text(store.isConnected ? "服务器暂不支持单独生成" : "连接服务器后可生成")
                    .font(.caption).foregroundStyle(Theme.secondary)
            }
        case .retry(let id):
            Text(result?.task(role: requestedRole)?.statusLabel ?? "生成失败")
                .font(.caption).foregroundStyle(Theme.secondary)
            GradientButton(title: "重试" + NativeRoleName.long(requestedRole), symbol: "arrow.clockwise",
                           isEnabled: store.isConnected && !store.isBusy(captureID)) {
                confirmGeneration = GenerationChoice(role: requestedRole, failedTaskID: id)
            }
        case .waiting:
            HStack {
                ProgressView().tint(Theme.accent)
                Text(NativeRoleName.long(requestedRole) + " · " + (result?.task(role: requestedRole)?.statusLabel ?? "重建中"))
                    .font(.subheadline).foregroundStyle(Theme.secondary)
            }
        case .blocked:
            Text(result?.task(role: requestedRole)?.statusLabel ?? "等待状态确认")
                .font(.caption).foregroundStyle(Theme.secondary)
        case .ready: EmptyView()
        }
    }

    /// Hard-links the verified cached model under a readable name for sharing.
    private func makeExportCopy(_ prepared: PreparedReconstructionVariant) -> URL? {
        let manager = FileManager.default
        let folder = manager.temporaryDirectory.appendingPathComponent("Export", isDirectory: true)
        let unsafe = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let base = title.components(separatedBy: unsafe).joined(separator: "-")
        let role = NativeRoleName.long(prepared.variant.role)
        let target = folder.appendingPathComponent("\(base)-\(role).\(prepared.modelURL.pathExtension)")
        do {
            try manager.createDirectory(at: folder, withIntermediateDirectories: true)
            if manager.fileExists(atPath: target.path) { try manager.removeItem(at: target) }
            do { try manager.linkItem(at: prepared.modelURL, to: target) }
            catch { try manager.copyItem(at: prepared.modelURL, to: target) }
            return target
        } catch {
            return nil
        }
    }

    private var detailLine: String {
        var parts: [String] = []
        if !subtitle.isEmpty { parts.append(subtitle) }
        if let requested {
            parts.append(requested.sizeLabel)
            parts.append("\(requested.pointCount.formatted()) 高斯")
        }
        return parts.joined(separator: " · ")
    }

    private var variantPicker: some View {
        HStack(spacing: 4) {
            ForEach(roles, id: \.self) { role in
                let task = result?.task(role: role)
                Button { requestedRole = role } label: {
                    HStack(spacing: 6) {
                        Circle().fill(dotColor(task)).frame(width: 7, height: 7)
                        Text(NativeRoleName.short(role)).font(.subheadline.weight(.semibold))
                    }
                    .foregroundStyle(requestedRole == role ? Color.black : Color.white)
                    .frame(maxWidth: .infinity).frame(minHeight: 44)
                    .background {
                        if requestedRole == role { Capsule().fill(.white) }
                    }
                }
                .buttonStyle(.plain).accessibilityIdentifier("version.switch." + role)
            }
        }
        .padding(3)
        .background(.ultraThinMaterial, in: Capsule())
        .environment(\.colorScheme, .dark)
    }

    private func dotColor(_ task: NativeReconstructionTask?) -> Color {
        guard let task else { return Theme.tertiary }
        if task.status == "ready" { return Theme.success }
        if task.isPending { return Theme.accent }
        if task.canRetry { return Theme.danger }
        return Theme.tertiary
    }

    private func banner(icon: String, text: String, tint: Color) -> some View {
        Label(text, systemImage: icon)
            .font(.caption).foregroundStyle(.white)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(.black.opacity(0.6), in: Capsule())
            .overlay(Capsule().stroke(tint.opacity(0.4)))
    }

    @MainActor private func openRequested() async {
        let key = loadKey
        selection.clear()
        active = nil; presentedID = nil
        crop = nil; cropFor = nil; exportURL = nil; originalExport = nil
        renderAttempt = UUID(); renderFailure = nil
        guard originalScope == store.scopeKey else {
            active = nil; presentedID = nil; isLoading = false
            error = ReconstructionStudyError.changedServer.localizedDescription; return
        }
        guard let requested else { isLoading = false; error = nil; return }
        isLoading = true; error = nil
        defer { if key == loadKey { isLoading = false } }
        do {
            let prepared = try await store.prepare(captureID: captureID, variant: requested)
            try Task.checkCancellation()
            guard key == loadKey, originalScope == store.scopeKey else { return }
            renderAttempt = UUID(); renderFailure = nil; presentedID = nil; active = prepared
        } catch is CancellationError {
        } catch { if key == loadKey { self.error = error.localizedDescription } }
    }
    @MainActor private func presented(_ result: PreparedReconstructionVariant, attempt: UUID) {
        guard attempt == renderAttempt, result.variant.role == requestedRole, originalScope == store.scopeKey else { return }
        presentedID = result.variant.id; renderFailure = nil
        selection.presented(role: result.variant.role, resultID: result.variant.id)
    }
    @MainActor private func failed(_ message: String, result: PreparedReconstructionVariant, attempt: UUID) {
        guard attempt == renderAttempt, result.variant.role == requestedRole, originalScope == store.scopeKey else { return }
        renderFailure = message; presentedID = nil; selection.clear()
        error = "\(result.variant.title)打开失败：\(message)"

    }
}
