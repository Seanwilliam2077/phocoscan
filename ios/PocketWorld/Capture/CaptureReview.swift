import AVFoundation
import SceneKit
import SwiftUI
import simd

/// What the phone actually recorded, for checking a scan before upload: LiDAR depth
/// back-projected with the recorded ARKit poses, the walked camera path and the anchor
/// ring. Points are green where the surface was seen from several angles and red
/// where it was seen from too few (`QualityVolume`, the same rule as the live panel);
/// the recorded video colors remain available. It replays captured data only; it is
/// not a reconstruction or a quality grade.
struct CaptureReviewModel {
    struct PointSet {
        var positions: [SIMD3<Float>] = []
        var colors: [SIMD3<Float>] = []
        /// 2 = seen from several angles (green), 1 = too few views (red), 0 = unknown.
        var quality: [UInt8] = []
        var count: Int { positions.count }

        mutating func append(_ position: SIMD3<Float>, _ color: SIMD3<Float>, _ grade: UInt8) {
            positions.append(position); colors.append(color); quality.append(grade)
        }
    }

    var near = PointSet()
    var all = PointSet()
    var path: [SIMD3<Float>] = []
    var target: ScanTargetBox?
    var coverage: ScanCoverage?
    var keyframeCount = 0
    var depthFrameCount = 0
    /// Share of captured surface cells (near the anchor when there is one) that are green.
    var goodFraction: Double?

    var focus: SIMD3<Float> {
        if let target { return target.simdCenter }
        let source = all.count > 0 ? all.positions : path
        guard !source.isEmpty else { return .zero }
        return source.reduce(.zero, +) / Float(source.count)
    }
}

enum CaptureReviewError: LocalizedError {
    case unreadable
    var errorDescription: String? { "无法读取这次扫描的逐帧数据。" }
}

/// Builds `CaptureReviewModel` from a saved `.scan` folder. Pure file processing.
enum CaptureReviewBuilder {
    /// The last few reviews built this session, so reopening one is instant.
    @MainActor static var cache: [URL: CaptureReviewModel] = [:]

    static let maxKeyframes = 48
    static let pixelStride = 2
    static let maxPoints = 400_000

    struct Frame: Decodable {
        struct Aux: Decodable { let file: String; let width: Int; let height: Int }
        let index: Int
        let videoPTSSeconds: Double
        let cameraImageWidth: Int
        let cameraImageHeight: Int
        let cameraToWorldARKit: [[Float]]
        let intrinsicsPixels: [[Float]]
        let trackingState: String
        let depth: Aux?
        let confidence: Aux?
        var arTimestampSeconds: Double? = nil

        var isTracked: Bool { trackingState == "normal" }
        var position: SIMD3<Float>? {
            guard cameraToWorldARKit.count == 4, cameraToWorldARKit.allSatisfy({ $0.count == 4 }) else { return nil }
            return SIMD3(cameraToWorldARKit[0][3], cameraToWorldARKit[1][3], cameraToWorldARKit[2][3])
        }
    }

