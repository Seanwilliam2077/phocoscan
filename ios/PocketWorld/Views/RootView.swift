import AVFoundation
import AVKit
import Foundation
import SwiftUI
import UIKit

/// Home: visual creation entries and the local/cloud library.
/// Upload, verification and reconstruction logic live in the stores; this file
/// only presents them.
struct RootView: View {
    @ObservedObject private var sync = ReconstructionSync.shared
    @ObservedObject private var cloud = ReconstructionSync.shared.cloud
    @Environment(\.scenePhase) private var scenePhase
    @State private var packages: [ScanPackage] = []
    @AppStorage("phocoscan.homeSection") private var homeSection: HomeSection = .discover
    @State private var showCreate = false
    @State private var pendingMode: ScanMode?
    @State private var pendingImage = false
    @State private var captureMode: ScanMode = .object
    @State private var selectedPackage: ScanPackage?
    @State private var showImageGeneration = false
    @State private var imageLibraryRevision = 0
    @State private var showCapture = false
    @State private var showSettings = false
    @State private var pendingSavedPackageURL: URL?
    @State private var libraryError: String?

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                Theme.background.ignoresSafeArea()
                ZStack {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 22) {
                            header
                            HomeLibraryView(packages: packages, cloud: cloud, openScan: openPackage,
                                            details: { selectedPackage = $0 }, create: { showCreate = true },
                                            rescan: startRescan, onDeleted: reloadPackages)
                                .id("\(cloud.imageAPI.connectionIdentity?.cacheKey ?? "offline")-\(imageLibraryRevision)")
                        }.padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 120)
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .refreshable {
                        reloadPackages(); imageLibraryRevision += 1
                        if !cloud.backendInput.isEmpty { await cloud.connect() }
                    }
                    .opacity(homeSection == .mine ? 1 : 0)
                    .allowsHitTesting(homeSection == .mine).accessibilityHidden(homeSection != .mine)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 26) {
                            header
                            HomeGuidesView(scan: { captureMode = $0; showCapture = true }, image: { showImageGeneration = true })
                        }.padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 120)
                    }
                    .opacity(homeSection == .discover ? 1 : 0)
                    .allowsHitTesting(homeSection == .discover).accessibilityHidden(homeSection != .discover)
                }
                HomeTabBar(selection: $homeSection) { showCreate = true }

            }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(item: $selectedPackage) { package in
                ScanDetailView(package: package, cloud: cloud, onRescan: { startRescan(package) }) {
                    selectedPackage = nil
                    reloadPackages()
                }.id(package.captureID)
            }
            .onAppear(perform: reloadPackages)
            .task {
                if !cloud.backendInput.isEmpty && !cloud.isConnected { await cloud.connect() }
            }
            // While the app is open, follow every cloud reconstruction (not only the
            // scan on screen) and download finished results to the phone.
            .task(id: "\(cloud.isConnected)-\(scenePhase == .active)") {
                guard cloud.isConnected, scenePhase == .active else { return }
                while !Task.isCancelled {
                    await sync.syncOnce()
                    try? await Task.sleep(nanoseconds: 8_000_000_000)
                }
            }
            .onChange(of: sync.openCaptureID) { _, id in
                guard let id else { return }
                reloadPackages()
                showCapture = false
                selectedPackage = packages.first { $0.captureID == id }
                sync.openCaptureID = nil
            }
            .sheet(isPresented: $showCreate, onDismiss: {
                if let mode = pendingMode { captureMode = mode; pendingMode = nil; showCapture = true }
                if pendingImage { pendingImage = false; showImageGeneration = true }
            }) {
                HomeCreateView(scan: { pendingMode = $0; showCreate = false }, image: { pendingImage = true; showCreate = false })
            }
            .fullScreenCover(isPresented: $showImageGeneration, onDismiss: { imageLibraryRevision += 1 }) { ImageGenerationView(api: cloud.imageAPI) }
            .fullScreenCover(isPresented: $showCapture, onDismiss: {
                if let url = pendingSavedPackageURL {
                    homeSection = .mine
                    selectedPackage = packages.first { $0.folderURL == url }
                    pendingSavedPackageURL = nil
                }
            }) {
                ARScanCaptureView(onSaved: { url in
                    reloadPackages()
                    pendingSavedPackageURL = url
                    showCapture = false
                }, onCancel: { showCapture = false }, initialMode: captureMode)
            }
            .sheet(isPresented: $showSettings, onDismiss: {
                reloadPackages(); imageLibraryRevision += 1
            }) { ServerSettingsView(cloud: cloud) }
            .alert("无法读取扫描目录", isPresented: Binding(
                get: { libraryError != nil },
                set: { if !$0 { libraryError = nil } }
            )) {
                Button("知道了", role: .cancel) { libraryError = nil }
            } message: {
                Text(libraryError ?? "")
            }
        }
    }

    /// Name on the left, settings on the right; the server state is the dot on the gear.
    private var header: some View {
        let status = cloud.isConnected ? "已连接服务器" : (cloud.isBusy ? "正在连接…" : "未连接，可离线扫描")
        return HStack(spacing: 10) {
            BrandMark(size: 52)
            VStack(alignment: .leading, spacing: 4) {
                Text("phocoscan").font(.system(size: 25, weight: .bold, design: .rounded)).foregroundStyle(Theme.text)
            }
            Spacer()
            GlassIconButton(symbol: "gearshape.fill", label: "设置，\(status)", size: 40) { showSettings = true }
                .overlay(alignment: .topTrailing) {
                    StatusDot(color: cloud.isConnected ? Theme.success : Theme.tertiary, pulsing: cloud.isBusy)
                        .overlay(Circle().stroke(Theme.background, lineWidth: 2))
                        .offset(x: -3, y: 3)
                        .allowsHitTesting(false)
                }
        }
        .padding(.top, 8)
    }

    private func openPackage(_ package: ScanPackage) {
        selectedPackage = package
    }

    private func startRescan(_ package: ScanPackage) {
        captureMode = ScanMode(rawValue: package.analysis?.mode ?? "") ?? .object
        showCapture = true
    }

    private func reloadPackages() {
        do {
            packages = try ScanPackage.loadAll()
            ScanNameStore.shared.assignNumbers(
                oldestFirst: packages.sorted { $0.createdDate < $1.createdDate }.map(\.captureID))
            libraryError = nil
        } catch {
            libraryError = error.localizedDescription
        }
    }
}

