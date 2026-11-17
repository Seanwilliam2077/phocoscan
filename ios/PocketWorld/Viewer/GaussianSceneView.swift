import Combine
import MetalKit
import SwiftUI

/// A real, local-file Gaussian Splat viewer; no browser or substitute model is involved.
struct GaussianSceneView: View {
    let url: URL
    let cameraPath: SceneCameraPath?
    let onFailure: ((String) -> Void)?
    let onReady: (() -> Void)?
    let showsTitle: Bool
    /// Keeps only the anchored object or person (nil: no anchor, older scan or poor alignment).
    let crop: SplatCrop?
    /// Optional independently verified subject derivative; Full scene always loads the original.
    let subjectURL: URL?
    /// Orbit-video style (from the scan mode).
    let predictedView: ImageGeneration.Hint?
    let videoStyle: OrbitVideo.Style
    @State private var cropEnabled = true
    @StateObject private var video = OrbitVideoExportController()
    private let cameraValidationError: String?
    /// Free-orbit start view and range from the capture cameras; nil without a camera path.
    private let orbitLimits: OrbitLimits?
    private let anchoredOrbit: SplatCrop.Orbit?
    /// Extra freedom beyond the captured angles before the orbit stops (10°).
    private static let orbitMargin = 10.0 * .pi / 180
    @State private var limitsEnabled = true
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var status = GaussianViewerStatus()
    @StateObject private var livePhoto = LivePhotoExportController()
    @State private var yaw: Float = 0
    @State private var pitch: Float = 0
    @State private var dragOrigin: SIMD2<Float>?
    @State private var distanceScale: Float = 1
    @State private var pinchOrigin: Float?
    @State private var flipUp = false
    @State private var panMode = false
    @State private var panOffset = SIMD2<Float>.zero
    @State private var panOrigin: SIMD2<Float>?
    @State private var roamingCamera: SceneRoamingCamera?
    @State private var isRoaming: Bool
    @State private var moveInput = SIMD2<Float>.zero
    @State private var previousMoveTick: Date?
    @State private var usesCameraPath: Bool
    @State private var tourProgress: Double = 0
    @State private var isPlaying = false
    @State private var previousTick: Date?
    @State private var hasReportedFailure = false
    @State private var showStats = false
    private let playbackClock = Timer.publish(every: 1.0 / 30.0, on: .main, in: .common).autoconnect()

    /// Space reserved at the bottom (e.g. for a host's bottom sheet) so controls stay visible.
    let bottomInset: CGFloat
    let onPoster: ((CGImage) -> Void)?

