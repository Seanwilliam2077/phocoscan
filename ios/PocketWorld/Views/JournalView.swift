import SwiftUI
import AVKit
import UniformTypeIdentifiers

struct JournalView: View {
    @EnvironmentObject private var store: GameStore
    @State private var pendingDestination: String?
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack { Text("风景邮袋").font(.system(size: 30, weight: .bold, design: .rounded)); Spacer(); if store.isBusy { ProgressView() } }
                    Text("草稿留在手机，寄出的风景在这里等你。制作失败也不会收回已经获得的卡片。")
                        .foregroundStyle(Palette.muted).font(.subheadline)
                    if store.state.pendingRequest != nil {
                        Panel {
                            Label("一次任务创建还没确认", systemImage: "arrow.clockwise.circle")
                            Text("可能是连接中断。重试会沿用同一个任务编号，不会重复创建。").font(.caption).foregroundStyle(Palette.muted)
                            Button("继续上次创建") { Task { pendingDestination = await store.retryPendingSession() } }.disabled(store.isBusy)
                        }
                    }
                    if store.state.sessions.isEmpty {
                        ContentUnavailableView("邮袋里还没有风景", systemImage: "envelope.open", description: Text("到「去探索」选择居民的一个小心愿。社区和建设卡可离线保存。"))
                    }
                    ForEach(store.state.sessions) { item in
                        NavigationLink { SessionDetailView(sessionId: item.id) } label: {
                            HStack(spacing: 15) {
                                SessionThumbnail(sessionId: item.id).frame(width: 70, height: 78).clipShape(RoundedRectangle(cornerRadius: 15))
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(store.quest(item.session.questId)?.title ?? "补全另一面").font(.headline).foregroundStyle(Palette.ink)
                                    Text(item.displayStatus).font(.subheadline).foregroundStyle(Palette.forest)
                                    Text("\(item.session.environment == "indoor" ? "室内" : "室外") · \(item.session.captureMode == "external_app" ? "外部扫描" : "原始录像")")
                                        .font(.caption).foregroundStyle(Palette.muted)
                                }
                                Spacer(minLength: 0); Image(systemName: "chevron.right").font(.caption).foregroundStyle(Palette.muted)
                            }.padding(14).background(Palette.paper, in: RoundedRectangle(cornerRadius: 20))
                        }.buttonStyle(.plain)
                    }
                }.padding(20)
            }.background(Palette.cream).navigationBarHidden(true)
                .refreshable { await store.refresh() }
                .navigationDestination(item: $pendingDestination) { SessionDetailView(sessionId: $0) }
        }
    }
}

struct SessionThumbnail: View {
    @EnvironmentObject private var store: GameStore
    let sessionId: String
    var body: some View {
        if let path = store.video(sessionId)?.previewURL, let image = UIImage(contentsOfFile: path.path) {
            Image(uiImage: image).resizable().scaledToFill().clipped()
        } else {
            ZStack { Palette.forest.opacity(0.1); Image(systemName: "postage.stamp.fill").font(.title).foregroundStyle(Palette.forest) }
        }
    }
}