// MARK: - Gallery

struct ScanCard: View {
    let package: ScanPackage
    let title: String
    let stage: ScanStage

    private var assessment: ScanCaptureAssessment { ScanCaptureAssessment(isComplete: package.isComplete, analysis: package.analysis) }
    private var tint: Color {
        switch assessment.state {
        case .incomplete, .retake: Theme.danger
        case .limited: Theme.warning
        case .usable: Theme.success
        case .unknown: Theme.tertiary
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.aspectRatio(1.15, contentMode: .fit)
                .overlay { VideoThumbnail(url: package.videoURL) }
                .clipped()
                .overlay(alignment: .topLeading) {
                    Text(assessment.title).font(.caption2.weight(.semibold)).foregroundStyle(tint)
                        .padding(.horizontal, 9).padding(.vertical, 6)
                        .background(.black.opacity(0.78), in: Capsule()).padding(10)
                }
            VStack(alignment: .leading, spacing: 7) {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.text).lineLimit(1)
                HStack(spacing: 4) {
                    Text(assessment.coverageText).font(.caption.weight(.medium)).foregroundStyle(tint)
                    Spacer(minLength: 0)
                }
                GeometryReader { geometry in
                    Capsule().fill(Theme.stroke)
                        .overlay(alignment: .leading) {
                            Capsule().fill(tint).frame(width: geometry.size.width * (assessment.coverage ?? 0))
                        }
                }.frame(height: 3).accessibilityHidden(true)
                Text(assessment.keyframeText).font(.caption2).foregroundStyle(Theme.secondary)
                Text(assessment.reason).font(.caption2).foregroundStyle(Theme.secondary)
                    .lineLimit(2).frame(minHeight: 30, alignment: .topLeading)
                Divider().overlay(Theme.stroke)
                HStack(alignment: .top, spacing: 5) {
                    StatusDot(color: stage.color, pulsing: stage.isActive)
                        .padding(.top, 3)
                    Text(stage.label).font(.caption2).foregroundStyle(Theme.secondary).lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }.padding(12)
        }
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(Theme.stroke))
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// One presentation status per scan, derived from the existing stores.
struct ScanStage {
    let label: String
    let color: Color
    let isActive: Bool

    @MainActor
    static func of(_ package: ScanPackage, cloud: CaptureV2UploadStore, store: NativeReconstructionStore) -> ScanStage {
        guard package.isComplete else { return ScanStage(label: "不完整", color: Theme.warning, isActive: false) }
        let id = package.captureID
        if cloud.activeCaptureID == id { return ScanStage(label: "上传中", color: Theme.accent, isActive: true) }
        if let result = store.result(captureID: id) {
            if !result.readyResults.isEmpty { return ScanStage(label: "可查看 3DGS", color: Theme.success, isActive: false) }
            if result.isPending { return ScanStage(label: "生成中", color: Theme.accent, isActive: true) }
            if result.tasks.contains(where: \.canRetry) {
                return ScanStage(label: "需重试", color: Theme.danger, isActive: false)
            }
        }
        if let status = cloud.status(for: id) {
            if status.verifiedReceipt != nil { return ScanStage(label: "已上传", color: Theme.accent, isActive: false) }
            if status.rgb != nil || status.metadata != nil {
                return ScanStage(label: "上传未完成", color: Theme.warning, isActive: false)
            }
        }
        return ScanStage(label: "仅本机", color: Theme.tertiary, isActive: false)
    }
}

// MARK: - Thumbnails

@MainActor
private final class ThumbnailCache {
    static let shared = ThumbnailCache()
    private var images: [URL: UIImage] = [:]