    init(url: URL, cameraPath: SceneCameraPath? = nil,
         onFailure: ((String) -> Void)? = nil, onReady: (() -> Void)? = nil,
         bottomInset: CGFloat = 0, onPoster: ((CGImage) -> Void)? = nil,
         crop: SplatCrop? = nil, videoStyle: OrbitVideo.Style = .orbit, predictedView: ImageGeneration.Hint? = nil,
         showsTitle: Bool = true, subjectURL: URL? = nil) {
        self.showsTitle = showsTitle
        self.predictedView = predictedView
        self.url = url
        self.crop = crop
        self.subjectURL = subjectURL
        self.videoStyle = videoStyle
        self.bottomInset = bottomInset
        self.onPoster = onPoster
        self.onFailure = onFailure
        self.onReady = onReady
        let validatedPath: SceneCameraPath?
        let validationError: String?
        do {
            validatedPath = try cameraPath?.validated()
            validationError = nil
        } catch {
            validatedPath = nil
            validationError = error.localizedDescription
        }
        self.cameraPath = validatedPath
        self.cameraValidationError = validationError
        let anchored = videoStyle == .flythrough ? nil : validatedPath?.sample(progress: 0).flatMap { crop?.orbit(firstCamera: $0.worldFromCamera) }
        self.anchoredOrbit = anchored
        let limits = validatedPath.flatMap { path in
            anchored.map { OrbitLimits(frames: $0.gravityFrames(path)) } ?? OrbitLimits(path: path)
        }
        self.orbitLimits = limits
        _usesCameraPath = State(initialValue: false)
        _isRoaming = State(initialValue: videoStyle == .flythrough && validatedPath != nil)
        _roamingCamera = State(initialValue: validatedPath?.sample(progress: 0).map { SceneRoamingCamera(origin: $0) })
        _yaw = State(initialValue: anchored?.yaw(flipped: false) ?? limits?.initialYaw(flipped: false) ?? predictedView?.presentation?.yaw ?? 0)
        _pitch = State(initialValue: anchored?.pitch(flipped: false) ?? limits?.initialPitch(flipped: false) ?? predictedView?.presentation?.pitch ?? 0)
    }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            if cameraValidationError == nil {
                GaussianMetalCanvas(url: cropActive ? (subjectURL ?? url) : url, yaw: yaw, pitch: pitch, distanceScale: distanceScale,
                                    flipUp: flipUp, panOffset: panOffset,
                                    anchoredOrbit: anchoredOrbit,
                                    orbitTarget: orbitLimits.map { SIMD3<Float>($0.target) } ?? predictedView?.presentation?.target,
                                    orbitDistance: orbitLimits.map { Float($0.initialDistance) } ?? predictedView?.presentation?.distance,
                                    cameraSample: usesCameraPath ? cameraPath?.sample(progress: tourProgress) : (isRoaming ? roamingCamera?.sample : nil),
                                    cameraFillsViewport: isRoaming && !usesCameraPath,
                                    isActive: scenePhase == .active, status: status, onPoster: onPoster,
                                    crop: cropActive ? crop : nil,
                                    exportController: livePhoto, videoController: video)
                .padding(.bottom, bottomInset)
                .allowsHitTesting(!livePhoto.isBusy && !video.isBusy && status.error == nil)
                .gesture(DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        guard !usesCameraPath else { return }
                        if isRoaming {
                            if dragOrigin == nil { dragOrigin = SIMD2(roamingCamera?.yaw ?? 0, roamingCamera?.pitch ?? 0) }
                            let start = dragOrigin ?? .zero
                            roamingCamera?.look(yaw: start.x - Float(value.translation.width) * 0.005,
                                                pitch: start.y - Float(value.translation.height) * 0.005)
                        } else if panMode {
                            if panOrigin == nil { panOrigin = panOffset }
                            let origin = panOrigin ?? .zero
                            panOffset = origin + SIMD2(Float(value.translation.width) * 0.002,
                                                        -Float(value.translation.height) * 0.002)
                        } else {
                            if dragOrigin == nil { dragOrigin = SIMD2(yaw, pitch) }
                            let origin = dragOrigin ?? .zero
                            yaw = clampedYaw(origin.x + Float(value.translation.width) * 0.008)
                            pitch = clampedPitch(origin.y + Float(value.translation.height) * 0.008)
                        }
                    }
                    .onEnded { _ in dragOrigin = nil; panOrigin = nil })
                .simultaneousGesture(MagnificationGesture()
                    .onChanged { value in
                        guard !usesCameraPath, !isRoaming else { return }
                        if pinchOrigin == nil { pinchOrigin = distanceScale }
                        distanceScale = clampedDistanceScale((pinchOrigin ?? 1) / Float(value))
                    }
                    .onEnded { _ in pinchOrigin = nil })
            }
            if status.isLoading && cameraValidationError == nil {
                VStack(spacing: 14) {
                    ProgressView().tint(.white)
                    Text("正在加载 3DGS…")
                }.foregroundStyle(.white).padding(24)
                    .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 18))
            }
            if let error = cameraValidationError ?? status.error {
                ContentUnavailableView("暂时无法查看", systemImage: "cube.transparent",
                                       description: Text(error)).foregroundStyle(.white)
            }
            // Keep the model unobstructed; secondary tools live in one menu.
            VStack(spacing: 14) {
                toolButton("arrow.counterclockwise", "复位", active: false) {
                    if usesCameraPath { pauseTour(); tourProgress = 0 }
                    else if isRoaming { resetRoaming() }
                    else { resetOrbit() }
                }
                if crop != nil {
                    toolButton("scissors", cropActive ? "主体" : "全景", active: cropActive) {
                        cropEnabled.toggle()
                    }
                    .disabled(livePhoto.isBusy || video.isBusy)
                }
                Menu {
                    if cameraPath != nil {
                        Section("浏览方式") {
                            Button {
                                pauseTour(); usesCameraPath = false
                                isRoaming = false; moveInput = .zero; resetOrbit()
                            } label: { Label("自由旋转", systemImage: "rotate.3d") }
                            Button {
                                pauseTour(); usesCameraPath = false
                                isRoaming = true; resetRoaming()
                            } label: { Label("空间漫游", systemImage: "figure.walk") }
                            Button {
                                pauseTour(); usesCameraPath = true; moveInput = .zero
                            } label: { Label("拍摄轨迹", systemImage: "video.fill") }
                        }
                    }
                    if !usesCameraPath && !isRoaming {
                        Section("视角调整") {
                            Toggle(isOn: $panMode) { Label("拖动平移", systemImage: "hand.draw") }
                            Button {
                                flipUp.toggle()
                                if let orbitLimits {
                                    yaw = anchoredOrbit?.yaw(flipped: flipUp) ?? orbitLimits.initialYaw(flipped: flipUp)
                                    pitch = anchoredOrbit?.pitch(flipped: flipUp) ?? orbitLimits.initialPitch(flipped: flipUp)
                                }
                            } label: { Label("上下翻转", systemImage: "arrow.up.arrow.down") }
                            if orbitLimits != nil {
                                Toggle(isOn: Binding(get: { limitsEnabled }, set: { enabled in
                                    limitsEnabled = enabled
                                    if enabled {
                                        yaw = clampedYaw(yaw); pitch = clampedPitch(pitch)
                                        distanceScale = clampedDistanceScale(distanceScale)
                                    }
                                })) { Label("限制浏览范围", systemImage: "lock.rotation") }
                            }
                        }
                    }
                    if canSaveLivePhoto {
                        Section("保存到相册") {
                            Button(action: saveVideo) { Label("视频", systemImage: "film") }
                            Button(action: saveLivePhoto) { Label("实况照片", systemImage: "livephoto") }
                        }
                    }
                    #if DEBUG
                    Section {
                        Toggle(isOn: $showStats) { Label("性能数据", systemImage: "speedometer") }
                    }
                    #endif
                } label: {
                    toolLabel("ellipsis", "更多", active: false)
                }
                .accessibilityLabel("更多查看选项")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
            .padding(.trailing, 14)
            .padding(.bottom, bottomInset)
            .opacity(status.error == nil && cameraValidationError == nil ? 1 : 0)
            .allowsHitTesting(status.error == nil && cameraValidationError == nil)
            if isRoaming && !usesCameraPath && !livePhoto.isBusy && !video.isBusy {
                movementPad
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .padding(.leading, 20).padding(.bottom, bottomInset + 55)
            }
            livePhotoOverlay
            videoOverlay
            if showStats {
                VStack(alignment: .leading, spacing: 8) {
                    Text(status.statsText)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.white)
                    Button {
                        UIPasteboard.general.string = status.statsText
                    } label: {
                        Label("复制数据", systemImage: "doc.on.doc").font(.caption2.weight(.semibold))
                    }
                    .tint(Theme.accentEnd)
                }
                .padding(10)
                .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.top, 110)
                .padding(.leading, 12)
            }
            // Bottom: tour transport and a one-line hint, above any host sheet.
            VStack(spacing: 10) {
                Spacer()
                if usesCameraPath, let cameraPath, cameraPath.frames.count > 1 {
                    HStack(spacing: 12) {
                        Button {
                            if tourProgress >= 1 { tourProgress = 0 }
                            isPlaying.toggle()
                            previousTick = nil
                        } label: {
                            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 16, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 40, height: 40)
                                .background(Theme.accentGradient, in: Circle())
                        }
                        .disabled(!status.hasPresentedFrame || status.error != nil)
                        .accessibilityLabel(isPlaying ? "暂停游览" : "播放游览")
                        Slider(value: $tourProgress, in: 0...1, onEditingChanged: { editing in
                            if editing { pauseTour() }
                        })
                        .tint(Theme.accent)
                        .accessibilityLabel("拍摄轨迹进度")
                    }
                    .padding(.leading, 6).padding(.trailing, 14).padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: Capsule())
                    .environment(\.colorScheme, .dark)
                }
                Text(hintText).font(.caption).foregroundStyle(.white.opacity(0.7))
                    .shadow(color: .black.opacity(0.6), radius: 4)
                    .accessibilityIdentifier("splat.asset." + (status.sourceURL?.lastPathComponent ?? "loading"))
                    .accessibilityValue(status.hasPresentedFrame ? "已显示" : "加载中")
            }
            .padding(.horizontal, 16)
            .padding(.bottom, bottomInset + 12)
            .foregroundStyle(.white)
            .opacity(status.error == nil && cameraValidationError == nil ? 1 : 0)
            .allowsHitTesting(status.error == nil && cameraValidationError == nil)
        }
        .navigationTitle(showsTitle ? "3DGS" : "")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: status.hasPresentedFrame) { _, presented in
            if presented { onReady?() }
        }
        .onAppear { reportFailureIfNeeded() }
        .onChange(of: status.error) { _, _ in reportFailureIfNeeded() }
        .onChange(of: cameraValidationError) { _, _ in
            hasReportedFailure = false
            reportFailureIfNeeded()
        }
        .onChange(of: url) { _, _ in resetForModel() }
        .onChange(of: status.error) { _, error in
            // A crop that leaves nothing falls back to the whole scene.
            if error == SplatCrop.emptyMessage, cropEnabled { cropEnabled = false }
        }
        .onChange(of: cameraPath) { _, _ in resetForModel() }
        .onChange(of: scenePhase) { _, phase in if phase != .active { pauseTour(); moveInput = .zero; previousMoveTick = nil } }
        .onDisappear { pauseTour(); moveInput = .zero; previousMoveTick = nil; livePhoto.cancel(); video.cancel() }
        .onReceive(playbackClock) { tick($0) }
    }

    private var hintText: String {
        var parts: [String] = []
        if status.isRefining {
            parts.append("正在补充细节 \(Int(Double(status.loadedPoints) / Double(max(1, status.totalPoints)) * 100))%")
        } else if let count = status.pointCount, status.error == nil {
            parts.append("\(count.formatted()) 个高斯点")
        }
        if status.isReduced && status.error == nil { parts.append("已按本机性能精简") }
        if cropActive && status.error == nil { parts.append("已裁掉背景") }
        if usesCameraPath { parts.append("沿拍摄轨迹游览 · 可拖动进度") }
        else if isRoaming { parts.append("拖动画面环顾 · 左下圆盘移动") }
        else {
            parts.append(panMode ? "拖动平移 · 双指缩放" : "拖动旋转 · 双指缩放")
            if orbitLimits != nil && limitsEnabled { parts.append("已限制在拍摄范围内") }
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Live Photo

    private var canSaveLivePhoto: Bool {
        status.hasPresentedFrame && !status.isRefining && !status.isLoading && status.error == nil
            && cameraValidationError == nil && !livePhoto.isBusy && !video.isBusy
    }
    private var cropActive: Bool { crop != nil && cropEnabled }

    // MARK: - Orbit video

    /// Renders the template for this scan (orbit, orbit with a push-in, or a forward drift) from
    /// the loaded model and saves it to Photos as an MP4 video.
    private func saveVideo() {
        pauseTour()
        let center = usesCameraPath
            ? OrbitPose(yaw: anchoredOrbit?.yaw(flipped: false) ?? orbitLimits?.initialYaw(flipped: false) ?? 0,
                        pitch: anchoredOrbit?.pitch(flipped: false) ?? orbitLimits?.initialPitch(flipped: false) ?? 0,
                        distanceScale: 1, panOffset: .zero, flipUp: false)
            : OrbitPose(yaw: yaw, pitch: pitch, distanceScale: distanceScale, panOffset: panOffset, flipUp: flipUp)
        let yawRange = orbitLimitsActive
            ? orbitLimits?.yawRange(flipped: center.flipUp, margin: Self.orbitMargin) : nil
        video.start(poses: OrbitVideo.poses(style: videoStyle, center: center, yawRange: yawRange,
                                            frameCount: OrbitVideo.frameCount))
    }

    @ViewBuilder private var videoOverlay: some View {
        switch video.phase {
        case .idle:
            EmptyView()
        case .rendering(let progress):
            exportCard {
                ProgressView(value: progress).tint(Theme.accent).frame(width: 180)
                Text("正在生成视频 \(Int(progress * 100))%").font(.subheadline)
                Button("取消") { video.cancel() }.font(.caption.weight(.semibold)).tint(.white)
            }
        case .saving:
            exportCard {
                ProgressView().tint(.white)
                Text("正在存入相册…").font(.subheadline)
            }
        case .saved:
            exportCard {
                Label("视频已存入相册", systemImage: "checkmark.circle.fill").font(.subheadline)
            }
            .task {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                video.dismissResult()
            }
        case .failed(let message):
            exportCard {
                Label("保存失败", systemImage: "exclamationmark.triangle.fill").font(.subheadline.weight(.semibold))
                Text(message).font(.caption).multilineTextAlignment(.center)
                Button("好") { video.dismissResult() }.font(.caption.weight(.semibold)).tint(.white)
            }
        }
    }

    /// Renders a short orbit loop of the loaded model around the current free view (or the first
    /// capture viewpoint while touring) and saves it to Photos as a Live Photo.
    private func saveLivePhoto() {
        pauseTour()
        let center = usesCameraPath
            ? OrbitPose(yaw: anchoredOrbit?.yaw(flipped: false) ?? orbitLimits?.initialYaw(flipped: false) ?? 0,
                        pitch: anchoredOrbit?.pitch(flipped: false) ?? orbitLimits?.initialPitch(flipped: false) ?? 0,
                        distanceScale: 1, panOffset: .zero, flipUp: false)
            : OrbitPose(yaw: yaw, pitch: pitch, distanceScale: distanceScale, panOffset: panOffset, flipUp: flipUp)
        let yawRange = orbitLimitsActive
            ? orbitLimits?.yawRange(flipped: center.flipUp, margin: Self.orbitMargin) : nil
        livePhoto.start(center: center, yawRange: yawRange)
    }

    @ViewBuilder private var livePhotoOverlay: some View {
        switch livePhoto.phase {
        case .idle:
            EmptyView()
        case .rendering(let progress):
            exportCard {
                ProgressView(value: progress).tint(Theme.accent).frame(width: 180)
                Text("正在生成实况照片 \(Int(progress * 100))%").font(.subheadline)
                Button("取消") { livePhoto.cancel() }.font(.caption.weight(.semibold)).tint(.white)
            }
        case .saving:
            exportCard {
                ProgressView().tint(.white)
                Text("正在存入相册…").font(.subheadline)
            }
        case .saved:
            exportCard {
                Label("已存入相册（实况照片）", systemImage: "checkmark.circle.fill").font(.subheadline)
            }
            .task {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                livePhoto.dismissResult()
            }
        case .failed(let message):
            exportCard {
                Label("保存失败", systemImage: "exclamationmark.triangle.fill").font(.subheadline.weight(.semibold))
                Text(message).font(.caption).multilineTextAlignment(.center)
                Button("好") { livePhoto.dismissResult() }.font(.caption.weight(.semibold)).tint(.white)
            }
        }
    }

    private func exportCard<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 12, content: content)
            .foregroundStyle(.white)
            .padding(20)
            .frame(maxWidth: 280)
            .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var orbitLimitsActive: Bool { orbitLimits != nil && limitsEnabled }

    private func clampedYaw(_ value: Float) -> Float {
        guard orbitLimitsActive, let range = orbitLimits?.yawRange(flipped: flipUp, margin: Self.orbitMargin) else {
            return value
        }
        return min(range.upperBound, max(range.lowerBound, value))
    }

    private func clampedPitch(_ value: Float) -> Float {
        let range = orbitLimitsActive
            ? orbitLimits?.pitchRange(flipped: flipUp, margin: Self.orbitMargin) ?? -1.45...1.45
            : -1.45...1.45
        return min(range.upperBound, max(range.lowerBound, value))
    }

    private func clampedDistanceScale(_ value: Float) -> Float {
        var range: ClosedRange<Float> = 0.08...8
        if anchoredOrbit == nil, orbitLimitsActive, let limits = orbitLimits?.distanceScaleRange {
            range = max(range.lowerBound, limits.lowerBound)...min(range.upperBound, max(limits.upperBound, 0.08))
        }
        return min(range.upperBound, max(range.lowerBound, value))
    }

    private func toolButton(_ symbol: String, _ title: String, active: Bool,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) { toolLabel(symbol, title, active: active) }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
    }

    private func toolLabel(_ symbol: String, _ title: String, active: Bool) -> some View {
        VStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(active ? Color.white : Color.white.opacity(0.9))
                .frame(width: 44, height: 44)
                .background {
                    if active { Circle().fill(Theme.accentGradient) }
                    else { Circle().fill(.ultraThinMaterial) }
                }
                .environment(\.colorScheme, .dark)
            Text(title).font(.caption2.weight(.medium)).foregroundStyle(.white)
                .shadow(color: .black.opacity(0.7), radius: 3)
        }
    }

    private func resetRoaming() {
        roamingCamera = cameraPath?.sample(progress: 0).map { SceneRoamingCamera(origin: $0) }
        moveInput = .zero; previousMoveTick = nil; dragOrigin = nil
    }

    private var movementPad: some View {
        ZStack {
            Circle().fill(.ultraThinMaterial).frame(width: 92, height: 92)
            Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
                .font(.title3).foregroundStyle(.white.opacity(0.5))
            Circle().fill(.white.opacity(0.85)).frame(width: 32, height: 32)
                .offset(x: CGFloat(moveInput.x) * 28, y: -CGFloat(moveInput.y) * 28)
        }
        .contentShape(Circle())
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { value in
                let vector = SIMD2(Float(value.translation.width), -Float(value.translation.height)) / 28
                moveInput = vector / max(1, simd_length(vector))
            }
            .onEnded { _ in moveInput = .zero; previousMoveTick = nil })
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("移动视点")
        .accessibilityAction(named: Text("前进")) { roamingCamera?.move(right: 0, forward: 0.1) }
        .accessibilityAction(named: Text("后退")) { roamingCamera?.move(right: 0, forward: -0.1) }
        .accessibilityAction(named: Text("向左")) { roamingCamera?.move(right: -0.1, forward: 0) }
        .accessibilityAction(named: Text("向右")) { roamingCamera?.move(right: 0.1, forward: 0) }
    }

    private func resetOrbit() {
        // Start from the first capture viewpoint when the camera path provides one.
        yaw = anchoredOrbit?.yaw(flipped: false) ?? orbitLimits?.initialYaw(flipped: false) ?? predictedView?.presentation?.yaw ?? 0
        pitch = anchoredOrbit?.pitch(flipped: false) ?? orbitLimits?.initialPitch(flipped: false) ?? predictedView?.presentation?.pitch ?? 0
        distanceScale = 1
        panOffset = .zero; flipUp = false; panMode = false
        dragOrigin = nil; pinchOrigin = nil; panOrigin = nil
    }

    private func resetForModel() {
        pauseTour()
        hasReportedFailure = false
        tourProgress = 0
        usesCameraPath = false
        isRoaming = videoStyle == .flythrough && cameraPath != nil
        resetRoaming()
        resetOrbit()
    }

    private func pauseTour() {
        isPlaying = false
        previousTick = nil
    }

    private func reportFailureIfNeeded() {
        guard !hasReportedFailure, let error = cameraValidationError ?? status.error,
              error != SplatCrop.emptyMessage else { return } // handled here: the view falls back to the whole scene
        hasReportedFailure = true
        pauseTour()
        onFailure?(error)
    }

    private func tick(_ date: Date) {
        if isRoaming && !usesCameraPath && scenePhase == .active && status.hasPresentedFrame
            && status.error == nil && !livePhoto.isBusy && !video.isBusy && moveInput != .zero {
            if let previousMoveTick {
                let dt = Float(min(0.05, max(0, date.timeIntervalSince(previousMoveTick))))
                let speed = max(0.01, Float(orbitLimits?.initialDistance ?? 1) * 0.4)
                roamingCamera?.move(right: moveInput.x * speed * dt, forward: moveInput.y * speed * dt)
            }
            previousMoveTick = date
        } else { previousMoveTick = nil }
        guard isPlaying, usesCameraPath, scenePhase == .active,
              status.hasPresentedFrame, !status.isLoading, status.error == nil,
              let cameraPath, cameraPath.duration > 0 else {
            previousTick = nil
            return
        }
        defer { previousTick = isPlaying ? date : nil }
        guard let previousTick else { return }
        // Do not jump through the path after a stalled frame or an interrupted run loop.
        let elapsed = min(0.1, max(0, date.timeIntervalSince(previousTick)))
        tourProgress = min(1, tourProgress + elapsed / cameraPath.duration)
        if tourProgress >= 1 { isPlaying = false }
    }
}

