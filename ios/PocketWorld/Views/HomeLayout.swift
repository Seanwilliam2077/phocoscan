import SwiftUI

// AgeScan's library/create layout, using phocoscan's existing brand and real assets.
enum HomeSection: String { case discover, mine }

struct HomeTabBar: View {
    @Binding var selection: HomeSection
    let create: () -> Void
    var body: some View {
        HStack(spacing: 0) {
            item(.discover, "发现", "safari")
            Button(action: create) {
                Image(systemName: "plus").font(.system(size: 25, weight: .semibold))
                    .foregroundStyle(.white).frame(width: 62, height: 62)
                    .background(Theme.accentGradient, in: Circle())
                    .overlay(Circle().stroke(Theme.accentSoft.opacity(0.4), lineWidth: 2))
                    .shadow(color: Theme.accent.opacity(0.35), radius: 12, y: 4)
            }.offset(y: -15).accessibilityLabel("新建扫描或单图作品")
            item(.mine, "我的", "person")
        }
        .frame(height: 64).padding(.horizontal, 12)
        .background(Theme.surfaceHigh, in: Capsule())
        .overlay(Capsule().stroke(Theme.stroke))
        .padding(.horizontal, 44).padding(.bottom, 6)
    }
    private func item(_ tab: HomeSection, _ title: String, _ symbol: String) -> some View {
        Button { selection = tab } label: {
            VStack(spacing: 4) {
                Image(systemName: selection == tab ? symbol + ".fill" : symbol).font(.system(size: 20))
                Text(title).font(.caption2.weight(.semibold))
            }.foregroundStyle(selection == tab ? Theme.accentSoft : Theme.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityAddTraits(selection == tab ? .isSelected : [])
    }
}

struct HomeCreateView: View {
    let scan: (ScanMode) -> Void
    let image: () -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollView {
                HomeModeList(scan: scan, image: image).padding(20)
            }
            .background(Theme.background)
            .navigationTitle("新建").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .tint(Theme.secondary).accessibilityLabel("关闭")
                }
            }
        }.preferredColorScheme(.dark)
    }
}

struct HomeGuidesView: View {
    let scan: (ScanMode) -> Void
    let image: () -> Void
    var body: some View { HomeModeList(scan: scan, image: image) }
}

/// Four visual entries shared by the home page and the create sheet.
/// Instructions appear in context during capture, rather than filling the picker.
struct HomeModeList: View {
    let scan: (ScanMode) -> Void
    let image: () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize
    var body: some View {
        VStack(spacing: 12) {
            ForEach(HomeCreationKind.allCases) { kind in
                Button {
                    if let mode = kind.mode { scan(mode) } else { image() }
                } label: {
                    HStack(spacing: 18) {
                        HomeModeArtwork(kind: kind)
                            .frame(width: typeSize.isAccessibilitySize ? 64 : 88, height: 88)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 7) {
                            Text(kind.title).font(.system(.title3, design: .rounded).weight(.semibold))
                                .lineLimit(typeSize.isAccessibilitySize ? 2 : 1).minimumScaleFactor(0.85)
                                .fixedSize(horizontal: false, vertical: true)
                            if kind == .image {
                                Text("AI").font(.system(size: 10, weight: .bold, design: .rounded))
                                    .foregroundStyle(Theme.accentSoft).padding(.horizontal, 7).padding(.vertical, 3)
                                    .background(Theme.accent.opacity(0.12), in: Capsule())
                            }
                        }.foregroundStyle(Theme.text)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Theme.tertiary).accessibilityHidden(true)
                    }
                    .padding(.leading, 12).padding(.trailing, 22).padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background {
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .fill(LinearGradient(colors: [Theme.surfaceHigh.opacity(0.8), Theme.surface],
                                                 startPoint: .topLeading, endPoint: .bottomTrailing))
                    }
                    .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Theme.stroke))
                }
                .buttonStyle(HomeModeButtonStyle())
                .accessibilityLabel(kind.title)
                .accessibilityHint(kind.mode == nil ? "拍摄或选择照片生成 3DGS" : "打开相机，点击快门开始扫描")
            }
        }
    }
}