struct SessionDetailView: View {
    @EnvironmentObject private var store: GameStore
    @Environment(\.dismiss) private var dismiss
    let sessionId: String
    @State private var showCamera = false
    @State private var showImporter = false
    @State private var showDelete = false
    @State private var viewer: URLSelection?
    @State private var showRepair = false
    @State private var repairDestination: String?
    @State private var player: AVPlayer?
    @State private var declaredSource = false
    @State private var importTool = "Scaniverse"
    @State private var failedSave: CapturedVideo?
    private var item: SessionEnvelope? { store.envelope(sessionId) }
    var body: some View {
        ScrollView {
            if let item {
                VStack(alignment: .leading, spacing: 20) {
                    header(item)
                    if item.session.captureMode == "in_app_rgb" { nativeCapture(item) }
                    else { externalCapture(item) }
                    processing(item)
                    if let asset = item.asset { result(asset) }
                    facts(item)
                    if item.readyForReward && item.reward == nil {
                        PrimaryAction(title: "领取基础场景卡", symbol: "gift.fill", disabled: store.isBusy) { Task { await store.claim(sessionId) } }
                    }
                    if item.reward != nil {
                        Label("场景卡已在背包里，回到小站即可布置。", systemImage: "checkmark.seal.fill").font(.subheadline).foregroundStyle(Palette.forest)
                    }
                    if item.readyForReward {
                        Button { showRepair = true } label: { Label("为这个收藏补拍另一面", systemImage: "camera.badge.ellipsis") }
                            .disabled(store.isBusy)
                        Text("补拍可选。先由你判断需要补的角度；新旧会话会关联，是否能对齐仍需审核。").font(.caption).foregroundStyle(Palette.muted)
                    }
                    Button(role: .destructive) { showDelete = true } label: { Label("删除这次影像与结果", systemImage: "trash") }.padding(.top, 10).disabled(store.isBusy)
                }.padding(20)
            } else { ContentUnavailableView("这封风景已移走", systemImage: "tray", description: Text("返回邮袋继续查看其他探索。")) }
        }.background(Palette.cream)
            .navigationTitle("风景来信").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button { Task { await store.refresh() } } label: { Image(systemName: "arrow.clockwise") }.disabled(store.isBusy) } }
            .fullScreenCover(isPresented: $showCamera) {
                NativeCaptureView(sessionID: sessionId, onSaved: { video in
                    if store.saveVideo(video, sessionId: sessionId) { showCamera = false; updatePlayer() }
                    else { failedSave = video }
                }, onCancel: { store.cancelCapture(); showCamera = false })
                .alert("探索草稿未能保存", isPresented: Binding(get: { failedSave != nil }, set: { _ in })) {
                    Button("重试保存") {
                        if let video = failedSave, store.saveVideo(video, sessionId: sessionId) { failedSave = nil; store.errorMessage = nil; showCamera = false; updatePlayer() }
                    }
                    Button("稍后重试", role: .cancel) { failedSave = nil; showCamera = false }
                } message: { Text("原始录像仍在本机，将按本任务恢复。请检查手机可用空间。") }
            }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.data, .content], allowsMultipleSelection: false) { result in
                switch result {
                case .success(let files): if let file = files.first { Task { await store.importAsset(file, sessionId: sessionId, tool: importTool) } }
                case .failure(let error): store.errorMessage = "文件未导入：\(error.localizedDescription)"
                }
            }
            .sheet(item: $viewer) { file in
                NavigationStack {
                    GaussianSceneView(url: file.url, onReady: {
                        store.log("result_viewed", sessionId: sessionId, assetId: item?.asset?.id); store.persist()
                    }).navigationTitle("我的真实风景").navigationBarTitleDisplayMode(.inline)
                        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { viewer = nil } } }
                }
            }
            .sheet(isPresented: $showRepair) { repairSheet }
            .alert("删除这次探索？", isPresented: $showDelete) {
                Button("删除影像与结果", role: .destructive) { Task { if await store.deleteSession(sessionId) { dismiss() } } }
                Button("取消", role: .cancel) {}
            } message: { Text("将删除本机草稿、服务器影像与模型。已经获得的建设卡保留为虚拟卡。此操作需要连接服务器。") }
            .navigationDestination(item: $repairDestination) { SessionDetailView(sessionId: $0) }
            .task {
                updatePlayer()
                while !Task.isCancelled {
                    await store.refresh()
                    do { try await Task.sleep(for: .seconds(15)) } catch { return }
                }
            }
            .onDisappear { player?.pause() }
    }
    private func header(_ item: SessionEnvelope) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            StatusPill(text: item.displayStatus, symbol: item.job?.status == "ready" ? "sparkles" : "envelope")
            Text(store.quest(item.session.questId)?.title ?? "补全另一面").font(.title.bold()).foregroundStyle(Palette.ink)
            Text(item.session.environment == "indoor" ? "来自一处室内角落" : "来自一处室外街角").foregroundStyle(Palette.muted)
            if let parent = item.session.parentSessionId {
                Label("补拍来源：\(String(parent.prefix(8))) · 尚未声明拼接成功", systemImage: "link").font(.caption).foregroundStyle(Palette.muted)
            }
        }
    }
    @ViewBuilder private func nativeCapture(_ item: SessionEnvelope) -> some View {
        if let video = store.video(sessionId) {
            Panel {
                Text("这次探索的原始录像").font(.headline)
                VideoPlayer(player: player).frame(height: 220).clipShape(RoundedRectangle(cornerRadius: 14))
                Text("\(Int(video.durationSeconds)) 秒 · \(video.width) × \(video.height) · 无音频").font(.caption).foregroundStyle(Palette.muted)
                if !item.readyForReward {
                    PrimaryAction(title: store.isBusy ? "正在寄出，请保持 App 在前台…" : "确认预览，把风景寄出", symbol: "paperplane.fill", disabled: store.isBusy) { player?.pause(); Task { await store.submitVideo(sessionId) } }
                    if item.session.captureStatus == "draft" && video.uploadStartedAt == nil {
                        Button("重新录一段") { player?.pause(); if store.willCapture(sessionId) { showCamera = true } }.disabled(store.isBusy)
                    }
                    Text("上传中断时原始文件仍在本机，可点同一个按钮重试。").font(.caption).foregroundStyle(Palette.muted)
                    if video.uploadStartedAt != nil { Text("这段录像已开始寄出，暂不能替换。想重新拍摄时，请从探索页创建另一封风景。").font(.caption).foregroundStyle(Palette.muted) }
                }
            }
        } else if !item.readyForReward {
            Panel {
                Text("先收集三枚观察邮戳").font(.headline)
                Text("稳稳看正面 → 缓慢侧移 → 补充地面与边缘。保持共同参照，不必走远。拍摄提示不等于自动质量检测。")
                    .font(.subheadline).foregroundStyle(Palette.muted)
                PrimaryAction(title: "打开相机，开始探索", symbol: "camera.fill", disabled: store.isBusy) { if store.willCapture(sessionId) { showCamera = true } }
            }
        }
    }
    @ViewBuilder private func externalCapture(_ item: SessionEnvelope) -> some View {
        if item.asset == nil {
            Panel {
                Text("带着任务去扫描").font(.headline)
                Text("1. 记住这次任务：\(String(sessionId.prefix(8)))\n2. 手动切到 Scaniverse 等工具，采集并重建这处场景。\n3. 将 Gaussian PLY 或 .splat 导出到 iPhone「文件」。\n4. 回到这里，导入同一次扫描的结果。")
                    .font(.subheadline).foregroundStyle(Palette.muted).lineSpacing(5)
                Button("我现在去外部扫描，任务已保存") {
                    store.log("external_capture_departed", sessionId: sessionId); store.persist(); store.statusMessage = "任务已保存。完成扫描并导出后，回到这封风景来信。"
                }
                TextField("实际使用的扫描工具", text: $importTool).textFieldStyle(.roundedBorder)
                Toggle("确认文件来自本任务这次场景的扫描", isOn: $declaredSource).font(.subheadline)
                PrimaryAction(title: store.isBusy ? "正在导入与检查…" : "从「文件」导入扫描结果", symbol: "square.and.arrow.down", disabled: !declaredSource || importTool.trimmingCharacters(in: .whitespaces).isEmpty || store.isBusy) { showImporter = true }
                Text("仅导入模型，不代表拥有原始视频或相机轨迹。首版不直接导入 SPZ；请导出 Gaussian PLY。模型需小于 150 MB。")
                    .font(.caption).foregroundStyle(Palette.muted)
            }
        }
    }
    private func processing(_ item: SessionEnvelope) -> some View {
        Panel {
            HStack { Image(systemName: "envelope.arrow.triangle.branch").foregroundStyle(Palette.forest); Text("风景制作进度").font(.headline) }
            Text(item.displayStatus).font(.subheadline.weight(.semibold)).foregroundStyle(Palette.forest)
            if item.job?.status == "failed" {
                Text(item.job?.errorMessage ?? "本次处理未完成，操作员可在后台重试。已有卡片不会收回。")
                    .font(.subheadline).foregroundStyle(Palette.muted)
            } else if item.job?.status == "queued" || item.job?.status == "processing" {
                Text("风景正在等待制作。可先回小站布置，完成后回来查看。测试期间由操作员处理与寄回，暂时无法预估完成时间。")
                    .font(.subheadline).foregroundStyle(Palette.muted)
            } else if item.job == nil {
                Text("提交视频或导入扫描结果后，才会创建处理记录。").font(.caption).foregroundStyle(Palette.muted)
            }
        }
    }
    private func result(_ asset: SceneAsset) -> some View {
        Panel {
            HStack { Image(systemName: "cube.transparent.fill").foregroundStyle(Palette.forest); Text("风景回来了").font(.headline) }
            Text("通过原生 3D 查看器回看；旋转、缩放，看看你喜欢的那一面。")
                .font(.subheadline).foregroundStyle(Palette.muted)
            PrimaryAction(title: store.isBusy ? "正在取回风景…" : "打开真实 3D 风景", symbol: "view.3d", disabled: store.isBusy) {
                Task { if let url = await store.downloadAsset(asset) { viewer = URLSelection(url: url) } }
            }
            Text("工具：\(asset.reconstructionTool) · \(asset.format.uppercased())\n来源关联：\(asset.lineageStatus == "verified" ? "已审核" : "人工声明，待审核")")
                .font(.caption).foregroundStyle(Palette.muted)
        }
    }
    private func facts(_ item: SessionEnvelope) -> some View {
        Panel {
            Text("这份收藏包含什么").font(.headline)
            LabeledContent("原始视频", value: item.session.rawDataAvailable ? "服务器已保存" : "未提供")
            LabeledContent("相机轨迹", value: item.session.poseSource == "none" ? "未采集" : item.session.poseSource)
            LabeledContent("质量审核", value: quality(item.asset?.qualityStatus))
            LabeledContent("双用途验证", value: dualUse(item.asset?.dualUseStatus))
            Text("能看见模型与数据能用于训练是两件事。机器人碰撞几何、真实尺度以及视频训练适用性需要后续单独验证。")
                .font(.caption).foregroundStyle(Palette.muted)
            Text("任务编号 \(sessionId)").font(.system(size: 10, design: .monospaced)).textSelection(.enabled).foregroundStyle(Palette.muted)
        }.font(.subheadline)
    }
    private func quality(_ value: String?) -> String {
        switch value { case "accepted": return "已通过本次人工审核"; case "rejected": return "需补采或重新处理"; case "needs_review": return "待人工审核"; default: return "未审核" }
    }
    private func dualUse(_ value: String?) -> String {
        switch value { case "accepted": return "已通过定义的验证"; case "partial": return "部分验证"; case "rejected": return "未通过"; default: return "未验证" }
    }
    private var repairSheet: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 22) {
                Text("你想补哪一面？").font(.title.bold())
                Text("先回看原视频或模型，再去同一个地方补充侧面、地面或边缘观察。尽量保留共同参照。这里没有自动检测缺口，也不会自动把两次扫描拼接起来。")
                    .foregroundStyle(Palette.muted)
                Text("会创建独立的新任务，并记录与这次探索的关系。").font(.subheadline)
                PrimaryAction(title: "用游戏相机补拍", symbol: "camera.fill", disabled: store.isBusy) { startRepair(mode: "in_app_rgb") }
                PrimaryAction(title: "用外部扫描工具补拍", symbol: "square.and.arrow.down", disabled: store.isBusy) { startRepair(mode: "external_app") }
                Spacer()
            }.padding(24).background(Palette.cream)
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("取消") { showRepair = false } } }
        }.presentationDetents([.medium, .large])
    }
    private func startRepair(mode: String) {
        Task {
            let id = await store.startSession(questId: "repair_view", environment: item?.session.environment ?? "unknown", mode: mode, parent: sessionId)
            if let id { showRepair = false; repairDestination = id }
        }
    }
    private func updatePlayer() { if let video = store.video(sessionId) { player = AVPlayer(url: video.url) } }
}