@MainActor
final class GaussianViewerStatus: ObservableObject {
    @Published var isLoading = true
    @Published var error: String?
    @Published var pointCount: Int?
    @Published var hasPresentedFrame = false
    @Published var sourceURL: URL?
    @Published var firstFrameSeconds: Double?
    // Progressive loading and device budget (R1).
    @Published var totalPoints = 0
    @Published var loadedPoints = 0
    @Published var prunedFrom: Int?
    @Published var shDegree: Int?
    @Published var sourceSHDegree: Int?
    @Published var fullLoadSeconds: Double?
    @Published var budgetSummary = ""
    // Live performance (R0), published at 2 Hz.
    @Published var fps: Double = 0
    @Published var gpuMs: Double = 0
    @Published var renderScale: CGFloat = 0
    @Published var availableMemoryMB = 0
    @Published var thermal = ""
    @Published var isIdle = false

    var isRefining: Bool { hasPresentedFrame && totalPoints > 0 && loadedPoints < totalPoints }
    /// True when this device shows fewer splats or SH bands than the file contains.
    var isReduced: Bool { prunedFrom != nil || (shDegree ?? 0) < (sourceSHDegree ?? 0) }

    var statsText: String {
        func seconds(_ value: Double?) -> String { value.map { String(format: "%.2f s", $0) } ?? "—" }
        var lines = ["档位 \(budgetSummary)"]
        lines.append("点数 \(loadedPoints.formatted()) / \(totalPoints.formatted())"
                     + (prunedFrom.map { "（原 \($0.formatted())，已精简）" } ?? ""))
        lines.append("SH \(shDegree.map(String.init) ?? "—")" + (sourceSHDegree.map { " / 文件 \($0)" } ?? ""))
        lines.append("首帧 \(seconds(firstFrameSeconds)) · 完整 \(seconds(fullLoadSeconds))")
        lines.append(isIdle ? "空闲暂停（静止时不重绘）"
                            : String(format: "%.0f fps · GPU %.1f ms · 分辨率 %.2f×", fps, gpuMs, renderScale))
        lines.append("可用内存 \(availableMemoryMB) MB · 热状态 \(thermal)")
        return lines.joined(separator: "\n")
    }
}