    func image(for url: URL) async -> UIImage? {
        if let cached = images[url] { return cached }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.maximumSize = CGSize(width: 720, height: 720)
        generator.appliesPreferredTrackTransform = true
        guard let frame = try? await generator.image(at: CMTime(seconds: 0.6, preferredTimescale: 600)) else {
            return nil
        }
        // ARKit frames are stored in sensor (landscape) orientation; show them upright.
        let image = UIImage(cgImage: frame.image, scale: 1, orientation: .right)
        images[url] = image
        return image
    }
}

struct VideoThumbnail: View {
    let url: URL?
    /// When set and a 3D render cover exists for this scan, show it instead of the video frame.
    var captureID: String?
    @ObservedObject private var posters = ScanPosterStore.shared
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Theme.surfaceHigh
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: "cube.transparent").font(.title).foregroundStyle(Theme.tertiary)
            }
        }
        .clipped()
        .task(id: "\(url?.path ?? "")#\(captureID.flatMap { posters.versions[$0] } ?? 0)") {
            if let captureID, let poster = posters.posterURL(for: captureID),
               let data = try? Data(contentsOf: poster), let rendered = UIImage(data: data) {
                image = rendered
                return
            }
            image = nil
            guard let url else { return }
            let loaded = await ThumbnailCache.shared.image(for: url)
            guard !Task.isCancelled else { return }
            image = loaded
        }
    }
}

// MARK: - Local package model

struct ScanPackage: Identifiable, Hashable {
    let folderURL: URL
    let videoURL: URL?
    let frameCount: Int?
    let depthFrameCount: Int?
    let skippedFrameCount: Int?
    let createdAt: String?
    let modifiedAt: Date
    let isComplete: Bool
    /// Capture-quality report saved with the scan (absent for older scans).
    let analysis: ScanAnalysis?

    var id: String { folderURL.path }
    var captureID: String { folderURL.deletingPathExtension().lastPathComponent }
    var shortID: String { String(folderURL.deletingPathExtension().lastPathComponent.prefix(8)) }
    var hasDepth: Bool { (depthFrameCount ?? 0) > 0 }
    /// Scans recorded with the keyframe/package update carry `capture/transforms.json`.
    var hasTrainingPackage: Bool {
        FileManager.default.fileExists(atPath: folderURL.appendingPathComponent("capture/transforms.json").path)
    }

    static func == (lhs: ScanPackage, rhs: ScanPackage) -> Bool { lhs.folderURL == rhs.folderURL }
    func hash(into hasher: inout Hasher) { hasher.combine(folderURL) }

    var createdDate: Date {
        guard let createdAt else { return modifiedAt }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: createdAt) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: createdAt) ?? modifiedAt
    }

    var displayTitle: String {
        createdDate.formatted(.dateTime.month(.defaultDigits).day().hour().minute())
    }

    var shortSummary: String {
        guard isComplete else { return "扫描未完整保存" }
        let frames = frameCount.map { "\($0) 帧" } ?? "帧数待核对"
        return frames + (hasDepth ? " · LiDAR" : "")
    }

    var summary: String {
        guard isComplete else { return "扫描未完整保存 · 无法上传" }
        let frameLabel = frameCount.map { "\($0) 帧" } ?? "帧数待核对"
        return frameLabel + (hasDepth ? " · 含深度" : " · 无深度")
    }

    static func loadAll() throws -> [ScanPackage] {
        let manager = FileManager.default
        guard let support = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return []
        }
        let root = support.appendingPathComponent("ScanPackages", isDirectory: true)
        guard manager.fileExists(atPath: root.path) else { return [] }
        let entries = try manager.contentsOfDirectory(at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles])
        return entries.filter { $0.pathExtension == "scan" }
            .compactMap { folder -> ScanPackage? in
                guard (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return nil }
                let manifestURL = folder.appendingPathComponent("manifest.json")
                var manifest: [String: Any]?
                if let data = try? Data(contentsOf: manifestURL) {
                    manifest = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                }
                let videoURL = safeChild(named: manifest?["videoFile"] as? String, in: folder)
                let framesURL = safeChild(named: manifest?["framesFile"] as? String, in: folder)
                let hasVideo = videoURL.map { manager.fileExists(atPath: $0.path) } ?? false
                let hasFrames = framesURL.map { manager.fileExists(atPath: $0.path) } ?? false
                let resourceValues = try? folder.resourceValues(forKeys: [.contentModificationDateKey])
                let modifiedAt = resourceValues?.contentModificationDate ?? .distantPast
                return ScanPackage(folderURL: folder, videoURL: hasVideo ? videoURL : nil,
                    frameCount: manifest?["frameCount"] as? Int,
                    depthFrameCount: manifest?["depthFrameCount"] as? Int,
                    skippedFrameCount: manifest?["skippedFrameCount"] as? Int,
                    createdAt: manifest?["createdAtUTC"] as? String,
                    modifiedAt: modifiedAt,
                    isComplete: manifest != nil && hasVideo && hasFrames,
                    analysis: ScanAnalysis.load(from: folder))
            }
            .sorted { $0.modifiedAt > $1.modifiedAt }
    }

    private static func safeChild(named name: String?, in folder: URL) -> URL? {
        guard let name, !name.isEmpty, name != ".", name != "..",
              name == URL(fileURLWithPath: name).lastPathComponent,
              !name.contains("/") && !name.contains("\\") else { return nil }
        return folder.appendingPathComponent(name)
    }
}

