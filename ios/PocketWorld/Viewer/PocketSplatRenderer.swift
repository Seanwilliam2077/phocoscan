// Metal integration adapted from MetalSplatter's MIT-licensed SampleApp.
// Copyright (c) 2026 Sean Cier. See docs/THIRD-PARTY-NOTICES.md.
import Foundation
@preconcurrency import Metal
import MetalKit
import MetalSplatter
import os
import QuartzCore
import simd
import SplatIO
import UIKit

@MainActor
final class PocketSplatRenderer: NSObject, MTKViewDelegate {
    // Any camera change keeps rendering alive; a still view pauses itself (saves power).
    var yaw: Float = 0 { didSet { if yaw != oldValue { noteActivity() } } }
    var pitch: Float = 0 { didSet { if pitch != oldValue { noteActivity() } } }
    var distanceScale: Float = 1 { didSet { if distanceScale != oldValue { noteActivity() } } }
    var flipUp = false { didSet { if flipUp != oldValue { noteActivity() } } }
    var panOffset = SIMD2<Float>.zero { didSet { if panOffset != oldValue { noteActivity() } } }
    /// Free-orbit centre and base distance from the capture cameras (`OrbitLimits`); when nil the
    /// orbit frames the model's bounding sphere instead.
    var orbitTarget: SIMD3<Float>? { didSet { if orbitTarget != oldValue { noteActivity() } } }
    var orbitDistance: Float? { didSet { if orbitDistance != oldValue { noteActivity() } } }
    var anchoredOrbit: SplatCrop.Orbit? { didSet { if anchoredOrbit != oldValue { noteActivity() } } }
    var cameraSample: SceneCameraSample? {
        didSet { if cameraSample?.worldFromCamera != oldValue?.worldFromCamera { noteActivity() } }
    }
    var cameraFillsViewport = false { didSet { if cameraFillsViewport != oldValue { noteActivity() } } }
    var isActive = true { didSet { if isActive && !oldValue { noteActivity() } } }
    /// Receives one rendered frame per loaded model, used as the scan's cover image.
    var onPoster: ((CGImage) -> Void)?
    /// When set, `load` keeps only splats inside the anchored subject's region (see `SplatCrop`).
    var crop: SplatCrop?

    private weak var view: MTKView?
    private var framesSinceFirstPresent = 0
    private var posterCaptured = false
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let status: GaussianViewerStatus
    private let inFlight = DispatchSemaphore(value: 2)
    private var model: SplatRenderer?
    private var center = SIMD3<Float>.zero
    private var radius: Float = 1
    private var disposed = false
    private var isExporting = false
    private var loadID = UUID()
    private var loadStartedAt: CFTimeInterval = 0
    private(set) var budget: RenderBudget
    private var governor: ResolutionGovernor
    private let screenScale: CGFloat
    private var keepAliveUntil: CFTimeInterval = 0
    private var presentedFrameTimes: [CFTimeInterval] = []
    private var gpuSeconds = 0.0, gpuFrames = 0
    private var lastStatsPublish: CFTimeInterval = 0
    private var thermalObserver: NSObjectProtocol?
    nonisolated static let chunkSize = 65_536