private struct GaussianMetalCanvas: UIViewRepresentable {
    let url: URL
    let yaw: Float
    let pitch: Float
    let distanceScale: Float
    let flipUp: Bool
    let panOffset: SIMD2<Float>
    let anchoredOrbit: SplatCrop.Orbit?
    let orbitTarget: SIMD3<Float>?
    let orbitDistance: Float?
    let cameraSample: SceneCameraSample?
    let cameraFillsViewport: Bool
    let isActive: Bool
    let status: GaussianViewerStatus
    let onPoster: ((CGImage) -> Void)?
    let crop: SplatCrop?
    let exportController: LivePhotoExportController
    let videoController: OrbitVideoExportController

    final class Coordinator {
        var renderer: PocketSplatRenderer?
        var loadTask: Task<Void, Never>?
        var loadedURL: URL?
        var loadedCrop: SplatCrop?
        var unloadTask: Task<Void, Never>?
        var unloadedForBackground = false
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        view.isOpaque = true
        view.isPaused = !isActive
        view.colorPixelFormat = .bgra8Unorm_srgb
        view.depthStencilPixelFormat = .depth32Float
        view.sampleCount = 1
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        view.framebufferOnly = false // Allows copying one rendered frame as the cover image.
        do {
            let renderer = try PocketSplatRenderer(view: view, status: status, screenScale: UIScreen.main.scale)
            renderer.cameraSample = cameraSample
            renderer.cameraFillsViewport = cameraFillsViewport
            renderer.anchoredOrbit = anchoredOrbit
            renderer.orbitTarget = orbitTarget
            renderer.orbitDistance = orbitDistance
            renderer.onPoster = onPoster
            context.coordinator.renderer = renderer
            exportController.renderer = renderer
            videoController.renderer = renderer
            view.delegate = renderer
            load(url, coordinator: context.coordinator)
        } catch {
            Task { @MainActor in status.isLoading = false; status.error = error.localizedDescription }
        }
        return view
    }