private enum HomeCreationKind: CaseIterable, Identifiable {
    case object, portrait, space, image
    var id: Self { self }
    var mode: ScanMode? {
        switch self { case .object: .object; case .portrait: .portrait; case .space: .space; case .image: nil }
    }
    var title: String { mode?.title ?? "单图生成" }
}

private struct HomeModeButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.8 : 1)
            .animation(.easeOut(duration: 0.16), value: configuration.isPressed)
    }
}

/// Small vector illustrations; all four use the same white/violet visual language.
private struct HomeModeArtwork: View {
    let kind: HomeCreationKind
    var body: some View {
        Canvas { context, size in
            let unit = min(size.width, size.height) / 120
            context.translateBy(x: (size.width - unit * 120) / 2, y: (size.height - unit * 120) / 2)
            context.scaleBy(x: unit, y: unit)
            func path(_ points: [CGPoint], closed: Bool = false) -> Path {
                Path { p in
                    guard let first = points.first else { return }
                    p.move(to: first)
                    for point in points.dropFirst() { p.addLine(to: point) }
                    if closed { p.closeSubpath() }
                }
            }
            func line(_ points: [CGPoint], color: Color = Theme.accentSoft, width: CGFloat = 1.5) {
                context.stroke(path(points), with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
            }
            func polygon(_ points: [CGPoint], opacity: Double) {
                context.fill(path(points, closed: true), with: .color(Theme.accent.opacity(opacity)))
            }
            switch kind {
            case .object:
                let top = CGPoint(x: 60, y: 21), left = CGPoint(x: 28, y: 39), right = CGPoint(x: 92, y: 39)
                let center = CGPoint(x: 60, y: 58), bottom = CGPoint(x: 60, y: 96)
                polygon([top, right, center, left], opacity: 0.3)
                polygon([left, center, bottom, CGPoint(x: 28, y: 77)], opacity: 0.08)
                polygon([right, center, bottom, CGPoint(x: 92, y: 77)], opacity: 0.18)
                line([top, right, CGPoint(x: 92, y: 77), bottom, CGPoint(x: 28, y: 77), left, top])
                line([left, center, right]); line([center, bottom])
                for point in [top, center, bottom] {
                    context.fill(Path(ellipseIn: CGRect(x: point.x - 2, y: point.y - 2, width: 4, height: 4)), with: .color(.white))
                }
            case .portrait:
                let head = Path(ellipseIn: CGRect(x: 47, y: 24, width: 26, height: 31))
                context.fill(head, with: .color(Theme.accent.opacity(0.3)))
                context.stroke(head, with: .color(Theme.accentSoft), lineWidth: 1.5)
                let shoulders = Path { p in
                    p.move(to: CGPoint(x: 29, y: 91))
                    p.addCurve(to: CGPoint(x: 91, y: 91), control1: CGPoint(x: 29, y: 48), control2: CGPoint(x: 91, y: 48))
                }
                context.stroke(shoulders, with: .color(Theme.accentSoft), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                line([CGPoint(x: 18, y: 40), CGPoint(x: 18, y: 22), CGPoint(x: 34, y: 22)], color: Theme.accent.opacity(0.5))
                line([CGPoint(x: 86, y: 96), CGPoint(x: 102, y: 96), CGPoint(x: 102, y: 78)], color: Theme.accent.opacity(0.5))
                line([CGPoint(x: 23, y: 77), CGPoint(x: 97, y: 77)], color: Theme.accent, width: 2)
            case .space:
                let a = CGPoint(x: 20, y: 39), b = CGPoint(x: 64, y: 22), c = CGPoint(x: 101, y: 40)
                let d = CGPoint(x: 20, y: 85), e = CGPoint(x: 64, y: 66), f = CGPoint(x: 101, y: 86)
                polygon([a, b, e, d], opacity: 0.06); polygon([b, c, f, e], opacity: 0.18)
                line([d, a, b, c, f, CGPoint(x: 58, y: 104), d]); line([b, e, d]); line([e, f])
                line([CGPoint(x: 44, y: 95), CGPoint(x: 85, y: 77)], color: Theme.accent.opacity(0.4))
                line([CGPoint(x: 38, y: 77), CGPoint(x: 78, y: 95)], color: Theme.accent.opacity(0.4))
                line([CGPoint(x: 75, y: 72), CGPoint(x: 75, y: 46), CGPoint(x: 91, y: 54), CGPoint(x: 91, y: 81)], color: Theme.accentSoft.opacity(0.65))
            case .image:
                let back = Path(roundedRect: CGRect(x: 22, y: 23, width: 65, height: 72), cornerRadius: 8)
                context.stroke(back, with: .color(Theme.accent.opacity(0.3)), lineWidth: 1.5)
                let front = Path(roundedRect: CGRect(x: 31, y: 32, width: 65, height: 72), cornerRadius: 8)
                context.fill(front, with: .color(Theme.surfaceHigh))
                context.stroke(front, with: .color(Theme.accentSoft), lineWidth: 1.5)
                polygon([CGPoint(x: 39, y: 88), CGPoint(x: 55, y: 64), CGPoint(x: 69, y: 79), CGPoint(x: 79, y: 69), CGPoint(x: 88, y: 88)], opacity: 0.28)
                line([CGPoint(x: 39, y: 88), CGPoint(x: 55, y: 64), CGPoint(x: 69, y: 79), CGPoint(x: 79, y: 69), CGPoint(x: 88, y: 88)], width: 1.2)
                context.fill(Path(ellipseIn: CGRect(x: 71, y: 44, width: 8, height: 8)), with: .color(Theme.accentSoft))
                let star = path([CGPoint(x: 94, y: 13), CGPoint(x: 97, y: 23), CGPoint(x: 107, y: 26), CGPoint(x: 97, y: 29), CGPoint(x: 94, y: 39), CGPoint(x: 91, y: 29), CGPoint(x: 81, y: 26), CGPoint(x: 91, y: 23)], closed: true)
                context.fill(star, with: .color(.white))
            }
        }
    }
}

/// Settings owns the management page. Reload from disk after deletion, rather
/// than retaining a snapshot of the library from the presenting screen.
struct LibraryManagementView: View {
    @ObservedObject var cloud: CaptureV2UploadStore
    @State private var packages: [ScanPackage] = []
    @State private var loadError: String?

    var body: some View {
        ScrollView {
            HomeLibraryView(packages: packages, cloud: cloud, openScan: { _ in },
                            details: { _ in }, create: {}, managementMode: true, onDeleted: reload)
                .id(cloud.imageAPI.connectionIdentity?.cacheKey ?? "offline")
                .padding(20)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Theme.background)
        .navigationTitle("作品管理")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: reload)
        .refreshable { reload() }
        .alert("无法读取作品", isPresented: Binding(
            get: { loadError != nil }, set: { if !$0 { loadError = nil } }
        )) {
            Button("重试", action: reload)
            Button("取消", role: .cancel) { loadError = nil }
        } message: { Text(loadError ?? "") }
    }

    private func reload() {
        do { packages = try ScanPackage.loadAll(); loadError = nil }
        catch { loadError = error.localizedDescription }
    }
}

struct HomeLibraryView: View {
    let packages: [ScanPackage]
    @ObservedObject var cloud: CaptureV2UploadStore
    @ObservedObject var reconstructions: NativeReconstructionStore
    @ObservedObject private var local = OnDeviceTrainingStore.shared
    @ObservedObject private var names = ScanNameStore.shared
    @StateObject private var images: ImageGenerationStore
    let openScan: (ScanPackage) -> Void
    let details: (ScanPackage) -> Void
    let create: () -> Void
    let rescan: (ScanPackage) -> Void
    let onDeleted: () -> Void
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let managing: Bool
    @State private var selected: Set<String> = []
    @State private var deleteIDs: Set<String> = []
    @State private var coverageCleanup = false
    @State private var confirmingDelete = false
    @State private var deleting = false
    @State private var deletionMessage: String?
    @State private var source = ScanLibrarySection.scans
    @State private var status = ScanLibraryFilter.all
    @State private var query = ""
    @State private var searching = false
    @FocusState private var searchFocused: Bool
    @State private var imageLibrary = false
    @State private var opening: String?
    @State private var viewedImage: ReadyImage?
    private struct ReadyImage: Identifiable { let id: String; let url: URL; let hint: ImageGeneration.Hint? }
    private struct Item: Identifiable {
        let id: String; let date: Date; let scan: ScanPackage?; let image: ImageGeneration?
        let work: ScanWorkState
        var active: Bool { work.active }
        var deletionBlocked: Bool { work.deletionBlocked }
        var ready: Bool { work.ready }
        var assessment: ScanCaptureAssessment? { scan.map { ScanCaptureAssessment(isComplete: $0.isComplete, analysis: $0.analysis) } }
    }
    init(packages: [ScanPackage], cloud: CaptureV2UploadStore, openScan: @escaping (ScanPackage) -> Void,
         details: @escaping (ScanPackage) -> Void, create: @escaping () -> Void,
         rescan: @escaping (ScanPackage) -> Void = { _ in }, managementMode: Bool = false,
         onDeleted: @escaping () -> Void) {
        self.packages = packages;self.cloud = cloud;self.reconstructions = cloud.reconstructions
        self.openScan = openScan;self.details = details;self.create = create;self.onDeleted = onDeleted
        self.rescan = rescan
        self.managing = managementMode
        _images = StateObject(wrappedValue: ImageGenerationStore(api: cloud.imageAPI))
    }
    private var items: [Item] {
        let scans = packages.map { package in
            let result = reconstructions.result(captureID: package.captureID)
            let localResult = local.result(captureID: package.captureID)
            let linkedImages = images.entries.filter { $0.scanSource?.captureID == package.captureID }
            let phase = local.phases[package.captureID]
            let localActive: Bool = switch phase { case .preparing, .training, .saving: true; default: false }
            let localFailed: Bool = if case .failed = phase { true } else { false }
            let submitting = reconstructions.isBusy(package.captureID)
            let ready = result?.readyResults ?? []
            return Item(id: "scan:" + package.captureID, date: package.createdDate, scan: package, image: nil,
                        work: ScanWorkState(
                            readyCount: ready.count + (localResult == nil ? 0 : 1),
                            activeCount: (result?.tasks.filter(\.isPending).count ?? 0)
                                + (cloud.activeCaptureID == package.captureID || submitting ? 1 : 0)
                                + (localActive ? 1 : 0),
                            failedCount: (result?.tasks.filter(\.canRetry).count ?? 0) + (localFailed ? 1 : 0),
                            downloadFailureCount: ready.filter { reconstructions.downloadErrors[$0.id] != nil }.count,
                            pausedCount: { if case .paused = phase { 1 } else { 0 } }(),
                            linkedImageActive: linkedImages.contains { $0.image.pending || images.busyID == $0.id }))
        }
        let photos = images.entries.map { entry in
            Item(id: "image:" + entry.id, date: Self.date(entry.image.createdAt), scan: nil, image: entry.image,
                 work: ScanWorkState(readyCount: entry.image.status == "ready" ? 1 : 0,
                                     activeCount: entry.image.pending || images.busyID == entry.id ? 1 : 0,
                                     failedCount: entry.image.status == "failed" ? 1 : 0))
        }
        return (scans + photos).sorted { $0.date > $1.date }
    }
    private var sectionItems: [Item] { items.filter { source.includes(isScan: $0.scan != nil) } }
    private var cleanupItems: [Item] {
        items.filter { ScanLibraryCleanup.includes(assessment: $0.assessment, active: $0.deletionBlocked) }
    }
    private var visible: [Item] {
        sectionItems.filter { item in
            status.includes(assessment: item.assessment, active: item.active, ready: item.ready, needsRecovery: item.work.needsRecovery)
            && ScanLibrarySearch.matches(query, fields: searchFields(item))
        }
    }
    private var days: [Date] { Array(Set(visible.map { Calendar.current.startOfDay(for: $0.date) })).sorted(by: >) }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text(managing ? "已选 \(selected.count) 项" : "作品").font(.headline).foregroundStyle(Theme.text)
                Spacer()
                Button {
                    searching.toggle()
                    if !searching { query = "" }
                    searchFocused = searching
                } label: {
                    Image(systemName: searching ? "xmark" : "magnifyingglass").frame(width: 44, height: 44)
                }.accessibilityLabel(searching ? "关闭搜索" : "搜索作品")
                    .accessibilityIdentifier("library.search")
            }
            if searching {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Theme.tertiary)
                    TextField("名称、编号或拍摄模式", text: $query)
                        .focused($searchFocused).submitLabel(.search)
                        .onSubmit { searchFocused = false }
                        .autocorrectionDisabled().foregroundStyle(Theme.text)
                        .accessibilityIdentifier("library.searchField")
                    if !query.isEmpty {
                        Button { query = "" } label: { Image(systemName: "xmark.circle.fill").frame(width: 44, height: 44) }
                            .accessibilityLabel("清空搜索").foregroundStyle(Theme.secondary)
                    }
                }.padding(.horizontal, 12).frame(minHeight: 48)
                    .background(Theme.surfaceHigh, in: RoundedRectangle(cornerRadius: 14))
            }
            if managing {
                HStack {
                    Button("全选当前列表") { selected = Set(visible.filter { !$0.deletionBlocked }.map(\.id)) }
                        .disabled(deleting)
                    Spacer()
                    Button(role: .destructive) { coverageCleanup = false; deleteIDs = selected; confirmingDelete = true } label: {
                        Label("删除", systemImage: "trash")
                    }.disabled(selected.isEmpty || deleting).accessibilityIdentifier("library.deleteSelected")
                }.font(.subheadline)
                if source == .scans {
                    Button(role: .destructive) {
                        coverageCleanup = true
                        deleteIDs = Set(cleanupItems.map(\.id))
                        confirmingDelete = !deleteIDs.isEmpty
                    } label: {
                        Label("清理覆盖低于 80%（\(cleanupItems.count)）", systemImage: "trash")
                            .font(.subheadline).frame(minHeight: 44)
                    }.disabled(cleanupItems.isEmpty || deleting || cloud.isBusy)
                        .accessibilityIdentifier("library.cleanupLowCoverage")
                }
                Text("正在处理的作品完成或取消后可删除。")
                    .font(.caption2).foregroundStyle(Theme.tertiary)
            }
            if deleting { ProgressView("正在删除…").tint(Theme.accent) }
            if let deletionMessage { Text(deletionMessage).font(.caption).foregroundStyle(Theme.warning) }
            HStack(spacing: 0) {
                statistic(sectionItems.count, source == .scans ? "扫描作品" : "单图作品")
                Divider().frame(height: 28)
                statistic(sectionItems.filter(\.ready).count, "可查看")
                Divider().frame(height: 28)
                statistic(sectionItems.filter { $0.assessment?.needsAttention == true || $0.work.needsRecovery }.count, "需处理")
            }.padding(.vertical, 18).background(Theme.surface, in: RoundedRectangle(cornerRadius: 20))
            HStack(spacing: 4) {
                ForEach(ScanLibrarySection.allCases, id: \.self) { section in
                    Button { source = section } label: {
                        Text(section.rawValue).font(.subheadline.weight(.semibold)).foregroundStyle(source == section ? Theme.text : Theme.secondary)
                            .frame(maxWidth: .infinity).padding(.vertical, 10)
                            .background(source == section ? Theme.accent : .clear, in: Capsule())
                    }.buttonStyle(.plain).accessibilityAddTraits(source == section ? .isSelected : [])
                        .accessibilityIdentifier(section == .scans ? "library.scans" : "library.images")
                }
            }.padding(4).background(Theme.surfaceHigh, in: Capsule()).frame(maxWidth: 280)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(ScanLibraryFilter.allCases, id: \.self) { filter in
                        Button { status = filter } label: {
                            Text(filter.rawValue).font(.caption.weight(.medium)).padding(.horizontal, 13).frame(minHeight: 44)
                                .foregroundStyle(status == filter ? Theme.accentSoft : Theme.secondary)
                                .background(status == filter ? Theme.accent.opacity(0.15) : Theme.surface, in: Capsule())
                        }.buttonStyle(.plain).accessibilityAddTraits(status == filter ? .isSelected : [])
                    }
                }
            }
            if source == .scans {
                Text("覆盖参考来自采集记录；生成结果不会改变素材评估。")
                    .font(.caption2).foregroundStyle(Theme.tertiary)
            }
            if visible.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "cube.transparent").font(.system(size: 38, weight: .light)).foregroundStyle(Theme.accentSoft)
                    Text(sectionItems.isEmpty ? (source == .scans ? "还没有扫描作品" : "还没有单图作品") : "没有符合条件的作品").font(.headline).foregroundStyle(Theme.text)
                    if sectionItems.isEmpty {
                        Text(source == .scans ? "扫描物体、人像或空间。" : "拍摄或选择一张照片。")
                            .font(.subheadline).foregroundStyle(Theme.secondary).multilineTextAlignment(.center)
                        if !managing {
                            Button("开始创作", action: create).buttonStyle(.borderedProminent).tint(Theme.accent).padding(.top, 4)
                        }
                    } else {
                        Button("清除筛选") { query = ""; status = .all; searchFocused = false }
                            .font(.subheadline).tint(Theme.accentSoft)
                    }
                }.frame(maxWidth: .infinity).padding(.vertical, 55)
            }
            ForEach(days, id: \.self) { day in
                VStack(alignment: .leading, spacing: 12) {
                    Text(Self.dayTitle(day)).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.secondary)
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: dynamicTypeSize.isAccessibilitySize ? 1 : 2), alignment: .leading, spacing: 12) {
                        ForEach(visible.filter { Calendar.current.isDate($0.date, inSameDayAs: day) }) { item in
                            if let package = item.scan {
                                Button { if managing { toggle(item) } else { openScan(package) } } label: {
                                    ScanCard(package: package, title: names.displayName(for: package.captureID),
                                             stage: projectStage(item, package: package))
                                }.buttonStyle(.plain).disabled(deleting)
                                    .accessibilityIdentifier("scan.card." + package.captureID)
                                    .overlay(alignment: .topTrailing) { selectionMark(item) }
                                    .contextMenu {
                                        if !managing {
                                            Button("项目详情", systemImage: "info.circle") { details(package) }
                                            Button("重新扫描", systemImage: "viewfinder") { rescan(package) }.disabled(deleting)
                                        }
                                        Button("删除", systemImage: "trash", role: .destructive) { coverageCleanup = false; deleteIDs = [item.id]; confirmingDelete = true }
                                            .disabled(item.deletionBlocked || deleting)
                                    }
                            } else if let image = item.image {
                                imageCard(image, item: item)
                                    .overlay(alignment: .topTrailing) { selectionMark(item) }
                                    .contextMenu {
                                        if !managing {
                                            Button("项目详情", systemImage: "info.circle") { imageLibrary = true }
                                        }
                                        Button("删除", systemImage: "trash", role: .destructive) { coverageCleanup = false; deleteIDs = [item.id]; confirmingDelete = true }
                                            .disabled(item.deletionBlocked || deleting)
                                    }
                            }
                        }
                    }
                }
            }
            if let error = images.error { Text(error).font(.caption).foregroundStyle(Theme.danger) }
        }
        // A bulk selection must never silently include works hidden by a new filter.
        .onChange(of: source) { _, _ in selected = []; query = ""; status = .all; deletionMessage = nil }
        .onChange(of: status) { _, _ in selected = [] }
        .onChange(of: query) { _, _ in selected = [] }
        .alert(coverageCleanup ? "清理 \(deleteIDs.count) 项低覆盖扫描？" : "删除 \(deleteIDs.count) 项作品？", isPresented: $confirmingDelete) {
            Button("取消", role: .cancel) { deleteIDs = [] }
            Button("删除", role: .destructive) { Task { await deleteSelection() } }
        } message: {
            Text(coverageCleanup
                 ? "按列表显示的覆盖百分比，清理全部扫描中低于 80% 的 \(deleteIDs.count) 项，不受搜索或状态筛选影响。原素材、历次重建结果及当前账号的云端副本将删除，无法恢复。单图作品、未评估和正在处理的扫描保留。\n\n" + cleanupNames
                 : "将删除所选作品的本机素材、重建结果，以及当前账号的云端副本和关联单图作品。无法恢复；删除失败的项目会保留并提示。")
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            await images.refresh()
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 8_000_000_000) } catch { break }
                if !Task.isCancelled { await images.refresh() }
            }
        }
        .fullScreenCover(isPresented: $imageLibrary, onDismiss: { Task { await images.refresh() } }) { ImageGenerationView(api: cloud.imageAPI) }
        .fullScreenCover(item: $viewedImage) { item in
            NavigationStack {
                GaussianSceneView(url: item.url, predictedView: item.hint, showsTitle: false)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) { Button("关闭") { viewedImage = nil } }
                        ToolbarItem(placement: .topBarTrailing) { ShareLink(item: item.url) { Image(systemName: "square.and.arrow.up") } }
                    }
            }
        }
    }
    private var cleanupNames: String {
        let targets = items.filter { deleteIDs.contains($0.id) }.compactMap(\.scan)
        let labels = targets.prefix(5).map { names.displayName(for: $0.captureID) }.joined(separator: "、")
        return labels + (targets.count > 5 ? "等 \(targets.count) 项" : "")
    }
    private func toggle(_ item: Item) {
        guard !deleting, !item.deletionBlocked else { return }
        if selected.contains(item.id) { selected.remove(item.id) } else { selected.insert(item.id) }
    }
    @ViewBuilder private func selectionMark(_ item: Item) -> some View {
        if managing {
            Image(systemName: selected.contains(item.id) ? "checkmark.circle.fill" : "circle")
                .font(.title2).foregroundStyle(item.deletionBlocked ? Theme.tertiary : Theme.accentSoft)
                .padding(10).background(.black.opacity(0.65), in: Circle()).padding(6)
                .allowsHitTesting(false)
        }
    }
    private func deleteSelection() async {
        guard !deleting else { return }
        let targets = items.filter { deleteIDs.contains($0.id) }
        let cleaningCoverage = coverageCleanup
        deleteIDs = []; deleting = true; deletionMessage = nil
        defer { deleting = false }
        var removed = 0, failed = 0, skipped = 0
        for item in targets {
            // Re-read live state: a selected item may have started processing since selection.
            guard let current = items.first(where: { $0.id == item.id }), !current.deletionBlocked else { skipped += 1; continue }
            if cleaningCoverage && !ScanLibraryCleanup.includes(assessment: current.assessment, active: current.deletionBlocked) {
                skipped += 1; continue
            }
            let succeeded: Bool
            if let package = item.scan {
                succeeded = await cloud.deleteScan(folderURL: package.folderURL, preserveLinkedImages: cleaningCoverage)
                if succeeded { names.setName("", for: package.captureID) }
            } else if let image = item.image { succeeded = await images.delete(image.id) }
            else { succeeded = false }
            if succeeded { removed += 1; selected.remove(item.id) }
            else { failed += 1 }
        }
        onDeleted()
        await images.refresh()
        deletionMessage = failed > 0 ? "已删除 \(removed) 项，\(failed) 项未完成。" + (cloud.errorMessage ?? images.error ?? "请稍后重试。") : "已删除 \(removed) 项"
        if skipped > 0 { deletionMessage = (deletionMessage ?? "") + "，已跳过 \(skipped) 项状态变化的作品。" }
    }
    private func projectStage(_ item: Item, package: ScanPackage) -> ScanStage {
        if let label = item.work.label {
            return ScanStage(label: label,
                             color: item.active ? Theme.accent : item.work.needsRecovery ? Theme.warning : Theme.success,
                             isActive: item.active)
        }
        return ScanStage.of(package, cloud: cloud, store: reconstructions)
    }
    private func searchFields(_ item: Item) -> [String] {
        if let scan = item.scan {
            return [names.displayName(for: scan.captureID), names.numbers[scan.captureID].map(ScanNameStore.autoName) ?? "", scan.displayTitle,
                    ScanMode(rawValue: scan.analysis?.mode ?? "")?.title ?? "", "扫描"]
        }
        return ["单图作品", "AI 生成", Self.dayTitle(item.date)]
    }
    private func statistic(_ value: Int, _ label: String) -> some View {
        VStack(spacing: 5) {
            Text(value.formatted()).font(.title3.bold().monospacedDigit()).foregroundStyle(Theme.text)
            Text(label).font(.caption).foregroundStyle(Theme.secondary)
        }.frame(maxWidth: .infinity)
    }
    private func imageCard(_ image: ImageGeneration, item: Item) -> some View {
        Button {
            if managing { toggle(item); return }
            guard image.status == "ready" else { imageLibrary = true;return }
            guard opening == nil else { return }; opening = image.id
            Task {
                defer { opening = nil }
                do { viewedImage = ReadyImage(id: image.id, url: try await images.api.prepareImageResult(image), hint: image.result?.viewHint) }
                catch { images.error = error.localizedDescription }
            }
        } label: {
            Color.clear.aspectRatio(3.0/4.0, contentMode: .fit)
                .overlay {
                    if let url = images.sourceURL(image.id), let picture = UIImage(contentsOfFile: url.path) {
                        Image(uiImage: picture).resizable().scaledToFill()
                    } else { Theme.surfaceHigh.overlay(Image(systemName: "photo").font(.title).foregroundStyle(Theme.tertiary)) }
                }
                .overlay { LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: .center, endPoint: .bottom) }
                .overlay(alignment: .bottomLeading) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("单图作品").font(.subheadline.weight(.semibold))
                        Text("AI 生成 · " + (image.result.map { ByteCountFormatter.string(fromByteCount: Int64($0.spz.byteSize), countStyle: .file) } ?? "3DGS"))
                            .font(.caption2).foregroundStyle(.white.opacity(0.7))
                    }.foregroundStyle(.white).padding(12)
                }
                .overlay(alignment: .topLeading) { StatusBadge(text: image.statusLabel, color: image.status == "ready" ? Theme.success : image.status == "failed" ? Theme.warning : Theme.accent, pulsing: image.pending).padding(10) }
                .overlay { if opening == image.id { ProgressView().tint(.white) } }
                .clipShape(RoundedRectangle(cornerRadius: 20)).overlay(RoundedRectangle(cornerRadius: 20).stroke(Theme.stroke))
        }.buttonStyle(.plain).disabled(deleting)
    }
    private static func date(_ value: String) -> Date {
        let f = ISO8601DateFormatter();f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = f.date(from: value) { return date };f.formatOptions = [.withInternetDateTime]
        return f.date(from: value) ?? .distantPast
    }
    private static func dayTitle(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return "今天" }
        if Calendar.current.isDateInYesterday(date) { return "昨天" }
        return date.formatted(.dateTime.year().month().day())
    }
}