    static func build(folder: URL, analysis: ScanAnalysis?,
                      progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> CaptureReviewModel {
        let framesData = try Data(contentsOf: folder.appendingPathComponent("frames.jsonl"))
        let decoder = JSONDecoder()
        let frames: [Frame] = framesData.split(separator: 0x0a).compactMap { try? decoder.decode(Frame.self, from: Data($0)) }
        guard !frames.isEmpty else { throw CaptureReviewError.unreadable }

        var model = CaptureReviewModel()
        model.target = analysis?.targetBox
        model.coverage = analysis?.coverage
        model.path = frames.enumerated().compactMap { $0.offset % 2 == 0 && $0.element.isTracked ? $0.element.position : nil }

        let withDepth = frames.filter { $0.isTracked && $0.depth != nil && safe($0.depth!.file) }
        model.depthFrameCount = withDepth.count
        guard !withDepth.isEmpty else { return model }
        let step = max(1, Int((Double(withDepth.count) / Double(maxKeyframes)).rounded(.up)))
        let keyframes = Swift.stride(from: 0, to: withDepth.count, by: step).map { withDepth[$0] }
        model.keyframeCount = keyframes.count

        let colors = try await sampleColors(video: folder.appendingPathComponent("video.mov"),
                                            keyframes: keyframes, progress: progress)
        try Task.checkCancellation()

        // New scans count only JPEGs that were saved, exactly like the live panel.
        // Older scans have no keyframe package and retain their original review.
        let saved = savedViewTimes(folder: folder)
        var volume = QualityVolume(target: model.target, cropToTarget: false, maxCells: 400_000)
        var lastView: Double?
        for frame in withDepth {
            if let saved {
                guard let timestamp = frame.arTimestampSeconds, timestamp.isFinite,
                      abs(timestamp) < 1e10, saved.contains(Int64((timestamp * 1e6).rounded())) else { continue }
            }
            if let lastView, frame.videoPTSSeconds - lastView < QualityVolume.viewInterval { continue }
            guard let aux = frame.depth, let view = qualityView(frame: frame, aux: aux, folder: folder) else { continue }
            lastView = frame.videoPTSSeconds
            volume.add(points: view.points, camera: view.camera)
            try Task.checkCancellation()
        }
        if let target = model.target {
            let region = QualityVolume.Region(target: target)
            let near = volume.cells.values.filter { region.contains($0.center) }
            model.goodFraction = near.isEmpty ? nil : Double(near.filter(\.isGood).count) / Double(near.count)
        } else if !volume.cells.isEmpty {
            model.goodFraction = volume.goodFraction
        }

        let voxel: Float = model.target.map { min(0.015, max(0.002, $0.ringRadius / 50)) } ?? 0.01
        var grid: [SIMD3<Int32>: (sum: SIMD3<Float>, color: SIMD3<Float>, count: Float)] = [:]
        for frame in keyframes {
            guard let aux = frame.depth, let points = unproject(frame: frame, aux: aux, folder: folder,
                                                                colors: colors[frame.index]) else { continue }
            for (point, color) in points {
                let key = SIMD3<Int32>(Int32((point.x / voxel).rounded(.down)),
                                       Int32((point.y / voxel).rounded(.down)),
                                       Int32((point.z / voxel).rounded(.down)))
                if var cell = grid[key] {
                    cell.sum += point; cell.color += color; cell.count += 1
                    grid[key] = cell
                } else {
                    grid[key] = (point, color, 1)
                }
            }
            try Task.checkCancellation()
        }
        var all = CaptureReviewModel.PointSet()
        let keep = max(1, grid.count / maxPoints + (grid.count % maxPoints == 0 ? 0 : 1))
        for (n, cell) in grid.values.enumerated() where n % keep == 0 {
            let position = cell.sum / cell.count
            let grade: UInt8 = volume.isGood(at: position).map { $0 ? 2 : 1 } ?? 0
            all.append(position, cell.color / cell.count, grade)
        }
        model.all = all
        if let target = model.target {
            let region = QualityVolume.Region(target: target)
            for i in all.positions.indices where region.contains(all.positions[i]) {
                model.near.append(all.positions[i], all.colors[i], all.quality[i])
            }
        } else {
            model.near = all
        }
        return model
    }

    static func savedViewTimes(folder: URL) -> Set<Int64>? {
        let file = folder.appendingPathComponent("capture/transforms.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        struct Saved: Decodable {
            struct View: Decodable { let timestamp: Double; let subject_moving: Bool? }
            let frames: [View]
        }
        guard let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode(Saved.self, from: data) else { return [] }
        return Set(saved.frames.compactMap {
            guard $0.subject_moving != true, $0.timestamp.isFinite, abs($0.timestamp) < 1e10 else { return nil }
            return Int64(($0.timestamp * 1e6).rounded())
        })
    }

    /// One frame's LiDAR view for the quality volume, sampled exactly like the live panel.
    static func qualityView(frame: Frame, aux: Frame.Aux, folder: URL) -> (points: [SIMD3<Float>], camera: SIMD3<Float>)? {
        let width = aux.width, height = aux.height
        guard width > 0, height > 0, frame.cameraImageWidth > 0, frame.cameraImageHeight > 0,
              frame.intrinsicsPixels.count == 3, frame.intrinsicsPixels.allSatisfy({ $0.count == 3 }),
              let pose = QualityVolume.matrix(rowMajor: frame.cameraToWorldARKit),
              let depthData = try? Data(contentsOf: folder.appendingPathComponent(aux.file)),
              depthData.count == width * height * 4 else { return nil }
        let depth: [Float] = depthData.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        var confidence: [UInt8]?
        if let c = frame.confidence, safe(c.file), c.width == width, c.height == height,
           let data = try? Data(contentsOf: folder.appendingPathComponent(c.file)), data.count == width * height {
            confidence = [UInt8](data)
        }
        let k = frame.intrinsicsPixels
        let sx = Float(width) / Float(frame.cameraImageWidth), sy = Float(height) / Float(frame.cameraImageHeight)
        let points = QualityVolume.unproject(width: width, height: height,
                                             intrinsics: SIMD4(k[0][0] * sx, k[1][1] * sy, k[0][2] * sx, k[1][2] * sy),
                                             cameraToWorld: pose, depth: { depth[$0] },
                                             confidence: confidence.map { values in { values[$0] } })
        return (points, SIMD3(pose.columns.3.x, pose.columns.3.y, pose.columns.3.z))
    }

    /// Relative path inside the scan folder only.
    private static func safe(_ file: String) -> Bool {
        !file.isEmpty && !file.hasPrefix("/") && !file.split(separator: "/").contains("..")
    }

    /// LiDAR pixels (every `pixelStride`) as world points with their video color.
    static func unproject(frame: Frame, aux: Frame.Aux, folder: URL,
                          colors: [SIMD3<Float>]?) -> [(SIMD3<Float>, SIMD3<Float>)]? {
        let width = aux.width, height = aux.height
        guard width > 0, height > 0, frame.cameraImageWidth > 0, frame.cameraImageHeight > 0,
              frame.intrinsicsPixels.count == 3, frame.intrinsicsPixels.allSatisfy({ $0.count == 3 }),
              frame.cameraToWorldARKit.count == 4, frame.cameraToWorldARKit.allSatisfy({ $0.count == 4 }),
              let depthData = try? Data(contentsOf: folder.appendingPathComponent(aux.file)),
              depthData.count == width * height * 4 else { return nil }
        let depth: [Float] = depthData.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        var confidence: [UInt8]?
        if let c = frame.confidence, safe(c.file), c.width == width, c.height == height,
           let data = try? Data(contentsOf: folder.appendingPathComponent(c.file)), data.count == width * height {
            confidence = [UInt8](data)
        }
        let k = frame.intrinsicsPixels, m = frame.cameraToWorldARKit
        let sx = Float(width) / Float(frame.cameraImageWidth), sy = Float(height) / Float(frame.cameraImageHeight)
        let fx = k[0][0] * sx, fy = k[1][1] * sy, cx = k[0][2] * sx, cy = k[1][2] * sy
        guard fx > 0, fy > 0 else { return nil }
        let gridWidth = (width + pixelStride - 1) / pixelStride
        var result: [(SIMD3<Float>, SIMD3<Float>)] = []
        result.reserveCapacity(depth.count / (pixelStride * pixelStride))
        for y in Swift.stride(from: 0, to: height, by: pixelStride) {
            for x in Swift.stride(from: 0, to: width, by: pixelStride) {
                let index = y * width + x
                let d = depth[index]
                guard d.isFinite, d > 0.1, d < 4 else { continue }
                if let confidence, confidence[index] < 1 { continue }
                // ARKit camera: +x right, +y up, looking down -z; image v grows downward.
                let lx = (Float(x) + 0.5 - cx) / fx * d, ly = -(Float(y) + 0.5 - cy) / fy * d, lz = -d
                let world = SIMD3<Float>(m[0][0] * lx + m[0][1] * ly + m[0][2] * lz + m[0][3],
                                         m[1][0] * lx + m[1][1] * ly + m[1][2] * lz + m[1][3],
                                         m[2][0] * lx + m[2][1] * ly + m[2][2] * lz + m[2][3])
                let color = colors.flatMap { c -> SIMD3<Float>? in
                    let g = (y / pixelStride) * gridWidth + x / pixelStride
                    return g < c.count ? c[g] : nil
                } ?? SIMD3(0.8, 0.8, 0.85)
                result.append((world, color))
            }
        }
        return result
    }

    /// Decodes the recorded video once and samples each keyframe's colors on its
    /// depth grid. Frames are matched by their recorded presentation time.
    static func sampleColors(video: URL, keyframes: [Frame],
                             progress: @escaping @Sendable (Double) -> Void) async throws -> [Int: [SIMD3<Float>]] {
        let asset = AVURLAsset(url: video)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { return [:] }
        let duration = try await asset.load(.duration).seconds
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return [:] }
        reader.add(output)
        guard reader.startReading() else { return [:] }
        defer { reader.cancelReading() }
        var wanted: [Int: Frame] = [:]
        for frame in keyframes { wanted[Int((frame.videoPTSSeconds * 1000).rounded())] = frame }
        let lastTime = keyframes.map(\.videoPTSSeconds).max() ?? duration
        var result: [Int: [SIMD3<Float>]] = [:]
        var reported = 0
        while result.count < keyframes.count, let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            let pts = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            guard pts.isFinite else { continue }
            let percent = lastTime > 0 ? Int(min(1, pts / lastTime) * 100) : 0
            if percent >= reported + 2 { reported = percent; progress(Double(percent) / 100) }
            let ms = Int((pts * 1000).rounded())
            guard let frame = wanted[ms] ?? wanted[ms - 1] ?? wanted[ms + 1],
                  result[frame.index] == nil, let aux = frame.depth,
                  let image = CMSampleBufferGetImageBuffer(sample) else { continue }
            result[frame.index] = colors(of: image, width: aux.width, height: aux.height)
        }
        return result
    }

    /// RGB on the depth grid (every `pixelStride` depth pixel) from a full-range 4:2:0 frame.
    static func colors(of image: CVPixelBuffer, width: Int, height: Int) -> [SIMD3<Float>]? {
        guard CVPixelBufferGetPlaneCount(image) == 2 else { return nil }
        CVPixelBufferLockBaseAddress(image, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(image, .readOnly) }
        guard let yPlane = CVPixelBufferGetBaseAddressOfPlane(image, 0)?.assumingMemoryBound(to: UInt8.self),
              let cPlane = CVPixelBufferGetBaseAddressOfPlane(image, 1)?.assumingMemoryBound(to: UInt8.self) else { return nil }
        let imageWidth = CVPixelBufferGetWidthOfPlane(image, 0), imageHeight = CVPixelBufferGetHeightOfPlane(image, 0)
        let yRow = CVPixelBufferGetBytesPerRowOfPlane(image, 0), cRow = CVPixelBufferGetBytesPerRowOfPlane(image, 1)
        let chromaWidth = CVPixelBufferGetWidthOfPlane(image, 1), chromaHeight = CVPixelBufferGetHeightOfPlane(image, 1)
        guard imageWidth > 0, imageHeight > 0, chromaWidth > 0, chromaHeight > 0 else { return nil }
        var colors: [SIMD3<Float>] = []
        colors.reserveCapacity(((width + pixelStride - 1) / pixelStride) * ((height + pixelStride - 1) / pixelStride))
        for y in Swift.stride(from: 0, to: height, by: pixelStride) {
            let iy = min(imageHeight - 1, Int((Float(y) + 0.5) * Float(imageHeight) / Float(height)))
            let cy = min(chromaHeight - 1, iy / 2)
            for x in Swift.stride(from: 0, to: width, by: pixelStride) {
                let ix = min(imageWidth - 1, Int((Float(x) + 0.5) * Float(imageWidth) / Float(width)))
                let cx = min(chromaWidth - 1, ix / 2)
                let luma = Float(yPlane[iy * yRow + ix])
                let cb = Float(cPlane[cy * cRow + cx * 2]) - 128
                let cr = Float(cPlane[cy * cRow + cx * 2 + 1]) - 128
                let rgb = SIMD3<Float>(luma + 1.402 * cr, luma - 0.344136 * cb - 0.714136 * cr, luma + 1.772 * cb)
                colors.append(simd_clamp(rgb / 255, SIMD3(repeating: 0), SIMD3(repeating: 1)))
            }
        }
        return colors
    }
}