// MARK: - Scan detail

private struct ScanDetailView: View {
    let package: ScanPackage
    @ObservedObject var cloud: CaptureV2UploadStore
    @ObservedObject private var store: NativeReconstructionStore
    var onDeleted: () -> Void = {}
    var onRescan: () -> Void = {}
    @State private var environment = "indoor"
    @State private var showUploadConsent = false
    @State private var showSettings = false
    @State private var showVideo = false
    @State private var showReview = false
    @State private var showRename = false
    @State private var showReconstructionGuide = false
    @State private var draftName = ""
    @ObservedObject private var names = ScanNameStore.shared
    @State private var exportItem: ExportedFile?
    @State private var exporting = false
    @State private var exportError: String?
    @State private var confirmDelete = false
    @State private var deleting = false

    private var title: String { names.displayName(for: package.captureID) }
    /// Ever submitted to a server: deleting then also removes the server copy.
    private var wasUploaded: Bool { serverStatus != nil || cloud.firstEnvironment(for: package.captureID) != nil }

    init(package: ScanPackage, cloud: CaptureV2UploadStore, onRescan: @escaping () -> Void = {}, onDeleted: @escaping () -> Void = {}) {
        self.package = package
        self.onDeleted = onDeleted
        self.onRescan = onRescan
        _cloud = ObservedObject(wrappedValue: cloud)
        _store = ObservedObject(wrappedValue: cloud.reconstructions)
    }

