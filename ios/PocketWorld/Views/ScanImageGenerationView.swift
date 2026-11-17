import SwiftUI

/// Scan detail -> its own subject -> one explicit single-image generation.
/// This does not enter the unrelated camera/album library or upload the scan.
struct ScanImageGenerationView: View {
    let folder: URL?
    let captureID: String
    @StateObject private var store: ImageGenerationStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var photo: UIImage?
    @State private var source: ScanSubjectPhoto.Source?
    @State private var preparing = true
    @State private var confirm = false
    @State private var retry = 0
    @State private var opening = false
    @State private var viewer: Ready?
    private struct Ready: Identifiable { let id: String; let url: URL; let hint: ImageGeneration.Hint? }
    init(api: APIClient, folder: URL?, captureID: String) {
        self.folder=folder; self.captureID=captureID
        _store=StateObject(wrappedValue:ImageGenerationStore(api:api))
    }
    private var entry: ImageGenerationStore.Entry? { store.entries.first { $0.scanSource?.captureID == captureID } }
    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Spacer(minLength: 8)
                if let photo {
                    Image(uiImage:photo).resizable().scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius:20)).accessibilityLabel("这次扫描的主体照片")
                } else if preparing {
                    ProgressView("正在选取主体").tint(Theme.accent)
                } else { Image(systemName:"photo").font(.system(size:48)).foregroundStyle(Theme.secondary) }
                Spacer(minLength: 8)
                if let error=store.error { Text(error).font(.caption).foregroundStyle(Theme.danger) }
                if let entry {
                    Text(entry.image.statusLabel).font(.caption).foregroundStyle(Theme.secondary)
                    if opening { ProgressView() }
                    else if entry.image.status == "ready" {
                        GradientButton(title:"进入 3D 空间",symbol:"view.3d") { open(entry.image) }
                    } else if store.busyID == entry.id {
                        ProgressView(value:store.progress).tint(Theme.accent)
                        Button("暂停") { store.pause() }
                    } else if entry.image.needsDeliveryRecovery {
                        GradientButton(title:"恢复结果",symbol:"arrow.clockwise") { Task { await store.recoverDelivery(entry.id) } }
                    } else if entry.image.pending {
                        ProgressView().tint(Theme.accent)
                        Button("取消生成",role:.destructive) { Task { await store.cancel(entry.id) } }.disabled(entry.image.status == "cancelling")
                    } else { generateButton }
                } else if photo != nil { generateButton }
                else if !preparing { Button("重新选取") { retry += 1 } }
            }
            .padding(24).frame(maxWidth:.infinity,maxHeight:.infinity)
            .background(Theme.background).foregroundStyle(Theme.text)
            .navigationTitle("单图生成").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement:.topBarLeading) { Button("关闭") { store.pause(); dismiss() } } }
            .task(id:retry) { await prepare() }
            .task(id:scenePhase) {
                guard scenePhase == .active else { return }
                while !Task.isCancelled {
                    if entry != nil { await store.refresh() }
                    do { try await Task.sleep(for:.seconds(5)) } catch { return }
                }
            }
            .alert("用扫描主体生成？",isPresented:$confirm) {
                Button("取消",role:.cancel) {}
                Button("同意并生成") { generate() }
            } message: {
                Text("仅上传这张主体照片，生成一个 AI 3DGS。结果包含推测内容，不用于测量；不会启动其他重建方式。")
            }
            .fullScreenCover(item:$viewer) { ready in
                NavigationStack {
                    GaussianSceneView(url:ready.url,predictedView:ready.hint,showsTitle:false)
                        .toolbar {
                            ToolbarItem(placement:.topBarLeading) { Button("关闭") { viewer=nil } }
                            ToolbarItem(placement:.topBarTrailing) { ShareLink(item:ready.url) { Image(systemName:"square.and.arrow.up") } }
                        }
                }
            }
        }
    }
    private var generateButton: some View {
        VStack(spacing:10) {
            Text(source?.selection == "whole_frame" ? "已选取扫描画面" : "已选取扫描主体")
                .font(.caption).foregroundStyle(Theme.secondary)
            GradientButton(title:entry?.requestedAttempt == nil ? "生成" : "继续生成",symbol:"sparkles",
                           isEnabled:store.busyID == nil && (photo != nil || entry != nil)) { confirm=true }
        }
    }
    private func prepare() async {
        preparing=true;store.error=nil
        defer { preparing=false }
        if let entry {
            source=entry.scanSource
            photo=store.sourceURL(entry.id).flatMap { UIImage(contentsOfFile:$0.path) }
            return
        }
        guard let folder else { store.error="本机扫描文件已丢失";return }
        let target=ScanAnalysis.load(from:folder)?.targetBox
        let worker=Task.detached(priority:.userInitiated) { try await ScanSubjectPhoto.prepare(folder:folder,target:target) }
        do {
            let prepared=try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
            try Task.checkCancellation()
            photo=UIImage(cgImage:prepared.image);source=prepared.source
        } catch is CancellationError {} catch { store.error=error.localizedDescription }
    }
    private func generate() {
        do {
            let id: String
            if let entry { id=entry.id }
            else {
                guard let photo, let source else { return }
                id=try store.add(image:photo,scanSource:source)
            }
            store.generate(id)
        } catch { store.error=error.localizedDescription }
    }
    private func open(_ image: ImageGeneration) {
        opening=true;store.error=nil
        Task {
            defer { opening=false }
            do { viewer=Ready(id:image.id,url:try await store.api.prepareImageResult(image),hint:image.result?.viewHint) }
            catch { store.error="结果打开未完成：\(error.localizedDescription)" }
        }
    }
}

