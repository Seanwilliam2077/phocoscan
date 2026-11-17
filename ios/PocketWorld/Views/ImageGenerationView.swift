import SwiftUI
import PhotosUI
import AVFoundation
import ARKit

struct ImageGenerationView: View {
    @StateObject private var store: ImageGenerationStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var picked: PhotosPickerItem?
    @State private var confirmID: String?
    @State private var deleteID: String?
    @State private var viewer: ReadyImage?
    @State private var opening: String?
    @State private var showCamera = false
    @State private var requestingCamera = false
    @State private var cameraError: String?
    @State private var cameraSettingsAvailable = false
    init(api: APIClient) {
        _store = StateObject(wrappedValue: ImageGenerationStore(api: api))
    }
    private struct ReadyImage: Identifiable { let id: String; let url: URL; let hint: ImageGeneration.Hint? }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 12) {
                        Button { Task { await openCamera() } } label: {
                            Label("拍摄", systemImage: "camera").frame(maxWidth: .infinity, minHeight: 32)
                        }.buttonStyle(.borderedProminent).tint(Theme.accent)
                        PhotosPicker(selection: $picked, matching: .images, photoLibrary: .shared()) {
                            Label("相册", systemImage: "photo").frame(maxWidth: .infinity, minHeight: 32)
                        }.buttonStyle(.bordered).tint(Theme.accentSoft)
                    }.disabled(requestingCamera)
                    Text("AI 生成 · 非实测尺寸").font(.caption).foregroundStyle(Theme.secondary)
                    if let error = store.error { Text(error).font(.caption).foregroundStyle(Theme.danger) }
                    ForEach(store.entries) { entry in
                        Card {
                            HStack(spacing: 12) {
                                thumbnail(store.sourceURL(entry.id)).frame(width: 68, height: 68).clipped().clipShape(RoundedRectangle(cornerRadius: 12))
                                VStack(alignment: .leading, spacing: 5) {
                                    Text("单图生成").font(.headline)
                                    Text(entry.image.statusLabel).font(.caption).foregroundStyle(Theme.secondary)
                                    if let result = entry.image.result {
                                        Text(ByteCountFormatter.string(fromByteCount: Int64(result.spz.byteSize), countStyle: .file)).font(.caption2).foregroundStyle(Theme.tertiary)
                                    }
                                }
                                Spacer()
                                if opening == entry.id { ProgressView() }
                                else if entry.image.status == "ready" {
                                    Button("进入") { open(entry.image) }
                                } else if store.busyID == entry.id {
                                    Button("暂停") { store.pause() }
                                } else if entry.image.needsDeliveryRecovery {
                                    Button("恢复结果") { Task { await store.recoverDelivery(entry.id) } }.disabled(store.busyID != nil)
                                } else if entry.image.pending {
                                    Button("取消") { Task { await store.cancel(entry.id) } }.disabled(entry.image.status == "cancelling")
                                } else {
                                    Button(entry.requestedAttempt != nil ? "继续" : "生成") { confirmID = entry.id }.disabled(store.busyID != nil)
                                }
                            }
                            if store.busyID == entry.id { ProgressView(value: store.progress).tint(Theme.accent) }
                        }
                        .contextMenu {
                            if entry.image.status == "ready" { Button("重新下载 / 打开", systemImage: "arrow.down.circle") { open(entry.image) } }
                            if !entry.image.pending { Button("删除", role: .destructive) { deleteID = entry.id } }
                        }
                    }
                }.padding(20)
            }
            .background(Theme.background).foregroundStyle(Theme.text)
            .navigationTitle("单图生成")
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button("完成") { store.pause();dismiss() }.disabled(requestingCamera) } }
            .refreshable { await store.refresh() }
            .task(id: scenePhase) {
                guard scenePhase == .active else { return }
                await store.refresh()
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    if !Task.isCancelled { await store.refresh() }
                }
            }
            .onChange(of: picked) { _, item in
                Task {
                    do { if let data = try await item?.loadTransferable(type: Data.self) { try store.add(data: data) } }
                    catch { store.error = error.localizedDescription }
                    picked = nil
                }
            }
            .alert("上传这张照片并生成？", isPresented: Binding(get: { confirmID != nil }, set: { if !$0 { confirmID = nil } })) {
                Button("取消", role: .cancel) { confirmID = nil }
                Button("同意并生成") { if let id = confirmID { store.generate(id) };confirmID = nil }
            } message: { Text("仅上传所选图片，由服务器上的 TripoSplat 生成 3DGS。结果包含 AI 推测内容，不用于测量；不会启动其他重建方式。") }
            .alert("删除这次单图生成？", isPresented: Binding(get: { deleteID != nil }, set: { if !$0 { deleteID = nil } })) {
                Button("取消", role: .cancel) { deleteID = nil }
                Button("删除", role: .destructive) { if let id = deleteID { Task { await store.delete(id) } };deleteID = nil }
            } message: { Text("会删除本机与服务器上的原图和生成结果。") }
            .alert("无法打开相机", isPresented: Binding(get: { cameraError != nil }, set: { if !$0 { cameraError = nil } })) {
                if cameraSettingsAvailable {
                    Button("打开设置") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                }
                Button("取消", role: .cancel) { cameraError = nil }
            } message: { Text(cameraError ?? "") }
            .fullScreenCover(isPresented: $showCamera) {
                SingleImageCamera(save: { image in
                    try store.add(image: image)
                    store.error = nil
                }, close: { showCamera = false })
                .ignoresSafeArea().interactiveDismissDisabled()
            }
            .fullScreenCover(item: $viewer) { ready in
                NavigationStack {
                    GaussianSceneView(url: ready.url, predictedView: ready.hint, showsTitle: false)
                        .toolbar {
                            ToolbarItem(placement: .topBarLeading) { Button("关闭") { viewer = nil } }
                            ToolbarItem(placement: .topBarTrailing) { ShareLink(item: ready.url) { Image(systemName: "square.and.arrow.up") } }
                        }
                }
            }
        }
    }
    @ViewBuilder private func thumbnail(_ url: URL?) -> some View {
        if let url, let image = UIImage(contentsOfFile: url.path) { Image(uiImage: image).resizable().scaledToFill() }
        else { Rectangle().fill(Theme.surfaceHigh).overlay(Image(systemName: "photo")) }
    }
    private func openCamera() async {
        guard !requestingCamera else { return }
        cameraSettingsAvailable = false
        guard ARWorldTrackingConfiguration.isSupported else {
            cameraError = "此设备无法拍摄，请从相册选择照片。"; return
        }
        requestingCamera = true
        defer { requestingCamera = false }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: showCamera = true
        case .notDetermined:
            if await AVCaptureDevice.requestAccess(for: .video) { showCamera = true }
            else { cameraSettingsAvailable = true; cameraError = "请在设置中允许 phocoscan 使用相机。" }
        case .denied:
            cameraSettingsAvailable = true; cameraError = "请在设置中允许 phocoscan 使用相机。"
        case .restricted: cameraError = "相机访问受到设备限制，可以从相册选择照片。"
        @unknown default: cameraError = "相机暂不可用，请从相册选择照片。"
        }
    }
    private func open(_ image: ImageGeneration) {
        opening = image.id; store.error = nil
        Task {
            defer { opening = nil }
            do { viewer = ReadyImage(id: image.id, url: try await store.api.prepareImageResult(image), hint: image.result?.viewHint) }
            catch { store.error = "结果下载或打开未完成：\(error.localizedDescription) 再点进入只会重试下载。" }
        }
    }
}