// MARK: - Colors

/// The review's two colors (plus white for the anchor and path).
enum ReviewPalette {
    static let good = SIMD3<Float>(0.25, 0.84, 0.62)   // Theme.success
    static let weak = SIMD3<Float>(1.0, 0.30, 0.37)    // Theme.danger
    static let unknown = SIMD3<Float>(0.6, 0.6, 0.62)

    static func color(grade: UInt8) -> SIMD3<Float> {
        switch grade {
        case 2: return good
        case 1: return weak
        default: return unknown
        }
    }

    /// Quality color shaded by the recorded brightness so the object's shape stays readable.
    static func shaded(grade: UInt8, rgb: SIMD3<Float>) -> SIMD3<Float> {
        let luma = simd_dot(rgb, SIMD3(0.299, 0.587, 0.114))
        return color(grade: grade) * (0.7 + 0.3 * luma)
    }
}

// MARK: - Review screen

/// Full-screen "采集检查": orbit the captured LiDAR points, path and coverage ring.
struct CaptureReviewView: View {
    let folder: URL
    let analysis: ScanAnalysis?
    @Environment(\.dismiss) private var dismiss
    @State private var model: CaptureReviewModel?
    @State private var errorMessage: String?
    @State private var progress = 0.0
    @State private var showAll = false
    @State private var originalColors = false