    func updateUIView(_ uiView: MTKView, context: Context) {
        let coordinator = context.coordinator
        let renderer = coordinator.renderer
        renderer?.isActive = isActive
        // The renderer resumes itself on activity and pauses when the view is still.
        if !isActive || status.error != nil { uiView.isPaused = true }
        if isActive {
            coordinator.unloadTask?.cancel()
            coordinator.unloadTask = nil
            if coordinator.unloadedForBackground {
                coordinator.unloadedForBackground = false
                coordinator.loadedURL = nil // reload below
            }
        } else if coordinator.unloadTask == nil && !coordinator.unloadedForBackground {
            // Free GPU memory if the app stays in the background.
            coordinator.unloadTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard !Task.isCancelled else { return }
                coordinator.loadTask?.cancel()
                coordinator.renderer?.unload()
                coordinator.unloadedForBackground = true
                coordinator.unloadTask = nil
            }
        }
        renderer?.yaw = yaw
        renderer?.pitch = pitch
        renderer?.distanceScale = distanceScale
        renderer?.flipUp = flipUp
        renderer?.panOffset = panOffset
        renderer?.anchoredOrbit = anchoredOrbit
        renderer?.orbitTarget = orbitTarget
        renderer?.orbitDistance = orbitDistance
        renderer?.cameraSample = cameraSample
        renderer?.cameraFillsViewport = cameraFillsViewport
        load(url, coordinator: context.coordinator)
    }

    private func load(_ url: URL, coordinator: Coordinator) {
        guard coordinator.loadedURL != url || coordinator.loadedCrop != crop, let renderer = coordinator.renderer else { return }
        coordinator.loadedURL = url
        coordinator.loadedCrop = crop
        renderer.crop = crop
        coordinator.loadTask?.cancel()
        coordinator.loadTask = Task { await renderer.load(url: url) }
    }

    static func dismantleUIView(_ uiView: MTKView, coordinator: Coordinator) {
        coordinator.unloadTask?.cancel()
        coordinator.loadTask?.cancel()
        coordinator.loadTask = nil
        uiView.isPaused = true
        uiView.delegate = nil
        coordinator.renderer?.invalidate()
        coordinator.renderer = nil
        uiView.releaseDrawables()
    }
}