/// Single-image works share the home library. Ready cards open the interactive result directly.
struct ImageLibrarySection: View {
    @StateObject private var store: ImageGenerationStore
    @State private var opened: URL?
    @State private var hint: ImageGeneration.Hint?
    @State private var showViewer = false
    @State private var showLibrary = false
    @Environment(\.scenePhase) private var scenePhase
    init(api: APIClient) { _store = StateObject(wrappedValue: ImageGenerationStore(api: api)) }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !store.entries.isEmpty {
                HStack { Text("单图作品").font(.headline);Spacer();Button("全部") { showLibrary = true }.font(.caption) }
                ForEach(Array(store.entries.prefix(3))) { entry in
                    Button {
                        guard entry.image.status == "ready" else { showLibrary = true;return }
                        Task {
                            do { opened = try await store.api.prepareImageResult(entry.image); hint = entry.image.result?.viewHint;showViewer = true }
                            catch { store.error = error.localizedDescription }
                        }
                    } label: {
                        HStack {
                            if let url = store.sourceURL(entry.id), let image = UIImage(contentsOfFile: url.path) {
                                Image(uiImage: image).resizable().scaledToFill().frame(width: 48, height: 48).clipped().clipShape(RoundedRectangle(cornerRadius: 10))
                            } else { Image(systemName: "photo").frame(width: 48, height: 48) }
                            VStack(alignment: .leading) {
                                Text("AI 单图生成").font(.subheadline)
                                Text(entry.image.statusLabel).font(.caption).foregroundStyle(Theme.secondary)
                            }
                            Spacer();Image(systemName: "chevron.right").font(.caption)
                        }.padding(10).background(Theme.surface,in:RoundedRectangle(cornerRadius:14))
                    }.foregroundStyle(Theme.text)
                }
                if let error = store.error { Text(error).font(.caption).foregroundStyle(Theme.danger) }
            }
        }
        .task(id: scenePhase) { if scenePhase == .active { await store.refresh() } }
        .fullScreenCover(isPresented: $showLibrary, onDismiss: { Task { await store.refresh() } }) { ImageGenerationView(api: store.api) }
        .fullScreenCover(isPresented: $showViewer) {
            if let opened {
                NavigationStack {
                    GaussianSceneView(url: opened, predictedView: hint, showsTitle: false)
                        .toolbar { ToolbarItem(placement: .topBarLeading) { Button("关闭") { showViewer = false } } }
                }
            }
        }
    }
}