    private var mode: ScanMode { analysis.flatMap { ScanMode(rawValue: $0.mode) } ?? .object }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let model {
                ReviewSceneView(model: model, showAll: showAll || model.target == nil, originalColors: originalColors)
                    .ignoresSafeArea()
            } else if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.warning).padding()
            } else {
                VStack(spacing: 12) {
                    ProgressView(value: progress).tint(Theme.success).frame(width: 180)
                    Text("正在读取采集数据…").font(.subheadline).foregroundStyle(.white.opacity(0.8))
                }
            }
            VStack(spacing: 12) {
                topBar
                Spacer()
                if let model { legend(model) }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
        .foregroundStyle(.white)
        .statusBarHidden()
        .task {
            let folder = folder, analysis = analysis
            if let cached = CaptureReviewBuilder.cache[folder] { model = cached; return }
            do {
                let built = try await Task.detached(priority: .userInitiated) {
                    try await CaptureReviewBuilder.build(folder: folder, analysis: analysis) { value in
                        Task { @MainActor in progress = value }
                    }
                }.value
                if CaptureReviewBuilder.cache.count >= 3 { CaptureReviewBuilder.cache.removeAll() }
                CaptureReviewBuilder.cache[folder] = built
                withAnimation(.easeOut(duration: 0.3)) { model = built }
            } catch is CancellationError {
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            GlassIconButton(symbol: "xmark", label: "关闭", size: 40) { dismiss() }
            VStack(alignment: .leading, spacing: 1) {
                Text("采集检查").font(.headline)
                Text("拍到的原始数据，不是重建结果").font(.caption2).foregroundStyle(.white.opacity(0.65))
            }
            Spacer()
            if model?.target != nil && model?.all.count ?? 0 > 0 {
                segmented([mode == .portrait ? "人附近" : "物体附近", "全部"], selected: showAll ? 1 : 0) { showAll = $0 == 1 }
            }
        }
        .padding(.top, 8)
    }

    private func segmented(_ titles: [String], selected: Int, action: @escaping (Int) -> Void) -> some View {
        HStack(spacing: 2) {
            ForEach(titles.indices, id: \.self) { index in
                Button { action(index) } label: {
                    Text(titles[index]).font(.caption.weight(.semibold))
                        .padding(.horizontal, 10).frame(height: 28)
                        .background { if index == selected { Capsule().fill(.white.opacity(0.22)) } }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(.black.opacity(0.5), in: Capsule())
    }

    private func legend(_ model: CaptureReviewModel) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(summary(model)).font(.subheadline.weight(.semibold))
                Spacer(minLength: 8)
                if model.all.count > 0 {
                    segmented(["质量", "原色"], selected: originalColors ? 1 : 0) { originalColors = $0 == 1 }
                }
            }
            if model.all.count > 0 {
                if originalColors {
                    legendRow(color: .white, "原片颜色：用来确认拍到的是什么")
                } else {
                    legendRow(color: Theme.success, "绿色：从多个角度拍到，数据充足")
                    legendRow(color: Theme.danger, "红色：只从一两个角度拍到，数据不足；没有点的地方就是没拍到")
                }
            } else {
                legendRow(color: Theme.warning, "这次没有可用的深度数据，只能显示拍摄路线和覆盖角度")
            }
            Text("单指拖动旋转 · 双指缩放和平移").font(.caption2).foregroundStyle(.white.opacity(0.55))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func legendRow(color: Color, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(text).font(.caption).foregroundStyle(.white.opacity(0.85))
        }
    }

    private func summary(_ model: CaptureReviewModel) -> String {
        if let fraction = model.goodFraction {
            return "数据充足（绿）\(Int((fraction * 100).rounded()))%"
        }
        guard let analysis else { return "\(model.keyframeCount) 个深度关键帧" }
        if mode == .space {
            return String(format: "移动 %.1f 米 · 视角范围 %d°", analysis.travelMeters, analysis.lookSpanDegrees)
        }
        return "绕\(mode == .portrait ? "人" : "物体")约拍到 \(Int((analysis.orbitCoverage * 100).rounded()))%"
    }
}

// MARK: - Scene

/// SceneKit view of the review model; orbit camera centered on the anchor.
struct ReviewSceneView: UIViewRepresentable {
    let model: CaptureReviewModel
    let showAll: Bool
    var originalColors = false

    final class Coordinator {
        var scene: SCNScene?
        var cloud: SCNNode?
        var key: String?
    }
    func makeCoordinator() -> Coordinator { Coordinator() }

    struct Built {
        let scene: SCNScene
        let camera: SCNNode
        let focus: SIMD3<Float>
    }

    /// Path, ring and anchor, plus a camera on the side the user started from.
    /// The point cloud is attached separately (`cloud(_:originalColors:)`).
    static func build(_ model: CaptureReviewModel) -> Built {
        let scene = SCNScene()
        scene.background.contents = UIColor.black
        scene.rootNode.addChildNode(pathNode(model.path))
        let focus = model.focus
        if let target = model.target {
            let pin = AnchorPinNode(height: 0, ringRadius: target.ringRadius)
            pin.simdPosition = target.simdCenter
            scene.rootNode.addChildNode(pin)
        }
        let reach: Float = model.target.map { max(0.35, $0.ringRadius * 4) } ?? max(1.5, extent(model.path, around: focus) * 1.4)
        var side = (model.path.first ?? focus + SIMD3(0, 0, 1)) - focus
        side.y = 0
        side = simd_length(side) > 1e-3 ? simd_normalize(side) : SIMD3(0, 0, 1)
        let cameraNode = makeCamera()
        cameraNode.simdPosition = focus + side * reach * 0.8 + SIMD3(0, reach * 0.6, 0)
        cameraNode.simdLook(at: focus, up: SIMD3(0, 1, 0), localFront: SIMD3(0, 0, -1))
        scene.rootNode.addChildNode(cameraNode)
        return Built(scene: scene, camera: cameraNode, focus: focus)
    }

    static func makeCamera() -> SCNNode {
        let camera = SCNCamera()
        camera.zNear = 0.005
        camera.zFar = 100
        camera.fieldOfView = 55
        let node = SCNNode()
        node.camera = camera
        return node
    }

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView(frame: .zero)
        view.backgroundColor = .black
        view.antialiasingMode = .multisampling4X
        view.allowsCameraControl = true
        view.preferredFramesPerSecond = 60
        let built = Self.build(model)
        context.coordinator.scene = built.scene
        view.scene = built.scene
        view.pointOfView = built.camera
        view.defaultCameraController.interactionMode = .orbitTurntable
        view.defaultCameraController.target = SCNVector3(built.focus.x, built.focus.y, built.focus.z)
        view.defaultCameraController.inertiaEnabled = true
        update(context.coordinator)
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) { update(context.coordinator) }

    private func update(_ coordinator: Coordinator) {
        let key = "\(showAll)-\(originalColors)"
        guard key != coordinator.key, let scene = coordinator.scene else { return }
        coordinator.key = key
        coordinator.cloud?.removeFromParentNode()
        let node = Self.cloud(showAll ? model.all : model.near, originalColors: originalColors)
        scene.rootNode.addChildNode(node)
        coordinator.cloud = node
    }

    private static func extent(_ points: [SIMD3<Float>], around center: SIMD3<Float>) -> Float {
        points.map { simd_length($0 - center) }.max() ?? 1
    }

    static func cloud(_ set: CaptureReviewModel.PointSet, originalColors: Bool) -> SCNNode {
        let colors = originalColors
            ? set.colors
            : set.positions.indices.map { ReviewPalette.shaded(grade: set.quality[$0], rgb: set.colors[$0]) }
        return pointNode(set.positions, colors: colors, size: 4)
    }

    static func pointNode(_ positions: [SIMD3<Float>], colors: [SIMD3<Float>], size: CGFloat) -> SCNNode {
        guard !positions.isEmpty, colors.count == positions.count else { return SCNNode() }
        let stride = MemoryLayout<SIMD3<Float>>.stride
        let vertexData = positions.withUnsafeBufferPointer { Data(buffer: $0) }
        // SceneKit treats vertex colors as linear; convert from sRGB so they are not washed out.
        let linear = colors.map { SIMD3<Float>(powf($0.x, 2.2), powf($0.y, 2.2), powf($0.z, 2.2)) }
        let colorData = linear.withUnsafeBufferPointer { Data(buffer: $0) }
        let vertices = SCNGeometrySource(data: vertexData, semantic: .vertex, vectorCount: positions.count,
                                         usesFloatComponents: true, componentsPerVector: 3,
                                         bytesPerComponent: 4, dataOffset: 0, dataStride: stride)
        let colorSource = SCNGeometrySource(data: colorData, semantic: .color, vectorCount: colors.count,
                                            usesFloatComponents: true, componentsPerVector: 3,
                                            bytesPerComponent: 4, dataOffset: 0, dataStride: stride)
        let element = SCNGeometryElement(indices: (0..<UInt32(positions.count)).map { $0 }, primitiveType: .point)
        element.pointSize = size
        element.minimumPointScreenSpaceRadius = size * 0.375
        element.maximumPointScreenSpaceRadius = size * 1.25
        let geometry = SCNGeometry(sources: [vertices, colorSource], elements: [element])
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = UIColor.white
        geometry.materials = [material]
        return SCNNode(geometry: geometry)
    }

    static func pathNode(_ path: [SIMD3<Float>]) -> SCNNode {
        guard !path.isEmpty else { return SCNNode() }
        let source = SCNGeometrySource(vertices: path.map { SCNVector3($0.x, $0.y, $0.z) })
        let element = SCNGeometryElement(indices: (0..<UInt32(path.count)).map { $0 }, primitiveType: .point)
        element.pointSize = 4
        element.minimumPointScreenSpaceRadius = 1.5
        element.maximumPointScreenSpaceRadius = 3
        let geometry = SCNGeometry(sources: [source], elements: [element])
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = UIColor.white.withAlphaComponent(0.45)
        geometry.materials = [material]
        return SCNNode(geometry: geometry)
    }
}