    init(view: MTKView, status: GaussianViewerStatus, screenScale: CGFloat) throws {
        guard let device = view.device, let queue = device.makeCommandQueue() else {
            throw ViewerError.unsupportedDevice
        }
        self.view = view
        self.device = device
        self.commandQueue = queue
        self.status = status
        self.screenScale = screenScale
        let budget = RenderBudget.forDevice(physicalMemory: ProcessInfo.processInfo.physicalMemory,
                                            thermal: ProcessInfo.processInfo.thermalState,
                                            screenScale: screenScale)
        self.budget = budget
        self.governor = ResolutionGovernor(scale: budget.maxScale, minScale: budget.minScale, maxScale: budget.maxScale)
        super.init()
        view.contentScaleFactor = governor.scale
        view.preferredFramesPerSecond = budget.preferredFPS
        // UIViewRepresentable creates this renderer during a SwiftUI update. Publish
        // presentation statistics on the next actor turn, not inside makeUIView.
        Task { @MainActor [weak self] in
            guard let self, !self.disposed else { return }
            self.status.budgetSummary = self.budget.summary
            self.status.renderScale = self.governor.scale
            self.status.thermal = Self.thermalLabel(ProcessInfo.processInfo.thermalState)
        }
        thermalObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.thermalStateChanged() }
        }
    }

    /// Keeps the view drawing for a short while (sorting settles after camera moves).
    func noteActivity() {
        keepAliveUntil = CACurrentMediaTime() + 1.5
        if status.isIdle {
            Task { @MainActor [weak self] in
                guard let self, !self.disposed, self.isActive else { return }
                self.status.isIdle = false
            }
        }
        if isActive, status.error == nil, !disposed { view?.isPaused = false }
    }

    private var isFullyLoaded: Bool { status.totalPoints > 0 && status.loadedPoints >= status.totalPoints }

    private func thermalStateChanged() {
        guard !disposed else { return }
        let state = ProcessInfo.processInfo.thermalState
        let fresh = RenderBudget.forDevice(physicalMemory: ProcessInfo.processInfo.physicalMemory,
                                           thermal: state, screenScale: screenScale)
        // Resolution and frame rate react now; point/SH limits apply to the next load.
        budget.minScale = fresh.minScale
        budget.maxScale = fresh.maxScale
        budget.preferredFPS = fresh.preferredFPS
        budget.thermalReduced = fresh.thermalReduced
        governor.setRange(minScale: fresh.minScale, maxScale: fresh.maxScale)
        view?.contentScaleFactor = governor.scale
        view?.preferredFramesPerSecond = fresh.preferredFPS
        status.renderScale = governor.scale
        status.thermal = Self.thermalLabel(state)
        status.budgetSummary = budget.summary
    }

    private static func thermalLabel(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "正常"
        case .fair: return "偏热"
        case .serious: return "很热"
        case .critical: return "过热"
        @unknown default: return "未知"
        }
    }

    /// Per-frame GPU time feeds the resolution governor; stats publish at 2 Hz.
    private func recordFrame(gpuSeconds frameGPU: Double) {
        guard !disposed else { return }
        let now = CACurrentMediaTime()
        presentedFrameTimes.append(now)
        presentedFrameTimes.removeAll { now - $0 > 1 }
        if frameGPU.isFinite, frameGPU > 0 { gpuSeconds += frameGPU; gpuFrames += 1 }
        let frameBudget = 1 / Double(max(1, view?.preferredFramesPerSecond ?? 30))
        if let scale = governor.record(gpuSeconds: frameGPU, frameBudget: frameBudget) {
            view?.contentScaleFactor = scale
        }
        guard now - lastStatsPublish >= 0.5 else { return }
        lastStatsPublish = now
        status.fps = Double(presentedFrameTimes.count)
        status.gpuMs = gpuFrames > 0 ? gpuSeconds / Double(gpuFrames) * 1000 : 0
        gpuSeconds = 0; gpuFrames = 0
        status.renderScale = governor.scale
        status.availableMemoryMB = Int(os_proc_available_memory() / 1_048_576)
    }

    func load(url: URL) async {
        let requestID = UUID()
        loadID = requestID
        loadStartedAt = CACurrentMediaTime()
        status.isLoading = true
        status.error = nil
        status.pointCount = nil
        status.hasPresentedFrame = false
        status.sourceURL = url
        status.firstFrameSeconds = nil
        status.fullLoadSeconds = nil
        status.totalPoints = 0
        status.loadedPoints = 0
        status.prunedFrom = nil
        status.shDegree = nil
        status.sourceSHDegree = nil
        status.budgetSummary = budget.summary
        framesSinceFirstPresent = 0
        posterCaptured = false
        if onPoster != nil { view?.framebufferOnly = false } // allows copying one frame
        let previousModel = model
        model = nil
        if let previousModel { await previousModel.removeAllChunks() }
        noteActivity()
        do {
            #if arch(x86_64)
            throw ViewerError.unsupportedDevice
            #else
            guard !disposed, requestID == loadID, let view else { return }
            let renderer = try SplatRenderer(device: device,
                colorFormat: view.colorPixelFormat, depthFormat: view.depthStencilPixelFormat,
                sampleCount: 1, maxViewCount: 1, maxSimultaneousRenders: 2,
                highQualityDepth: false,
                clearColor: MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1))
            var minimum = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
            var maximum = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
            // Chunks arrive progressively (64K splats each); the first one is shown immediately.
            for try await piece in Self.chunkStream(url: url, budget: budget, device: device, crop: crop) {
                try Task.checkCancellation()
                guard !disposed, requestID == loadID else { return }
                switch piece {
                case let .plan(total, prunedFrom):
                    status.totalPoints = total
                    status.prunedFrom = prunedFrom
                case let .chunk(box):
                    await renderer.addChunk(box.chunk)
                    try Task.checkCancellation()
                    guard !disposed, requestID == loadID else { return }
                    minimum = simd_min(minimum, box.minimum)
                    maximum = simd_max(maximum, box.maximum)
                    center = minimum / 2 + maximum / 2
                    radius = max(simd_length(maximum - minimum) / 2, 0.05)
                    status.loadedPoints += box.count
                    status.shDegree = box.shDegree
                    status.sourceSHDegree = box.sourceSHDegree
                    if model == nil { model = renderer }
                    noteActivity()
                }
            }
            guard status.loadedPoints > 0 || crop == nil else { throw ViewerError.cropEmpty }
            guard status.loadedPoints > 0, radius.isFinite, radius < 1_000_000 else { throw ViewerError.invalidData }
            status.totalPoints = status.loadedPoints
            status.pointCount = status.loadedPoints
            status.fullLoadSeconds = CACurrentMediaTime() - loadStartedAt
            noteActivity()
            // Keep the loading state until Metal reports a drawable was actually presented.
            #endif
        } catch is CancellationError {
            // Dismissal/new requests intentionally discard this result.
        } catch {
            guard !disposed, requestID == loadID else { return }
            status.isLoading = false
            status.error = error.localizedDescription
        }
    }

    /// Frees GPU memory (e.g. while the app is in the background); `load` restores it.
    func unload() {
        loadID = UUID()
        let oldModel = model
        model = nil
        status.loadedPoints = 0
        if let oldModel { Task { await oldModel.removeAllChunks() } }
    }

    func invalidate() {
        disposed = true
        if let thermalObserver { NotificationCenter.default.removeObserver(thermalObserver) }
        thermalObserver = nil
        loadID = UUID()
        let oldModel = model
        model = nil
        view = nil
        if let oldModel { Task { await oldModel.removeAllChunks() } }
    }

    func draw(in view: MTKView) {
        guard !disposed, !isExporting, let model, model.isReadyToRender,
              view.drawableSize.width > 0, view.drawableSize.height > 0 else { return }
        // Never block the UI waiting indefinitely for a GPU frame.
        guard inFlight.wait(timeout: .now()) == .success else { return }
        guard let drawable = view.currentDrawable, let buffer = commandQueue.makeCommandBuffer() else {
            inFlight.signal()
            return
        }
        let semaphore = inFlight
        let frameLoadID = loadID
        buffer.addCompletedHandler { [weak self] completed in
            semaphore.signal()
            let gpu = completed.gpuEndTime - completed.gpuStartTime
            if completed.error == nil {
                Task { @MainActor in self?.recordFrame(gpuSeconds: gpu) }
            }
            if let failure = completed.error {
                let message = failure.localizedDescription
                Task { @MainActor in
                    guard let self, !self.disposed, self.loadID == frameLoadID else { return }
                    self.status.isLoading = false
                    self.status.error = "GPU 未能完成渲染：\(message)"
                    self.view?.isPaused = true
                }
            }
        }
        do {
            let rendered = try model.render(viewports: [viewport(size: view.drawableSize)],
                colorTexture: drawable.texture, colorStoreAction: .store,
                depthTexture: view.depthStencilTexture, rasterizationRateMap: nil,
                renderTargetArrayLength: 0, accessTimeout: 0, sortTimeout: 0, to: buffer)
            if rendered {
                if !status.hasPresentedFrame {
                    let markFirstFrame: @Sendable () -> Void = { [weak self] in
                        Task { @MainActor in
                            guard let self, !self.disposed, self.loadID == frameLoadID,
                                  self.status.error == nil, !self.status.hasPresentedFrame else { return }
                            self.status.isLoading = false
                            self.status.firstFrameSeconds = max(0, CACurrentMediaTime() - self.loadStartedAt)
                            self.status.hasPresentedFrame = true
                        }
                    }
                    #if targetEnvironment(simulator)
                    // The simulator SDK has no MTLDrawable.addPresentedHandler; use GPU completion.
                    buffer.addCompletedHandler { completed in
                        if completed.error == nil { markFirstFrame() }
                    }
                    #else
                    drawable.addPresentedHandler { presented in
                        guard presented.presentedTime > 0 else { return }
                        markFirstFrame()
                    }
                    #endif
                } else if !posterCaptured, onPoster != nil, isFullyLoaded {
                    // Let sorting settle for a few frames, then copy one finished frame.
                    framesSinceFirstPresent += 1
                    if framesSinceFirstPresent >= 20 { capturePoster(from: drawable.texture, in: buffer) }
                }
                buffer.present(drawable)
            }
        } catch {
            status.isLoading = false
            status.error = "模型渲染失败：\(error.localizedDescription)"
            view.isPaused = true
        }
        buffer.commit()
        // Nothing is changing: stop redrawing until the next camera change or load.
        if status.hasPresentedFrame, isFullyLoaded, posterCaptured || onPoster == nil,
           CACurrentMediaTime() > keepAliveUntil {
            view.isPaused = true
            if !status.isIdle { status.isIdle = true }
        }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { noteActivity() }

    private func capturePoster(from source: MTLTexture, in buffer: MTLCommandBuffer) {
        posterCaptured = true
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: source.pixelFormat,
            width: source.width, height: source.height, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = []
        guard let copy = device.makeTexture(descriptor: descriptor),
              let blit = buffer.makeBlitCommandEncoder() else { return }
        blit.copy(from: source, to: copy)
        blit.endEncoding()
        let callback = onPoster
        let frameLoadID = loadID
        buffer.addCompletedHandler { [weak self] completed in
            guard completed.error == nil, let image = Self.makeImage(copy) else { return }
            Task { @MainActor in
                guard let self, !self.disposed, self.loadID == frameLoadID else { return }
                callback?(image)
                self.view?.framebufferOnly = true // cover taken; restore the faster default
                self.noteActivity()
            }
        }
    }

    /// BGRA8 (sRGB) shared texture → CGImage.
    nonisolated private static func makeImage(_ texture: MTLTexture) -> CGImage? {
        let width = texture.width, height = texture.height, rowBytes = width * 4
        var bytes = Data(count: rowBytes * height)
        bytes.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            texture.getBytes(base, bytesPerRow: rowBytes,
                             from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }
        guard let provider = CGDataProvider(data: bytes as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: rowBytes, space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue
                                                | CGImageAlphaInfo.noneSkipFirst.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// The interactive free-orbit camera.
    var orbitPose: OrbitPose {
        OrbitPose(yaw: yaw, pitch: pitch, distanceScale: distanceScale, panOffset: panOffset, flipUp: flipUp)
    }

    private func viewport(size: CGSize) -> SplatRenderer.ViewportDescriptor {
        if let cameraSample { return calibratedViewport(size: size, camera: cameraSample) }
        return orbitViewport(size: size, pose: orbitPose)
    }

    private func orbitViewport(size: CGSize, pose: OrbitPose) -> SplatRenderer.ViewportDescriptor {
        let aspect = Float(size.width / max(size.height, 1))
        let fov: Float = .pi / 3
        // Orbit the capture-derived target when known; otherwise fit the bounding sphere to the
        // narrower viewing angle for portrait and landscape.
        let halfAngle = min(fov / 2, atan(tan(fov / 2) * aspect))
        let baseDistance = anchoredOrbit?.distance(aspect: aspect) ?? orbitDistance ?? radius / sin(halfAngle) * 1.1
        let orbitCenter = anchoredOrbit?.target ?? orbitTarget ?? center
        let panScale = anchoredOrbit?.radius ?? orbitDistance.map { $0 * 0.5 } ?? radius
        let distance = max(0.01, baseDistance * pose.distanceScale)
        let near = max(0.0001, min(radius * 0.001, distance * 0.01))
        let far = max(near + 1, distance + radius * 10)
        let translation = Self.translation(SIMD3(pose.panOffset.x * panScale,
                                                   pose.panOffset.y * panScale, -distance))
        let rotationX = simd_float4x4(simd_quatf(angle: pose.pitch, axis: SIMD3(1, 0, 0)))
        let rotationY = simd_float4x4(simd_quatf(angle: pose.yaw, axis: SIMD3(0, 1, 0)))
        let up = simd_float4x4(simd_quatf(angle: pose.flipUp ? .pi : 0, axis: SIMD3(0, 0, 1)))
        var alignment = matrix_identity_float4x4
        if let anchoredOrbit { for i in 0..<3 { alignment[i] = SIMD4(anchoredOrbit.modelToUpright[i], 0) } }
        let matrix = translation * rotationX * rotationY * up * alignment * Self.translation(-orbitCenter)
        return SplatRenderer.ViewportDescriptor(
            viewport: MTLViewport(originX: 0, originY: 0, width: size.width,
                                  height: size.height, znear: 0, zfar: 1),
            projectionMatrix: Self.perspective(fov: fov, aspect: aspect, near: near, far: far),
            viewMatrix: matrix, screenSize: SIMD2(Int(size.width), Int(size.height)))
    }

    // MARK: - Offscreen clip (Live Photo export)

    /// Renders `poses` offscreen at `width`×`height` and hands each finished frame (BGRA, sRGB) to
    /// `deliver` in order. Depth sorting is asynchronous, so every frame first triggers and waits for
    /// a sort at its own pose; the on-screen view pauses meanwhile and resumes afterwards.
    func renderClip(poses: [OrbitPose], width: Int, height: Int,
                    progress: (Double) -> Void,
                    deliver: (MTLTexture, Int) async throws -> Void) async throws {
        guard !disposed, !isExporting, let model, isFullyLoaded, status.error == nil,
              let view, width > 0, height > 0 else { throw ViewerError.notReadyForExport }
        isExporting = true
        view.isPaused = true
        defer {
            isExporting = false
            noteActivity()
        }
        let colorDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: view.colorPixelFormat,
            width: width, height: height, mipmapped: false)
        colorDescriptor.usage = [.renderTarget, .shaderRead]
        colorDescriptor.storageMode = .shared
        let depthDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: view.depthStencilPixelFormat,
            width: width, height: height, mipmapped: false)
        depthDescriptor.usage = .renderTarget
        depthDescriptor.storageMode = .private
        guard let color = device.makeTexture(descriptor: colorDescriptor),
              let depth = device.makeTexture(descriptor: depthDescriptor) else { throw ViewerError.exportRenderFailed }
        let size = CGSize(width: width, height: height)

        for (index, pose) in poses.enumerated() {
            try Task.checkCancellation()
            guard !disposed, self.model === model else { throw CancellationError() }
            let descriptor = orbitViewport(size: size, pose: pose)
            // Two rounds: the first may complete a sort that started at the previous pose.
            for _ in 0..<2 {
                _ = await Self.waitForNextSort(of: model, timeout: 2) {
                    _ = try? self.encodeOffscreen(model, descriptor, color: color, depth: depth, completion: nil)
                }
            }
            let finished = AsyncStream<Bool>.makeStream()
            let rendered = try encodeOffscreen(model, descriptor, color: color, depth: depth) { ok in
                finished.continuation.yield(ok)
                finished.continuation.finish()
            }
            guard rendered else { throw ViewerError.exportRenderFailed }
            var completedOK = false
            for await ok in finished.stream { completedOK = ok }
            guard completedOK else { throw ViewerError.exportRenderFailed }
            try await deliver(color, index)
            progress(Double(index + 1) / Double(max(1, poses.count)))
        }
    }

    private func encodeOffscreen(_ model: SplatRenderer, _ viewport: SplatRenderer.ViewportDescriptor,
                                 color: MTLTexture, depth: MTLTexture,
                                 completion: (@Sendable (Bool) -> Void)?) throws -> Bool {
        guard let buffer = commandQueue.makeCommandBuffer() else { throw ViewerError.exportRenderFailed }
        let rendered = try model.render(viewports: [viewport], colorTexture: color, colorStoreAction: .store,
            depthTexture: depth, rasterizationRateMap: nil, renderTargetArrayLength: 0,
            accessTimeout: 1, sortTimeout: 1, to: buffer)
        if let completion {
            buffer.addCompletedHandler { completed in completion(rendered && completed.error == nil) }
        }
        buffer.commit()
        return rendered
    }

    /// Runs `trigger` (which updates the sort pose) and waits until the next depth sort completes.
    private static func waitForNextSort(of model: SplatRenderer, timeout: TimeInterval,
                                        trigger: () -> Void) async -> Bool {
        let signal = AsyncStream<Void>.makeStream()
        model.afterNextSort { signal.continuation.yield(()) }
        trigger()
        let sorted = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await _ in signal.stream { return true }
                return false
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        signal.continuation.finish()
        return sorted
    }

    private func calibratedViewport(size: CGSize, camera: SceneCameraSample) -> SplatRenderer.ViewportDescriptor {
        // The model remains in its original frame, including SH3 direction coefficients.
        // Only the camera is transformed. Preserve the camera's image aspect by letterboxing.
        let imageAspect = Double(camera.width / camera.height)
        let width = cameraFillsViewport ? Double(size.width) : min(Double(size.width), Double(size.height) * imageAspect)
        let height = cameraFillsViewport ? Double(size.height) : width / imageAspect
        let scale = max(Float(width) / camera.width, Float(height) / camera.height)
        let fx = camera.fx * scale, fy = camera.fy * scale
        let cx = Float(width) / 2 + (camera.cx - camera.width / 2) * scale
        let cy = Float(height) / 2 + (camera.cy - camera.height / 2) * scale
        let originX = (Double(size.width) - width) / 2
        let originY = (Double(size.height) - height) / 2
        let position = SIMD3(camera.worldFromCamera.columns.3.x,
                             camera.worldFromCamera.columns.3.y,
                             camera.worldFromCamera.columns.3.z)
        let near = max(0.00001, min(radius * 0.001, 0.01))
        let far = max(near + 1, simd_length(position - center) + radius * 4)
        let z = far / (near - far)
        let projection = simd_float4x4(columns: (
            SIMD4(2 * fx / Float(width), 0, 0, 0),
            SIMD4(0, 2 * fy / Float(height), 0, 0),
            SIMD4(1 - 2 * cx / Float(width), 2 * cy / Float(height) - 1, z, -1),
            SIMD4(0, 0, z * near, 0)))
        return SplatRenderer.ViewportDescriptor(
            viewport: MTLViewport(originX: originX, originY: originY,
                                  width: width, height: height, znear: 0, zfar: 1),
            projectionMatrix: projection, viewMatrix: camera.worldFromCamera.inverse,
            screenSize: SIMD2(max(1, Int(width.rounded())), max(1, Int(height.rounded()))))
    }

    private static func translation(_ p: SIMD3<Float>) -> simd_float4x4 {
        var result = matrix_identity_float4x4
        result.columns.3 = SIMD4(p, 1)
        return result
    }

    private static func perspective(fov: Float, aspect: Float, near: Float, far: Float) -> simd_float4x4 {
        let y = 1 / tan(fov / 2)
        let z = far / (near - far)
        return simd_float4x4(columns: (SIMD4(y / aspect, 0, 0, 0), SIMD4(0, y, 0, 0),
                                      SIMD4(0, 0, z, -1), SIMD4(0, 0, z * near, 0)))
    }

    /// A GPU-ready chunk plus its bounds; MetalBuffer-backed, handed over once.
    private struct ChunkBox: @unchecked Sendable {
        let chunk: SplatChunk
        let count: Int
        let minimum: SIMD3<Float>
        let maximum: SIMD3<Float>
        let shDegree: Int
        let sourceSHDegree: Int
    }

    private enum LoadPiece: @unchecked Sendable {
        case plan(total: Int, prunedFrom: Int?)
        case chunk(ChunkBox)
    }

    /// Validates the file, then yields 64K-splat GPU chunks. Within budget: streamed as
    /// read (first chunk appears early, CPU memory stays at one chunk). Over budget:
    /// read once, keep the most important splats, then chunk.
    nonisolated private static func chunkStream(url: URL, budget: RenderBudget, device: MTLDevice,
                                                crop: SplatCrop?) -> AsyncThrowingStream<LoadPiece, Error> {
        AsyncThrowingStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                do {
                    let declared = try declaredPointCount(url: url)
                    let shLimit = budget.maxSHDegree
                    let reader = try AutodetectSceneReader(url)
                    if declared <= budget.maxPoints {
                        continuation.yield(.plan(total: declared, prunedFrom: nil))
                        var pending: [SplatPoint] = []
                        pending.reserveCapacity(chunkSize)
                        var sourceSH = 0, total = 0
                        for try await batch in try await reader.read() {
                            try Task.checkCancellation()
                            for point in batch {
                                try validate(point)
                                total += 1
                                guard total <= 1_000_000 else { throw ViewerError.tooManyPoints }
                                if total == 1 { sourceSH = Int(point.color.shDegree.rawValue) }
                                if let crop, !crop.keeps(position: point.position, opacity: point.opacity.asLinearFloat) { continue }
                                pending.append(point.limitingSH(to: shLimit))
                                if pending.count == chunkSize {
                                    continuation.yield(.chunk(try makeChunk(pending, device: device, sourceSH: sourceSH)))
                                    pending.removeAll(keepingCapacity: true)
                                }
                            }
                        }
                        if !pending.isEmpty {
                            continuation.yield(.chunk(try makeChunk(pending, device: device, sourceSH: sourceSH)))
                        }
                    } else {
                        var points: [SplatPoint] = []
                        points.reserveCapacity(declared)
                        for try await batch in try await reader.read() {
                            try Task.checkCancellation()
                            for point in batch { try validate(point) }
                            if let crop {
                                points.append(contentsOf: batch.filter {
                                    crop.keeps(position: $0.position, opacity: $0.opacity.asLinearFloat)
                                })
                            } else {
                                points.append(contentsOf: batch)
                            }
                            guard points.count <= 1_000_000 else { throw ViewerError.tooManyPoints }
                        }
                        guard !points.isEmpty else { throw crop == nil ? ViewerError.invalidData : ViewerError.cropEmpty }
                        let sourceSH = Int(points[0].color.shDegree.rawValue)
                        let scores = points.map {
                            SplatPruning.importance(opacity: $0.opacity.asLinearFloat, scale: $0.scale.asLinearFloat)
                        }
                        let kept = SplatPruning.topIndices(scores, count: budget.maxPoints)
                        continuation.yield(.plan(total: kept.count, prunedFrom: points.count))
                        var start = 0
                        while start < kept.count {
                            try Task.checkCancellation()
                            let end = min(kept.count, start + chunkSize)
                            let slice = kept[start..<end].map { points[$0].limitingSH(to: shLimit) }
                            continuation.yield(.chunk(try makeChunk(slice, device: device, sourceSH: sourceSH)))
                            start = end
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    nonisolated private static func makeChunk(_ points: [SplatPoint], device: MTLDevice,
                                              sourceSH: Int) throws -> ChunkBox {
        var minimum = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var maximum = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        for point in points {
            minimum = simd_min(minimum, point.position)
            maximum = simd_max(maximum, point.position)
        }
        let chunk = try SplatChunk(device: device, from: points)
        return ChunkBox(chunk: chunk, count: points.count, minimum: minimum, maximum: maximum,
                        shDegree: Int(points.first?.color.shDegree.rawValue ?? 0), sourceSHDegree: sourceSH)
    }

    nonisolated private static func validate(_ point: SplatPoint) throws {
        let p = point.position
        let scale = point.scale.asLinearFloat
        guard p.x.isFinite, p.y.isFinite, p.z.isFinite,
              scale.x.isFinite, scale.y.isFinite, scale.z.isFinite,
              scale.x > 0, scale.y > 0, scale.z > 0 else {
            throw ViewerError.invalidData
        }
    }

    /// File type, size and declared splat count, checked before any decoding.
    nonisolated private static func declaredPointCount(url: URL) throws -> Int {
        guard url.isFileURL, ["ply", "splat", "spz"].contains(url.pathExtension.lowercased()) else {
            throw ViewerError.fileType
        }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, size <= 150 * 1024 * 1024 else { throw ViewerError.fileSize }
        let limit = 1_000_000
        if url.pathExtension.lowercased() == "spz" {
            return try SPZFilePreflight.inspect(url, maxPoints: limit).pointCount
        }
        if url.pathExtension.lowercased() == "splat" {
            guard size % 32 == 0 else { throw ViewerError.invalidData }
            guard size / 32 <= limit else { throw ViewerError.tooManyPoints }
            return size / 32
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let prefix = try handle.read(upToCount: 65_536) ?? Data()
        guard let headerEnd = prefix.range(of: Data("end_header".utf8)),
              let header = String(data: prefix[..<headerEnd.lowerBound], encoding: .ascii) else {
            throw ViewerError.invalidData
        }
        let lines = header.components(separatedBy: .newlines)
        guard let line = lines.first(where: { $0.hasPrefix("element vertex ") }),
              let count = Int(line.split(whereSeparator: \.isWhitespace).last ?? ""), count > 0 else {
            throw ViewerError.invalidData
        }
        guard count <= limit else { throw ViewerError.tooManyPoints }
        return count
    }

    private enum ViewerError: LocalizedError {
        case unsupportedDevice, fileType, fileSize, tooManyPoints, invalidData, notReadyForExport, exportRenderFailed, cropEmpty
        var errorDescription: String? {
            switch self {
            case .cropEmpty: return SplatCrop.emptyMessage
            case .notReadyForExport: return "模型还没有完整加载，请稍后再保存。"
            case .exportRenderFailed: return "GPU 未能渲染导出画面，请稍后重试。"
            case .unsupportedDevice: return "此设备无法运行原生 Metal 查看器，请使用支持 iOS 18 的真实 iPhone。"
            case .fileType: return "无法识别此 3DGS 文件格式，支持 Gaussian PLY、SPLAT 和 SPZ。"
            case .fileSize: return "模型为空或超过 150 MB。请在外部工具中裁剪或降低模型大小。"
            case .tooManyPoints: return "模型超过 100 万高斯点。请先简化模型，原始文件仍保留在服务器。"
            case .invalidData: return "文件不包含可读取的高斯模型，或部分数值无效。请重新导出。"
            }
        }
    }
}

/// One free-orbit camera: angles in radians, distance relative to the orbit's base distance.
struct OrbitPose: Equatable, Sendable {
    var yaw: Float
    var pitch: Float
    var distanceScale: Float
    var panOffset: SIMD2<Float>
    var flipUp: Bool
}