    private var serverStatus: CaptureV2Status? { cloud.status(for: package.captureID) }
    private var isThisUploadActive: Bool { cloud.activeCaptureID == package.captureID }
    private var isVerified: Bool { serverStatus?.verifiedReceipt != nil }
    private var environmentLocked: Bool { cloud.firstEnvironment(for: package.captureID) != nil }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                hero
                VStack(alignment: .leading, spacing: 6) {
                    Button {
                        draftName = names.customName(for: package.captureID) ?? ""
                        showRename = true
                    } label: {
                        HStack(spacing: 8) {
                            Text(title).font(.title2.weight(.bold)).foregroundStyle(Theme.text)
                                .lineLimit(1)
                            Image(systemName: "pencil").font(.subheadline.weight(.semibold))
                                .foregroundStyle(Theme.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("重命名：\(title)")
                    Text("\(package.displayTitle) · \(package.summary)").font(.subheadline)
                        .foregroundStyle(Theme.secondary)
                }
                if let analysis = package.analysis { ScanAnalysisCard(analysis: analysis) }
                if !package.isComplete {
                    Card {
                        Label("这次扫描没有完整保存", systemImage: "exclamationmark.triangle.fill")
                            .font(.headline).foregroundStyle(Theme.warning)
                        Text("视频或相机轨迹缺失，无法上传。请重新扫描一次。")
                            .font(.subheadline).foregroundStyle(Theme.secondary)
                    }
                } else if !isVerified {
                    if isThisUploadActive { UploadProgressCard(phase: cloud.activePhase) }
                    else { generateCard }
                }
                NativeReconstructionPanel(captureID: package.captureID, store: store,
                                          title: title, subtitle: package.displayTitle,
                                          sourceReady: isVerified, includesLocalTraining: true,
                                          onShowGuide: { showReconstructionGuide = true })
                detailsCard
                actionsCard
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 32)
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.background, for: .navigationBar)
        .onAppear {
            environment = cloud.firstEnvironment(for: package.captureID)
                ?? CaptureEnvironmentMemory.load(captureID: package.captureID)
                ?? "indoor"

        }
        .sheet(isPresented: $showSettings, onDismiss: {
            if !FileManager.default.fileExists(atPath: package.folderURL.path) { onDeleted() }
        }) { ServerSettingsView(cloud: cloud) }
        .sheet(isPresented: $showReconstructionGuide) { ReconstructionGuideView() }
        .alert("重命名扫描", isPresented: $showRename) {
            TextField("例如：书桌一角", text: $draftName)
            Button("取消", role: .cancel) {}
            Button("保存") { names.setName(draftName, for: package.captureID) }
        } message: {
            Text("留空则使用自动编号。名称只保存在这台手机上。")
        }
        .sheet(isPresented: $showUploadConsent) {
            UploadConsentSheet(destination: cloud.connectedDestination ?? "未连接的服务器",
                               warning: package.analysis.flatMap { $0.verdict == "poor"
                                   ? "扫描分析建议重拍：" + $0.issues.prefix(2).joined(separator: "；") + "。重建效果可能较差，仍可上传。"
                                   : nil }) {
                showUploadConsent = false
                ReconstructionSync.shared.requestNotificationPermission()
                Task { await cloud.upload(packageURL: package.folderURL, selectedEnvironment: environment) }
            }
        }
        .fullScreenCover(isPresented: $showVideo) {
            if let video = package.videoURL { RawVideoPlayer(url: video) }
        }
        .sheet(item: $exportItem) { item in ActivitySheet(items: [item.url]) }
        .alert("操作未完成", isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })) {
            Button("知道了", role: .cancel) {}
        } message: { Text(exportError ?? "") }
        .alert("删除「\(title)」？", isPresented: $confirmDelete) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) { deleteScan() }
        } message: {
            Text("将删除本机原片、深度、训练数据和重建结果，以及当前账号的云端副本和关联单图作品。无法恢复；远端删除失败时，本机素材会保留。")
        }
    }

    /// Export of the training package and deletion, kept at the bottom of the page.
    private var actionsCard: some View {
        Card(padding: 6) {
            VStack(spacing: 0) {
                actionRow(title: "重新扫描", detail: "沿用拍摄模式，原素材和结果保留",
                          symbol: "viewfinder", busy: false, action: onRescan)
                Divider().overlay(Theme.stroke).padding(.leading, 52)
                if package.hasTrainingPackage {
                    actionRow(title: "导出训练数据包", detail: "nerfstudio 格式，可在电脑上训练",
                              symbol: "shippingbox", busy: exporting) { exportPackage() }
                    Divider().overlay(Theme.stroke).padding(.leading, 52)
                }
                actionRow(title: "删除这次扫描", detail: wasUploaded ? "连同服务器上的原片和 3DGS" : "原片、深度和数据包",
                          symbol: "trash", tint: Theme.danger, busy: deleting) { confirmDelete = true }
            }
        }
    }

    private func actionRow(title: String, detail: String, symbol: String, tint: Color = Theme.text,
                           busy: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: symbol).font(.body.weight(.semibold)).foregroundStyle(tint).frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(tint)
                    Text(detail).font(.caption).foregroundStyle(Theme.tertiary)
                }
                Spacer()
                if busy { ProgressView() }
            }
            .padding(.horizontal, 12).padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(exporting || deleting || cloud.isBusy)
    }

    private func exportPackage() {
        exporting = true
        let folder = package.folderURL
        let name = "phocoscan-" + title.filter { $0.isLetter || $0.isNumber } + "-" + package.shortID
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Result { try TrainingPackageWriter.exportZip(scanFolder: folder, name: name) }
            }.value
            exporting = false
            switch result {
            case .success(let url): exportItem = ExportedFile(url: url)
            case .failure(let error): exportError = error.localizedDescription
            }
        }
    }

    private func deleteScan() {
        deleting = true
        Task {
            let deleted = await cloud.deleteScan(folderURL: package.folderURL)
            deleting = false
            if deleted {
                names.setName("", for: package.captureID)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                onDeleted()
            } else {
                exportError = cloud.errorMessage ?? "删除没有完成，扫描仍保留在本机。"
            }
        }
    }

    private var hero: some View {
        Color.clear
            .aspectRatio(4.0 / 3.0, contentMode: .fit)
            .overlay { VideoThumbnail(url: package.videoURL) }
            .overlay(alignment: .bottom) {
                HStack(spacing: 10) {
                    if (package.depthFrameCount ?? 0) > 0 {
                        Button { showReview = true } label: {
                            Label("采集检查", systemImage: "rotate.3d")
                                .font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                                .padding(.horizontal, 14).frame(minHeight: 44)
                                .background(Theme.accentGradient, in: Capsule())
                        }.buttonStyle(.plain)
                        .accessibilityHint("查看原始深度点云和拍摄路线，不是重建结果")
                    }
                    Spacer(minLength: 0)
                    if package.videoURL != nil {
                        Button { showVideo = true } label: {
                            Label("原片", systemImage: "play.fill")
                                .font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                                .padding(.horizontal, 14).frame(minHeight: 44)
                                .background(.ultraThinMaterial, in: Capsule())
                        }.buttonStyle(.plain)
                    }
                }.padding(14)
            }
            .fullScreenCover(isPresented: $showReview) {
                CaptureReviewView(folder: package.folderURL, analysis: package.analysis)
            }
            .overlay(alignment: .topLeading) {
                Text("原始采集").font(.caption.weight(.medium)).foregroundStyle(.white)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(.black.opacity(0.6), in: Capsule()).padding(14)
            }
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(Theme.stroke))
    }

    private var generateCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 4) {
                Text("上传采集数据").font(.headline).foregroundStyle(Theme.text)
                Text("云端重建需先上传，本机重建无需上传。")
                    .font(.subheadline).foregroundStyle(Theme.secondary)
            }
            Picker("场景", selection: $environment) {
                Text("室内").tag("indoor")
                Text("室外").tag("outdoor")
                Text("不确定").tag("unknown")
            }
            .pickerStyle(.segmented)
            .disabled(environmentLocked || cloud.isBusy)
            if environmentLocked {
                Text("场景类型已在首次提交时确定，重试会沿用。")
                    .font(.caption).foregroundStyle(Theme.tertiary)
            }
            if cloud.isConnected {
                GradientButton(title: serverStatus == nil ? "上传扫描" : "继续上传",
                               symbol: "icloud.and.arrow.up", isEnabled: !cloud.isBusy) {
                    showUploadConsent = true
                }
            } else {
                GradientButton(title: "连接服务器", symbol: "network") { showSettings = true }
                Text("扫描已保存在本机。连接服务器后即可上传。")
                    .font(.caption).foregroundStyle(Theme.tertiary)
            }
            if let error = cloud.errorMessage {
                Label(error, systemImage: "exclamationmark.circle.fill")
                    .font(.caption).foregroundStyle(Theme.danger)
            }

        }
    }

    private var detailsCard: some View {
        Card {
            DisclosureGroup {
                VStack(spacing: 10) {
                    infoRow("扫描 ID", package.captureID)
                    infoRow("帧数", package.frameCount.map(String.init) ?? "待核对")
                    infoRow("深度帧", package.depthFrameCount.map(String.init) ?? "待核对")
                    infoRow("跳帧记录", package.skippedFrameCount.map(String.init) ?? "待核对")
                    if let createdAt = package.createdAt { infoRow("开始时间", createdAt) }
                    infoRow("上传状态", cloud.statusLabel(for: package.captureID))
                    if let receipt = serverStatus?.verifiedReceipt {
                        infoRow("服务器回执", String(receipt.captureReceiptId.prefix(12)))
                        infoRow("核验时间", receipt.verifiedAt)
                        Text("回执核验了 RGB 原片与逐帧相机信息。LiDAR 深度文件仍在本机；重建质量需要单独验证。")
                            .font(.caption).foregroundStyle(Theme.tertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.top, 10)
            } label: {
                Label("扫描信息", systemImage: "info.circle").font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.text)
            }
            .tint(Theme.secondary)
        }
    }

    private func infoRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.caption).foregroundStyle(Theme.secondary)
            Spacer(minLength: 12)
            Text(value).font(.caption.monospaced()).foregroundStyle(Theme.text)
                .multilineTextAlignment(.trailing).textSelection(.enabled)
        }
    }
}