// MARK: - Live panel while recording

/// "实时回看": the same red/green view, updated twice a second while recording and
/// slowly turning so the far side is visible too. Non-interactive.
struct LiveQualityPanel: View {
    let snapshot: LiveQualitySnapshot
    let target: ScanTargetBox?
    let coverage: ScanCoverage
    var nextPosition: SubjectStepGuidance? = nil
    var cameraTransform: simd_float4x4? = nil
    var followsCamera = false

    var body: some View {
        // Red/green saved observations, without a second progress counter.
        ZStack {
            LiveReviewSceneView(snapshot: snapshot, target: target, coverage: coverage, nextPosition: nextPosition, cameraTransform: cameraTransform, followsCamera: followsCamera)
            if snapshot.positions.isEmpty {
                ProgressView().controlSize(.small).tint(.white.opacity(0.7))
            }
        }
        .frame(width: 112, height: 112)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(.white.opacity(0.1)))
        .allowsHitTesting(false)
        .accessibilityElement()
        .accessibilityLabel("实时回看：数据充足 \(Int((snapshot.goodFraction * 100).rounded()))%")
    }
}

private struct LiveReviewSceneView: UIViewRepresentable {
    let snapshot: LiveQualitySnapshot
    let target: ScanTargetBox?
    let coverage: ScanCoverage
    var nextPosition: SubjectStepGuidance? = nil
    var cameraTransform: simd_float4x4? = nil
    var followsCamera = false