struct CardDetailView: View {
    @EnvironmentObject private var store: GameStore
    @Environment(\.dismiss) private var dismiss
    let cardId: String
    var body: some View {
        ScrollView {
            if let card = store.card(cardId) {
                VStack(alignment: .leading, spacing: 22) {
                    CardArt(card: card).frame(height: 220)
                    Text(card.kind.title).font(.largeTitle.bold()).foregroundStyle(Palette.ink)
                    StatusPill(text: card.sourceLabel, symbol: card.sessionId == nil ? "gift.fill" : "camera.fill")
                    if let sessionId = card.sessionId, store.envelope(sessionId) != nil {
                        SessionThumbnail(sessionId: sessionId).frame(height: 190).clipShape(RoundedRectangle(cornerRadius: 20))
                        NavigationLink { SessionDetailView(sessionId: sessionId) } label: { Label("打开这张卡的真实风景来信", systemImage: "envelope.open.fill") }
                    } else { Text("这是一张虚拟建设卡，可以自由布置。它不代表采集过真实场景。").foregroundStyle(Palette.muted) }
                    PrimaryAction(title: "选中它，回小站布置", symbol: "square.grid.3x3.fill") { store.selectedCardID = cardId; dismiss() }
                }.padding(24)
            }
        }.background(Palette.cream).navigationTitle("场景卡").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() } } }
    }
}