/// Secondary guidance stays out of the project's primary actions.
struct ReconstructionGuideView: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    guide("快速预览", "bolt.fill", "云端快速预览，先看看整体效果。")
                    guide("精细重建", "sparkles", "云端精细重建，需要更多清晰角度，耗时更长。")
                    guide("本机重建", "iphone.gen3", "用手机训练，素材不上传。锁屏暂停，回来继续。")
                    Text("各版本独立生成。已有结果会保留，可随时尝试其他方式。")
                        .font(.caption).foregroundStyle(Theme.tertiary)
                }.padding(24)
            }
            .background(Theme.background)
            .navigationTitle("选择重建方式").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() }.tint(Theme.accentSoft) }
            }
        }.presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
            .preferredColorScheme(.dark)
    }
    private func guide(_ name: String, _ symbol: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol).foregroundStyle(Theme.accentSoft).frame(width: 24)
            VStack(alignment: .leading, spacing: 5) {
                Text(name).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.text)
                Text(text).font(.subheadline).foregroundStyle(Theme.secondary)
            }
        }
    }
}

/// Capture-quality report, simplified: one verdict, one completeness number, one
/// plain sentence and at most two things to do. All measurements stay one tap away.
private struct ScanAnalysisCard: View {
    let analysis: ScanAnalysis
    @State private var showDetails = false
    private var mode: ScanMode { ScanMode(rawValue: analysis.mode) ?? .object }

    private var verdictColor: Color {
        switch analysis.verdict {
        case "good": return Theme.success
        case "fair": return Theme.warning
        default: return Theme.danger
        }
    }

    /// One sentence on what the coverage means for this scan.
    private var headline: String {
        if mode == .space {
            return String(format: "移动 %.1f 米，视角范围 %d°", analysis.travelMeters, analysis.lookSpanDegrees)
        }
        if analysis.orbitCoverage >= 0.85 {
            return analysis.multiHeightCoverage >= 0.25 ? "已记录多个方向和高度" : "已记录多个方向，上下角度偏少"
        }
        return "绕\(mode == .portrait ? "人" : "物体")约拍到 \(percent(analysis.orbitCoverage))，还有角度没拍到"
    }