    final class Coordinator {
        let scene = SCNScene()
        let pivot = SCNNode()
        let camera = ReviewSceneView.makeCamera()
        var cloud: SCNNode?
        let nextMarker = RecommendedPositionNode()
        let phone = SCNNode()
        var version = -1
        var framedTarget: ScanTargetBox?
        var framedExtent: Float = 0
    }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView(frame: .zero)
        view.backgroundColor = .clear
        view.preferredFramesPerSecond = 30
        view.antialiasingMode = .multisampling2X
        view.isUserInteractionEnabled = false
        let c = context.coordinator
        c.scene.background.contents = UIColor.clear
        c.scene.rootNode.addChildNode(c.pivot)
        c.pivot.addChildNode(c.camera)
        c.nextMarker.isHidden = true
        c.scene.rootNode.addChildNode(c.nextMarker)
        let marker = SCNSphere(radius: 0.01)
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = UIColor.white
        marker.materials = [material]
        c.phone.geometry = marker
        c.phone.isHidden = true
        c.scene.rootNode.addChildNode(c.phone)
        view.scene = c.scene
        view.pointOfView = c.camera
        update(c)
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) { update(context.coordinator) }

    private func update(_ c: Coordinator) {
        // Frame the anchored object, or the captured cells when there is no anchor.
        let focus: SIMD3<Float>
        var reach: Float
        if let target {
            focus = target.simdCenter
            reach = max(0.3, target.ringRadius * 3.6)
        } else if !snapshot.positions.isEmpty {
            focus = snapshot.positions.reduce(.zero, +) / Float(snapshot.positions.count)
            reach = max(1.0, min(6, (snapshot.positions.map { simd_length($0 - focus) }.max() ?? 1) * 2.2))
        } else {
            focus = .zero; reach = 1
        }
        if let cameraTransform, let target {
            let position = SIMD3(cameraTransform.columns.3.x, cameraTransform.columns.3.y, cameraTransform.columns.3.z)
            reach = max(reach, simd_distance(position, target.simdCenter) * 1.7)
        }
        if let nextPosition { reach = max(reach, simd_distance(nextPosition.position, focus) * 1.7) }
        if c.framedTarget != target || abs(c.framedExtent - reach) > reach * 0.25 {
            c.framedTarget = target
            c.framedExtent = reach
            c.pivot.simdPosition = focus
            c.camera.simdPosition = SIMD3(0, reach * 0.55, reach * 0.85)
            c.camera.simdLook(at: focus, up: SIMD3(0, 1, 0), localFront: SIMD3(0, 0, -1))
        }
        // Follow the real camera heading instead of turning automatically: the missing
        // surfaces stay spatially understandable while the user walks.
        if let transform = cameraTransform {
            c.pivot.eulerAngles.y = atan2(transform.columns.2.x, transform.columns.2.z)
        }
        if followsCamera { c.pivot.simdPosition = focus }
        c.nextMarker.isHidden = nextPosition == nil || nextPosition?.motion == .hold
        if let nextPosition { c.nextMarker.simdPosition = nextPosition.position }
        if let camera = cameraTransform.map({ SIMD3($0.columns.3.x, $0.columns.3.y, $0.columns.3.z) }) ?? snapshot.camera {

            c.phone.isHidden = false
            c.phone.simdPosition = camera
            c.phone.scale = SCNVector3(repeating: reach * 2.5) // ≈ 2.5% of the framed size
        }
        guard snapshot.version != c.version else { return }
        c.version = snapshot.version
        c.cloud?.removeFromParentNode()
        let colors = snapshot.good.map { $0 ? ReviewPalette.good : ReviewPalette.weak }
        let node = ReviewSceneView.pointNode(snapshot.positions, colors: colors, size: 3)
        c.scene.rootNode.addChildNode(node)
        c.cloud = node
    }
}

private extension SCNVector3 {
    init(repeating value: Float) { self.init(value, value, value) }
}