/// A scan-linked AI result belongs to the scan project. Opening a finished result
/// downloads that result only; generation remains behind the subject/consent screen.
struct ScanImageGenerationRow: View {
    let folder: URL
    let captureID: String
    @StateObject private var store: ImageGenerationStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var showSource = false
    @State private var opening = false
    @State private var ready: Ready?
    private struct Ready: Identifiable { let id: String; let url: URL; let hint: ImageGeneration.Hint? }

    init(api: APIClient, folder: URL, captureID: String) {
        self.folder = folder; self.captureID = captureID
        _store = StateObject(wrappedValue: ImageGenerationStore(api: api))
    }
    private var entry: ImageGenerationStore.Entry? { store.entries.first { $0.scanSource?.captureID == captureID } }
    var body: some View {
        Card {
            HStack(spacing: 12) {
                Image(systemName: "photo").font(.body.weight(.semibold)).foregroundStyle(Theme.accent)
                    .frame(width: 40, height: 40).background(Theme.surfaceHigh, in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 3) {
                    Text("单图生成").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.text)
                    Text(entry?.image.statusLabel ?? "使用这次扫描的主体照片")
                        .font(.caption).foregroundStyle(Theme.secondary)
                }
                Spacer(minLength: 4)
                if opening { ProgressView().controlSize(.small) }
                else {
                    GhostButton(title: entry?.image.status == "ready" ? "查看" : entry == nil ? "生成" : "详情", tint: Theme.text) {
                        if let image = entry?.image, image.status == "ready" {
                            opening = true
                            Task {
                                defer { opening = false }
                                do {
                                    let url = try await store.api.prepareImageResult(image)
                                    ready = Ready(id: image.id, url: url, hint: image.result?.viewHint)
                                } catch { store.error = error.localizedDescription }
                            }
                        } else { showSource = true }
                    }
                }
            }
            if let error = store.error { Text(error).font(.caption).foregroundStyle(Theme.danger) }
        }
        .task(id: "\(scenePhase)-\(showSource)") {
            guard scenePhase == .active, !showSource else { return }
            await store.refresh()
            while !Task.isCancelled && entry?.image.pending == true {
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                await store.refresh()
            }
        }
        .fullScreenCover(isPresented: $showSource) {
            ScanImageGenerationView(api: store.api, folder: folder, captureID: captureID)
        }
        .fullScreenCover(item: $ready) { item in
            NavigationStack {
                GaussianSceneView(url: item.url, predictedView: item.hint, showsTitle: false)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) { Button("关闭") { ready = nil } }
                        ToolbarItem(placement: .topBarTrailing) { ShareLink(item: item.url) { Image(systemName: "square.and.arrow.up") } }
                    }
            }
        }
    }
}