    var body: some View {
        Card {
            HStack(spacing: 14) {
                ZStack {
                    Circle().stroke(Theme.surfaceHigh, lineWidth: 6)
                    Circle().trim(from: 0, to: min(1, max(0, analysis.completeness)))
                        .stroke(verdictColor, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Text(percent(analysis.completeness))
                        .font(.system(size: 15, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundStyle(Theme.text)
                }
                .frame(width: 58, height: 58)
                .accessibilityLabel("采集覆盖参考 \(percent(analysis.completeness))")
                VStack(alignment: .leading, spacing: 3) {
                    Text(ScanCaptureAssessment(isComplete: true, analysis: analysis).title).font(.headline).foregroundStyle(verdictColor)
                    Text("采集覆盖参考 · 不代表重建质量").font(.caption2).foregroundStyle(Theme.tertiary)
                    Text(headline).font(.subheadline).foregroundStyle(Theme.secondary)
                }
                Spacer(minLength: 0)
            }
            DisclosureGroup(isExpanded: $showDetails) {
            if analysis.suggestions.isEmpty {
                Label("可以直接上传生成", systemImage: "checkmark.seal.fill")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(Theme.success)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(analysis.suggestions.prefix(2).enumerated()), id: \.offset) { _, tip in
                        Label(tip, systemImage: "lightbulb.fill")
                            .font(.subheadline).foregroundStyle(Theme.text)
                            .labelStyle(TipLabelStyle())
                    }
                }
            }
                details.padding(.top, 10)
            } label: {
                Text("采集检查与建议").font(.caption.weight(.semibold)).foregroundStyle(Theme.secondary)
            }
            .tint(Theme.secondary)
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 10) {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 10) {
                if mode.usesAnchor {
                    tile("circle.dashed", "环绕覆盖", percent(analysis.orbitCoverage), good: analysis.orbitCoverage >= 0.85)
                    tile("arrow.up.and.down", "多高度", percent(analysis.multiHeightCoverage), good: analysis.multiHeightCoverage >= 0.25)
                } else {
                    tile("figure.walk", "移动距离", String(format: "%.1f m", analysis.travelMeters), good: analysis.travelMeters >= 1)
                    tile("binoculars", "视角范围", "\(analysis.lookSpanDegrees)°", good: analysis.lookSpanDegrees >= 60)
                }
                tile("scope", "追踪稳定", percent(analysis.trackingNormalRatio), good: analysis.trackingNormalRatio >= 0.85)
                tile("clock", "时长", String(format: "%.0f 秒 · %d 帧", analysis.durationSeconds, analysis.frameCount),
                     good: analysis.durationSeconds >= 15)
                tile("figure.walk.motion", "平均速度", String(format: "%.2f m/s", analysis.meanSpeed),
                     good: max(analysis.fastMotionRatio, analysis.fastRotationRatio) <= 0.15)
                tile("arrow.triangle.2.circlepath", "转动速度", String(format: "%.0f°/s", analysis.meanAngularSpeedDegrees),
                     good: analysis.fastRotationRatio <= 0.15)
                tile("sun.max", "光线", lightLabel, good: analysis.darkRatio <= 0.3)
                tile("square.grid.3x3", "纹理特征", analysis.meanFeaturePoints.map { "\(Int($0)) 点/帧" } ?? "—",
                     good: analysis.lowTextureRatio <= 0.3)
                tile("ruler", "拍摄距离", analysis.medianTargetDistance.map { String(format: "%.1f m", $0) } ?? "—",
                     good: analysis.medianTargetDistance.map { mode.distanceRange.contains($0) } ?? true)
                tile("dot.radiowaves.left.and.right", "LiDAR 深度", percent(analysis.depthFrameRatio), good: true)
                if let box = analysis.targetBox {
                    tile("mappin.and.ellipse", box.isPerson ? "锚定的人" : "锚定物体", box.sizeLabel, good: true)
                }
            }
            if !analysis.issues.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(analysis.issues.enumerated()), id: \.offset) { _, issue in
                        Label(issue, systemImage: "exclamationmark.circle")
                            .font(.caption).foregroundStyle(Theme.secondary)
                    }
                }
            }
            Text("基于拍摄时的相机轨迹与画面统计估算，仅供参考；完整数据保存在扫描文件夹的 analysis.json。")
                .font(.caption2).foregroundStyle(Theme.tertiary)
        }
    }

    private var lightLabel: String {
        guard let lux = analysis.meanAmbientLux else { return "—" }
        let word = lux < ScanAnalyzer.darkLux ? "偏暗" : (lux < 600 ? "一般" : "明亮")
        return "\(word) · \(Int(lux)) lx"
    }

    private func percent(_ value: Double) -> String { "\(Int((value * 100).rounded()))%" }

    private func tile(_ symbol: String, _ title: String, _ value: String, good: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).font(.caption).foregroundStyle(good ? Theme.accentEnd : Theme.warning)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.caption2).foregroundStyle(Theme.tertiary)
                Text(value).font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(good ? Theme.text : Theme.warning)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Theme.surfaceHigh.opacity(0.6), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// Lightbulb tinted with the accent, text in the regular color, aligned to the first line.
private struct TipLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            configuration.icon.foregroundStyle(Theme.accentEnd)
            configuration.title
        }
    }
}

/// Three-step progress while the original video and metadata are uploaded.
private struct UploadProgressCard: View {
    let phase: String
    private let steps = ["上传原片", "服务器核验", "选择 3DGS 版本"]

    private var currentStep: Int {
        if phase.contains("已核验") { return 2 }
        if phase.contains("核验") && phase.contains("等待") { return 1 }
        return 0
    }

    var body: some View {
        Card {
            HStack {
                Text("正在上传").font(.headline).foregroundStyle(Theme.text)
                Spacer()
                ProgressView().tint(Theme.accent)
            }
            VStack(alignment: .leading, spacing: 14) {
                ForEach(Array(steps.enumerated()), id: \.offset) { index, title in
                    HStack(spacing: 12) {
                        ZStack {
                            Circle().fill(index < currentStep ? Theme.success
                                          : index == currentStep ? Theme.accent : Theme.surfaceHigh)
                                .frame(width: 26, height: 26)
                            if index < currentStep {
                                Image(systemName: "checkmark").font(.caption.weight(.bold)).foregroundStyle(.black)
                            } else {
                                Text("\(index + 1)").font(.caption.weight(.bold)).foregroundStyle(.white)
                            }
                        }
                        Text(title).font(.subheadline.weight(index == currentStep ? .semibold : .regular))
                            .foregroundStyle(index <= currentStep ? Theme.text : Theme.tertiary)
                    }
                }
            }
            Text(phase.isEmpty ? "准备中…" : phase).font(.caption).foregroundStyle(Theme.secondary)
            Text("上传期间请保持应用打开；中断后可回到这里继续，原片会留在本机。")
                .font(.caption).foregroundStyle(Theme.tertiary)
        }
    }
}

/// Consent shown before any original data leaves the phone. Same terms as before,
/// laid out as a readable sheet instead of an alert.
private struct UploadConsentSheet: View {
    @Environment(\.dismiss) private var dismiss
    let destination: String
    var warning: String?
    let onAccept: () -> Void

    private var items: [(String, String)] {
        [
            ("icloud.and.arrow.up", "发送原始 RGB 视频与逐帧 ARKit 相机位姿、内参到 \(destination)"),
            ("sparkles", "核验后不会自动生成 3DGS：快速预览、精细重建、位姿版由你逐个选择"),
            ("leaf", "各版本及重试只对应同一次成长"),
            ("iphone", "LiDAR 深度文件留在本机"),
            ("hand.raised", "本次不授予机器人或视频模型训练许可")
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("上传这次扫描？").font(.title3.weight(.bold)).foregroundStyle(Theme.text)
                .padding(.top, 8)
            if let warning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline).foregroundStyle(Theme.warning)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.warning.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            VStack(alignment: .leading, spacing: 14) {
                ForEach(items, id: \.1) { item in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: item.0).foregroundStyle(Theme.accent).frame(width: 22)
                        Text(item.1).font(.subheadline).foregroundStyle(Theme.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Spacer(minLength: 0)
            GradientButton(title: "同意并上传", symbol: "checkmark") { onAccept() }
            Button("取消") { dismiss() }
                .font(.subheadline.weight(.semibold)).foregroundStyle(Theme.secondary)
                .frame(maxWidth: .infinity)
        }
        .padding(24)
        .background(Theme.surface.ignoresSafeArea())
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

private struct RawVideoPlayer: View {
    @Environment(\.dismiss) private var dismiss
    let url: URL
    @State private var player: AVPlayer?

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.ignoresSafeArea()
            if let player { VideoPlayer(player: player).ignoresSafeArea() }
            GlassIconButton(symbol: "xmark", label: "关闭", size: 40) { dismiss() }.padding(16)
        }
        .onAppear {
            let player = AVPlayer(url: url)
            self.player = player
            player.play()
        }
        .onDisappear { player?.pause() }
    }
}

// MARK: - Settings

private struct ServerSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var cloud: CaptureV2UploadStore

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    NavigationLink {
                        LibraryManagementView(cloud: cloud)
                    } label: {
                        settingsRow("tray.full.fill", "作品管理", nil)
                    }.accessibilityIdentifier("settings.libraryManagement")
                }
                Section {
                    TextField("https://你的服务器地址", text: $cloud.backendInput)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .disabled(cloud.isBusy)
                    Button {
                        Task { await cloud.connect() }
                    } label: {
                        HStack {
                            Text(cloud.isConnected ? "重新连接" : "连接")
                            Spacer()
                            if cloud.isBusy { ProgressView() }
                        }
                    }
                    .disabled(cloud.isBusy)
                    HStack(spacing: 8) {
                        Circle().fill(cloud.isConnected ? Theme.success : Theme.tertiary).frame(width: 8, height: 8)
                        Text(cloud.connectionDisplay).foregroundStyle(Theme.secondary)
                    }
                    if let error = cloud.errorMessage {
                        Text(error).font(.footnote).foregroundStyle(Theme.danger)
                    }
                    #if DEBUG
                    Button("使用 A10 测试服务") { cloud.backendInput = "http://9.135.79.113:8787" }
                        .disabled(cloud.isBusy)
                    #endif
                } header: {
                    Text("服务器")
                } footer: {
                    #if DEBUG
                    Text("扫描和本机保存无需网络。Debug 测试服务需要手机能访问同一内网；正式版仅使用 HTTPS。")
                    #else
                    Text("扫描和本机保存无需网络。")
                    #endif
                }
                Section {
                    settingsRow("info.circle.fill", "版本", Bundle.main.appVersionLabel)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() } } }
        }
    }

    private func settingsRow(_ symbol: String, _ title: String, _ value: String?) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).foregroundStyle(Theme.accent).frame(width: 24)
            Text(title).foregroundStyle(Theme.text)
            Spacer()
            if let value { Text(value).foregroundStyle(Theme.secondary) }
        }
    }
}

private extension Bundle {
    var appVersionLabel: String {
        let version = infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let build = infoDictionary?["CFBundleVersion"] as? String ?? "—"
        return "\(version) (\(build))"
    }
}

/// A temporary file handed to the share sheet.
struct ExportedFile: Identifiable {
    let url: URL
    var id: String { url.path }
}

/// The system share sheet (AirDrop, Files, other apps) for local files.
struct ActivitySheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
