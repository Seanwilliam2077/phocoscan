import Foundation
import Metal
import simd

/// One training camera: OpenCV world→camera rotation rows and translation, pinhole intrinsics at
/// the training resolution, and which target image it sees.
struct TrainingCamera: Sendable {
    var r0: SIMD3<Float>, r1: SIMD3<Float>, r2: SIMD3<Float>
    var t: SIMD3<Float>
    var fx: Float, fy: Float, cx: Float, cy: Float
    var imageIndex: Int

    /// From an ARKit / OpenGL camera-to-world pose (camera looks down −Z, +Y up).
    init(cameraToWorld m: simd_float4x4, fx: Float, fy: Float, cx: Float, cy: Float, imageIndex: Int) {
        let rotation = simd_float3x3(SIMD3(m.columns.0.x, m.columns.0.y, m.columns.0.z),
                                     SIMD3(m.columns.1.x, m.columns.1.y, m.columns.1.z),
                                     SIMD3(m.columns.2.x, m.columns.2.y, m.columns.2.z))
        let center = SIMD3(m.columns.3.x, m.columns.3.y, m.columns.3.z)
        // world→OpenGL camera = Rᵀ; OpenCV flips the camera's y and z axes.
        let rt = rotation.transpose
        let flip = simd_float3x3(diagonal: SIMD3(1, -1, -1))
        let w = flip * rt
        r0 = SIMD3(w[0][0], w[1][0], w[2][0])
        r1 = SIMD3(w[0][1], w[1][1], w[2][1])
        r2 = SIMD3(w[0][2], w[1][2], w[2][2])
        t = -(w * center)
        self.fx = fx; self.fy = fy; self.cx = cx; self.cy = cy
        self.imageIndex = imageIndex
    }

    var center: SIMD3<Float> {
        let w = simd_float3x3(rows: [r0, r1, r2])
        return -(w.transpose * t)
    }
}

/// Initial Gaussian: position, isotropic size, colour (0…1).
struct GaussianSeed: Sendable {
    var position: SIMD3<Float>
    var size: Float
    var color: SIMD3<Float>
}

struct TrainingStats: Sendable {
    var iteration: Int
    var meanAbsError: Float?
    var pairs: Int
    var relocated: Int
}

enum GaussianTrainerError: LocalizedError {
    case metalUnavailable, pipeline(String), tooManyPairs, invalidInput, memoryBudget
    var errorDescription: String? {
        switch self {
        case .metalUnavailable: return "这台设备的 GPU 不支持本机训练。"
        case .pipeline(let name): return "训练程序 \(name) 无法加载。"
        case .tooManyPairs: return "画面里的高斯点太多，超出了本机训练的内存上限。"
        case .invalidInput: return "训练数据不完整。"
        case .memoryBudget: return "当前可用内存不足，请关闭其他应用后重试。已有结果会保留。"
        }
    }
}

/// Differentiable Gaussian-splat training on Metal: projection, tile binning (GPU radix sort),
/// alpha-blended rasterisation, its backward pass and Adam, with MCMC-style relocation of dead
/// Gaussians and optional budgeted gradient refinement. Platform-neutral (no UIKit) so the same code runs in tests on a Mac GPU.
final class GaussianTrainer {
    /// Diagnostic timing only; never changes optimisation/checkpoint state.
    var recordsTiming = false
    var cachesTargetStatistics = true
    private(set) var timing: [String: Double] = [:]
    private var targetFractions: [Int: Float] = [:]
    private func timed(_ name: String, since start: TimeInterval?) {
        if let start { timing[name, default: 0] += Date.timeIntervalSinceReferenceDate - start }
    }
    struct Refinement: Sendable, Codable, Equatable {
        var capacity: Int
        var every = 100
        var start = 300
        var stopFraction = 0.7
        var gradientThreshold: Float = 0.0008
        var fraction: Float = 0.10
        var splitLarge: Bool? = nil
    }
    struct Config: Sendable, Codable, Equatable {
        var iterations = 3000
        var lrMeanInit: Float = 1.6e-4
        var lrMeanFinal: Float = 1.6e-6
        var lrScale: Float = 0.005
        var lrQuat: Float = 0.001
        var lrColor: Float = 0.0025
        var lrOpacity: Float = 0.05
        var opacityReg: Float = 0.01
        var scaleReg: Float = 0.01
        var relocateEvery = 100
        var relocateFrom = 300
        var relocateUntilFraction = 0.8
        var noiseLR: Float = 5e5
        var maxRadius: Float = 256
        /// Alpha below which a splat is skipped, and its footprint in sigmas (3DGS: 1/255, 3).
        /// The gradient tests turn both off, since cut-offs are not differentiable.
        var minAlpha: Float = 1.0 / 255.0
        var radiusSigmas: Float = 3
        var structuralWeight: Float = 0.2
        /// Limits include all trainer-owned Metal buffers, not the app/OS working set.
        var memoryBudgetBytes = 512 * 1024 * 1024
        var pairLimit = 8_000_000
        // Optional additions: v1 checkpoints decode with nil and retain exactly the old algorithm.
        var refinement: Refinement? = nil
        var subjectWeighting: Bool? = nil
        var randomSeed: UInt64? = nil
        /// Bound needle-like scales (largest / middle); planar splats may stay thin.
        /// Optional for exact compatibility with existing paused jobs.
        var lineAspectLimit: Float? = nil
    }

    static let tile = 16
    static let radixBlock = 4096
    static let grad2DStride = 12
    static let maxPairs = 48_000_000

    let device: MTLDevice
    private(set) var width: Int, height: Int
    let fullWidth: Int, fullHeight: Int
    private(set) var count: Int
    let capacity: Int
    let config: Config
    let sceneExtent: Float
    private(set) var cameras: [TrainingCamera]
    private let queue: MTLCommandQueue
    private var pipelines: [String: MTLComputePipelineState] = [:]
    private var tilesX: Int, tilesY: Int
    private let targetData: Data
    private let targetSource, targets: MTLBuffer
    private var loadedTarget = -1
    private var foregroundFraction: Float = 1
    private var cameraBag: [Int] = []
    private var trainingViews: [Int] = []
    private(set) var lastCameraIndex: Int?

    // Parameters and optimiser state (shared: the CPU relocates and exports).
    let means, logScales, quats, colorOp: MTLBuffer
    private let momentM, momentV, densityStats: MTLBuffer
    private let dMean, dScale, dQuat, dColorOp, grad2D: MTLBuffer
    // Per-iteration scratch.
    private let projXY, conicOp, rgb, tilesTouched, offsets: MTLBuffer
    private let ranges, outColor, outCount, dLdColor, absError: MTLBuffer
    private let structuralMean, structuralSquare, structuralCross, objective: MTLBuffer
    private var keyDepth: [MTLBuffer] = [], keyTile: [MTLBuffer] = [], values: [MTLBuffer] = []
    private var pairCapacity = 0
    private var histogram: MTLBuffer?
    private var histogramScanned: MTLBuffer?
    private var scanScratch: [Int: [MTLBuffer]] = [:]
    private(set) var step = 0
    var control: TrainingRunControl?
    private(set) var canCheckpoint = true
    private var random = TrainingRandom(state: UInt64.random(in: 1...UInt64.max))

    struct State: Codable {
        let count: Int, width: Int, height: Int, step: Int, divisor: Int
        let extent: Float
        let config: Config
        let trainingViews: [Int], cameraBag: [Int]
        let random: TrainingRandom
    }

    var checkpointState: State {
        State(count: count, width: fullWidth, height: fullHeight, step: step,
              divisor: fullWidth / width, extent: sceneExtent, config: config,
              trainingViews: trainingViews, cameraBag: cameraBag, random: random)
    }
    // CPU-visible buffers; call only on the worker after its GPU command has completed.
    var checkpointBuffers: [MTLBuffer] {
        [means, logScales, quats, colorOp, momentM, momentV] + (config.refinement == nil ? [] : [densityStats])
    }

    func restore(_ state: State, buffers: [Data]) throws {
        guard (config.refinement == nil ? state.count == count : (count...capacity).contains(state.count)), state.width == fullWidth, state.height == fullHeight,
              state.extent == sceneExtent, state.config == config, (0...config.iterations).contains(state.step),
              [1, 2, 4].contains(state.divisor), buffers.count == checkpointBuffers.count,
              Set(state.trainingViews).count == state.trainingViews.count,
              state.trainingViews.allSatisfy({ cameras.indices.contains($0) }),
              Set(state.cameraBag).count == state.cameraBag.count,
              state.cameraBag.allSatisfy({ (state.trainingViews.isEmpty ? Array(cameras.indices) : state.trainingViews).contains($0) })
        else { throw GaussianTrainerError.invalidInput }
        for (data, buffer) in zip(buffers, checkpointBuffers) {
            guard data.count == buffer.length else { throw GaussianTrainerError.invalidInput }
            let finite = data.withUnsafeBytes { bytes in bytes.bindMemory(to: Float.self).allSatisfy(\.isFinite) }
            guard finite else { throw GaussianTrainerError.invalidInput }
        }
        for (data, buffer) in zip(buffers, checkpointBuffers) {
            data.withUnsafeBytes { buffer.contents().copyMemory(from: $0.baseAddress!, byteCount: data.count) }
        }
        count = state.count
        step = state.step; random = state.random; cameraBag = state.cameraBag; trainingViews = state.trainingViews
        setResolution(divisor: state.divisor)
    }

    private func commit(_ command: MTLCommandBuffer) throws {
        if let control { try control.commit(command) } else { command.commit() }
    }

    /// `targets`: RGBA8 images of `width × height`, one after another, indexed by `imageIndex`.
    init(device: MTLDevice, library: MTLLibrary, seeds: [GaussianSeed], cameras: [TrainingCamera],
         targets: Data, width: Int, height: Int, config: Config = Config()) throws {
        guard !seeds.isEmpty, !cameras.isEmpty, width > 0, height > 0,
              width <= 4096, height <= 4096, config.iterations > 0, config.relocateEvery > 0,
              config.structuralWeight.isFinite, (0...1).contains(config.structuralWeight),
              config.pairLimit > 0, config.memoryBudgetBytes > 0,
              cameras.allSatisfy({ $0.imageIndex >= 0 && $0.imageIndex < targets.count / (width * height * 4) }),
              seeds.allSatisfy({ $0.size.isFinite && $0.size > 0 &&
                  $0.position.x.isFinite && $0.position.y.isFinite && $0.position.z.isFinite }) else {
            throw GaussianTrainerError.invalidInput
        }
        if let r = config.refinement {
            guard r.capacity >= seeds.count, r.capacity <= 250_000, r.every > 0, r.start > 0,
                  r.stopFraction > 0, r.stopFraction < 1, r.gradientThreshold.isFinite, r.gradientThreshold >= 0,
                  r.fraction > 0, r.fraction <= 0.25 else { throw GaussianTrainerError.invalidInput }
        }
        if let limit = config.lineAspectLimit {
            guard limit.isFinite, (2...100).contains(limit) else { throw GaussianTrainerError.invalidInput }
        }
        guard let queue = device.makeCommandQueue() else { throw GaussianTrainerError.metalUnavailable }
        self.device = device; self.queue = queue
        self.width = width; self.height = height
        fullWidth = width; fullHeight = height
        targetData = targets // Data shares storage; never duplicate the entire image stack on GPU.
        capacity = config.refinement?.capacity ?? seeds.count
        if let seed = config.randomSeed { random = TrainingRandom(state: seed) }
        self.count = seeds.count; self.config = config; self.cameras = cameras
        tilesX = (width + Self.tile - 1) / Self.tile
        tilesY = (height + Self.tile - 1) / Self.tile
        for name in ["preprocessForward", "emitKeys", "scanBlocks", "addBlockOffsets", "radixHistogram", "radixScatter",
                     "tileRanges", "rasterizeForward", "rasterizeSubjectEvidence", "l1LossGradient", "rasterizeBackward", "preprocessBackward", "adam",
                     "trainingTarget", "structuralStatistics", "structuralGradient", "accumulateDensity"] {
            guard let function = library.makeFunction(name: name) else { throw GaussianTrainerError.pipeline(name) }
            do { pipelines[name] = try device.makeComputePipelineState(function: function) }
            catch { throw GaussianTrainerError.pipeline(name) }
        }
        let centers = cameras.map(\.center)
        let mid = centers.reduce(.zero, +) / Float(centers.count)
        sceneExtent = max(0.1, (centers.map { simd_length($0 - mid) }.max() ?? 1) * 1.1)

        var allocated = 0
        func buffer(_ length: Int) throws -> MTLBuffer {
            allocated += max(16, length)
            guard allocated <= config.memoryBudgetBytes else { throw GaussianTrainerError.memoryBudget }
            guard let b = device.makeBuffer(length: max(16, length), options: .storageModeShared) else {
                throw GaussianTrainerError.metalUnavailable
            }
            return b
        }
        let n = capacity, f4 = MemoryLayout<SIMD4<Float>>.stride
        means = try buffer(n * f4); logScales = try buffer(n * f4); quats = try buffer(n * f4); colorOp = try buffer(n * f4)
        momentM = try buffer(4 * n * f4); momentV = try buffer(4 * n * f4)
        dMean = try buffer(n * f4); dScale = try buffer(n * f4); dQuat = try buffer(n * f4); dColorOp = try buffer(n * f4)
        grad2D = try buffer(n * Self.grad2DStride * 4)
        densityStats = try buffer(config.refinement == nil ? 16 : n * f4)
        projXY = try buffer(n * f4); conicOp = try buffer(n * f4); rgb = try buffer(n * f4)
        tilesTouched = try buffer(n * 4); offsets = try buffer(n * 4)
        ranges = try buffer(tilesX * tilesY * 8)
        let pixels = width * height
        outColor = try buffer(pixels * f4); outCount = try buffer(pixels * 4)
        dLdColor = try buffer(pixels * f4); absError = try buffer(pixels * 4)
        structuralMean = try buffer(pixels * f4); structuralSquare = try buffer(pixels * f4)
        structuralCross = try buffer(pixels * f4); objective = try buffer(pixels * 4)
        targetSource = try buffer(pixels * 4); self.targets = try buffer(pixels * 4)

        let m = means.contents().bindMemory(to: SIMD4<Float>.self, capacity: n)
        let s = logScales.contents().bindMemory(to: SIMD4<Float>.self, capacity: n)
        let q = quats.contents().bindMemory(to: SIMD4<Float>.self, capacity: n)
        let c = colorOp.contents().bindMemory(to: SIMD4<Float>.self, capacity: n)
        for b in [means, logScales, quats, colorOp, densityStats] { memset(b.contents(), 0, b.length) }
        let initialOpacity: Float = 0.3
        for (i, seed) in seeds.enumerated() {
            m[i] = SIMD4(seed.position, 0)
            s[i] = SIMD4(repeating: log(max(1e-4, seed.size))); s[i].w = 0
            q[i] = SIMD4(1, 0, 0, 0)
            let f = (simd_clamp(seed.color, .zero, SIMD3(repeating: 1)) - 0.5) / 0.28209479
            c[i] = SIMD4(f, log(initialOpacity / (1 - initialOpacity)))
        }
        memset(momentM.contents(), 0, momentM.length)
        memset(momentV.contents(), 0, momentV.length)
        try ensurePairCapacity(1)
    }

    // MARK: Public API

    func setTrainingViews(_ indices: [Int]) throws {
        guard !indices.isEmpty, Set(indices).count == indices.count,
              indices.allSatisfy({ cameras.indices.contains($0) }) else { throw GaussianTrainerError.invalidInput }
        trainingViews = indices; cameraBag.removeAll()
    }

    /// Switch resolution without losing parameters or Adam state. Allocation stays bounded by
    /// the final resolution; camera intrinsics and target reduction use the same pixel centres.
    func setResolution(divisor: Int) {
        precondition(divisor == 1 || divisor == 2 || divisor == 4)
        width = max(1, fullWidth / divisor); height = max(1, fullHeight / divisor)
        tilesX = (width + Self.tile - 1) / Self.tile; tilesY = (height + Self.tile - 1) / Self.tile
    }

    var workingSetBytes: Int {
        let fixed = [means, logScales, quats, colorOp, momentM, momentV, dMean, dScale, dQuat, dColorOp,
                     grad2D, densityStats, projXY, conicOp, rgb, tilesTouched, offsets, ranges, outColor, outCount,
                     dLdColor, absError, structuralMean, structuralSquare, structuralCross, objective, targetSource, targets]
        return (fixed + keyDepth + keyTile + values + scanScratch.values.flatMap { $0 }).reduce(0) { $0 + $1.length }
            + (histogram?.length ?? 0) + (histogramScanned?.length ?? 0)
    }
    var targetBufferBytes: Int { targetSource.length + targets.length }
    var sortingCapacity: Int { pairCapacity }

    func scaledCamera(_ c: TrainingCamera) -> TrainingCamera {
        var scaled = c
        let sx = Float(width) / Float(fullWidth), sy = Float(height) / Float(fullHeight)
        scaled.fx *= sx; scaled.fy *= sy
        scaled.cx = (c.cx + 0.5) * sx - 0.5; scaled.cy = (c.cy + 0.5) * sy - 0.5
        return scaled
    }

    /// Direct pixel-loss check used for finite differences (does not update any parameters).
    func pixelLoss(rendered: [SIMD4<Float>], cameraIndex: Int) throws -> (value: Float, gradient: [SIMD4<Float>]) {
        guard rendered.count == width * height, cameras.indices.contains(cameraIndex),
              let command = queue.makeCommandBuffer() else { throw GaussianTrainerError.invalidInput }
        rendered.withUnsafeBytes { outColor.contents().copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
        try encodeLoss(command, cameras[cameraIndex]); try commit(command); command.waitUntilCompleted()
        if let error = command.error { throw error }
        let n = width * height
        let errors = (config.structuralWeight > 0 ? objective : absError).contents().bindMemory(to: Float.self, capacity: n)
        var total: Double = 0
        for i in 0..<n { total += Double(errors[i]) }
        let gradient = Array(UnsafeBufferPointer(start: dLdColor.contents().bindMemory(to: SIMD4<Float>.self, capacity: n), count: n))
        return (Float(total / Double(n)), gradient)
    }

    /// One optimisation step on camera `cameraIndex` (random when nil).
    @discardableResult
    func trainStep(cameraIndex: Int? = nil, measure: Bool = false) throws -> TrainingStats {
        let tick = recordsTiming ? Date.timeIntervalSinceReferenceDate : nil
        defer { timed("total", since: tick) }
        let savedBag = cameraBag, savedRandom = random
        var completed = false
        defer { if !completed { cameraBag = savedBag; random = savedRandom } }
        // Shuffle without replacement: every view gets an update each epoch.
        if cameraIndex == nil && cameraBag.isEmpty {
            cameraBag = (trainingViews.isEmpty ? Array(cameras.indices) : trainingViews).shuffled(using: &random)
        }
        let selected = cameraIndex ?? cameraBag.removeLast()
        guard cameras.indices.contains(selected) else { throw GaussianTrainerError.invalidInput }
        let camera = cameras[selected]
        lastCameraIndex = selected
        let pairs = try forwardPasses(camera, optimize: true)
        var relocated = 0
        let cpuTick = recordsTiming ? Date.timeIntervalSinceReferenceDate : nil
        if step % config.relocateEvery == 0, step >= config.relocateFrom,
           Double(step) < Double(config.iterations) * config.relocateUntilFraction {
            relocated = relocateDeadGaussians()
        }
        if let r = config.refinement, step >= r.start, step % r.every == 0,
           Double(step) < Double(config.iterations) * r.stopFraction {
            refineGaussians(r)
        }
        timed("refineCPU", since: cpuTick)
        var meanError: Float?
        if measure {
            let e = absError.contents().bindMemory(to: Float.self, capacity: width * height)
            var total: Float = 0
            for i in 0..<(width * height) { total += e[i] }
            meanError = total / Float(width * height)
        }
        completed = true
        return TrainingStats(iteration: step, meanAbsError: meanError, pairs: pairs, relocated: relocated)
    }

    /// Renders camera `index` with the current parameters (RGB + final transmittance per pixel).
    func render(cameraIndex: Int) throws -> [SIMD4<Float>] {
        _ = try forwardPasses(cameras[cameraIndex])
        let p = outColor.contents().bindMemory(to: SIMD4<Float>.self, capacity: width * height)
        return Array(UnsafeBufferPointer(start: p, count: width * height))
    }

    /// Read-only export evidence at full resolution. The subject selector supplies only
    /// training views. Evidence is transient and never added to checkpoint buffers.
    func subjectEvidence(cameraIndices: [Int]) throws -> [SIMD2<Float>] {
        try subjectBoundaryEvidence(cameraIndices:cameraIndices).map { SIMD2($0.foreground,$0.background) }
    }

    struct SubjectBoundaryEvidence {
        let foreground, background: Float
        let foregroundMoment, backgroundMoment: SIMD3<Float>
        var removalCost: Float = 0
    }

    func subjectBoundaryEvidence(cameraIndices: [Int]) throws -> [SubjectBoundaryEvidence] {
        let allowed=Set(cameras.indices)
        guard !cameraIndices.isEmpty,Set(cameraIndices).count==cameraIndices.count,
              cameraIndices.allSatisfy({ allowed.contains($0) }),
              let pipeline=pipelines["rasterizeSubjectEvidence"],
              let evidence=device.makeBuffer(length:count*48,options:.storageModeShared) else { throw GaussianTrainerError.invalidInput }
        let original=(width,height,tilesX,tilesY)
        setResolution(divisor:1)
        defer { (width,height,tilesX,tilesY)=original; loadedTarget = -1 }
        evidence.contents().initializeMemory(as:UInt8.self,repeating:0,count:evidence.length)
        for index in cameraIndices {
            let camera=cameras[index]
            _ = try forwardPasses(camera)
            let bytes=fullWidth*fullHeight*4
            targetData.withUnsafeBytes { raw in
                targetSource.contents().copyMemory(from:raw.baseAddress!.advanced(by:camera.imageIndex*bytes),byteCount:bytes)
            }
            guard let command=queue.makeCommandBuffer(),let encoder=command.makeComputeCommandEncoder() else { throw GaussianTrainerError.metalUnavailable }
            encoder.setComputePipelineState(pipeline)
            for (i,b) in [ranges,values[0],projXY,conicOp].enumerated() { encoder.setBuffer(b,offset:0,index:i) }
            var cam=cameraParams(camera)
            encoder.setBytes(&cam,length:MemoryLayout<CameraUniform>.stride,index:4)
            for (i,b) in [outColor,outCount,targetSource,evidence,means,logScales,quats,rgb].enumerated() { encoder.setBuffer(b,offset:0,index:i+5) }
            encoder.dispatchThreadgroups(MTLSize(width:tilesX,height:tilesY,depth:1),threadsPerThreadgroup:MTLSize(width:Self.tile,height:Self.tile,depth:1))
            encoder.endEncoding();try commit(command);command.waitUntilCompleted()
            if let error=command.error { throw error }
        }
        let values=evidence.contents().bindMemory(to:Float.self,capacity:count*12)
        return (0..<count).map { i in
            let b=i*12
            return SubjectBoundaryEvidence(foreground:values[b],background:values[b+1],
                foregroundMoment:SIMD3(values[b+2],values[b+3],values[b+4]),
                backgroundMoment:SIMD3(values[b+5],values[b+6],values[b+7]),removalCost:values[b+8])
        }
    }

    /// Parameter gradients for an arbitrary per-pixel colour gradient (tests: gradient checks).
    func gradients(cameraIndex: Int, dLdPixel: [SIMD4<Float>], opacityReg: Float = 0, scaleReg: Float = 0)
        throws -> (mean: [SIMD4<Float>], scale: [SIMD4<Float>], quat: [SIMD4<Float>], colorOp: [SIMD4<Float>]) {
        let camera = cameras[cameraIndex]
        _ = try forwardPasses(camera)
        precondition(dLdPixel.count == width * height)
        dLdPixel.withUnsafeBytes { dLdColor.contents().copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
        guard let command = queue.makeCommandBuffer() else { throw GaussianTrainerError.metalUnavailable }
        try encodeBackward(command, camera, regs: SIMD4(opacityReg, scaleReg, Float(count), 0))
        try commit(command)
        command.waitUntilCompleted()
        func read(_ b: MTLBuffer) -> [SIMD4<Float>] {
            Array(UnsafeBufferPointer(start: b.contents().bindMemory(to: SIMD4<Float>.self, capacity: count), count: count))
        }
        return (read(dMean), read(dScale), read(dQuat), read(dColorOp))
    }

    /// Sorted (tile, depth, gaussian) pairs and tile ranges of the last forward pass (tests).
    func debugPairs(count pairs: Int) -> (tiles: [UInt32], depths: [UInt32], values: [UInt32], ranges: [SIMD2<UInt32>]) {
        func copy(_ source: MTLBuffer, _ n: Int) -> [UInt32] {
            guard n > 0, let staging = device.makeBuffer(length: n * 4, options: .storageModeShared),
                  let command = queue.makeCommandBuffer(), let blit = command.makeBlitCommandEncoder() else { return [] }
            blit.copy(from: source, sourceOffset: 0, to: staging, destinationOffset: 0, size: n * 4)
            blit.endEncoding(); do { try commit(command) } catch { return [] }; command.waitUntilCompleted()
            return Array(UnsafeBufferPointer(start: staging.contents().bindMemory(to: UInt32.self, capacity: n), count: n))
        }
        let r = ranges.contents().bindMemory(to: SIMD2<UInt32>.self, capacity: tilesX * tilesY)
        return (copy(keyTile[0], pairs), copy(keyDepth[0], pairs), copy(values[0], pairs),
                Array(UnsafeBufferPointer(start: r, count: tilesX * tilesY)))
    }

    /// Number of tile pairs of the last forward pass.
    private(set) var lastPairs = 0

    // MARK: Parameter access

    func parameters() -> (means: [SIMD4<Float>], logScales: [SIMD4<Float>], quats: [SIMD4<Float>], colorOp: [SIMD4<Float>]) {
        func read(_ b: MTLBuffer) -> [SIMD4<Float>] {
            Array(UnsafeBufferPointer(start: b.contents().bindMemory(to: SIMD4<Float>.self, capacity: count), count: count))
        }
        return (read(means), read(logScales), read(quats), read(colorOp))
    }

    func setParameter(_ buffer: MTLBuffer, index: Int, value: SIMD4<Float>) {
        buffer.contents().bindMemory(to: SIMD4<Float>.self, capacity: count)[index] = value
    }

    func value(_ buffer: MTLBuffer, index: Int) -> SIMD4<Float> {
        buffer.contents().bindMemory(to: SIMD4<Float>.self, capacity: count)[index]
    }

    // MARK: Passes

    private func cameraParams(_ c: TrainingCamera) -> CameraUniform {
        let c = scaledCamera(c)
        let tanX = Float(width) / (2 * c.fx), tanY = Float(height) / (2 * c.fy)
        return CameraUniform(r0: SIMD4(c.r0, 0), r1: SIMD4(c.r1, 0), r2: SIMD4(c.r2, 0), t: SIMD4(c.t, 0),
                             intr: SIMD4(c.fx, c.fy, c.cx, c.cy),
                             dims: SIMD4(UInt32(width), UInt32(height), UInt32(tilesX), UInt32(tilesY)),
                             lim: SIMD4(1.3 * tanX, 1.3 * tanY, 0.02, config.maxRadius),
                             opts: SIMD4(config.minAlpha, config.radiusSigmas, config.refinement == nil ? 0 : 1, 0))
    }

    /// Projection, binning, sorting and forward rasterisation. Returns the number of tile pairs.
    private func forwardPasses(_ camera: TrainingCamera, optimize: Bool = false) throws -> Int {
        let tick = recordsTiming ? Date.timeIntervalSinceReferenceDate : nil
        defer { timed("forwardBackward", since: tick) }
        var cam = cameraParams(camera)
        var n = UInt32(count)
        guard let first = queue.makeCommandBuffer(), let encoder = first.makeComputeCommandEncoder() else {
            throw GaussianTrainerError.metalUnavailable
        }
        encoder.setComputePipelineState(pipelines["preprocessForward"]!)
        for (i, b) in [means, logScales, quats, colorOp].enumerated() { encoder.setBuffer(b, offset: 0, index: i) }
        encoder.setBytes(&cam, length: MemoryLayout<CameraUniform>.stride, index: 4)
        for (i, b) in [projXY, conicOp, rgb, tilesTouched].enumerated() { encoder.setBuffer(b, offset: 0, index: 5 + i) }
        encoder.setBytes(&n, length: 4, index: 9)
        dispatch(encoder, "preprocessForward", count)
        try encodeScan(encoder, input: tilesTouched, output: offsets, n: count)
        encoder.endEncoding()
        try commit(first)
        first.waitUntilCompleted()
        if let error = first.error { throw error }
        let lastOffset = offsets.contents().bindMemory(to: UInt32.self, capacity: count)[count - 1]
        let lastTiles = tilesTouched.contents().bindMemory(to: UInt32.self, capacity: count)[count - 1]
        let pairs = Int(lastOffset) + Int(lastTiles)
        guard pairs <= min(Self.maxPairs, config.pairLimit) else { throw GaussianTrainerError.tooManyPairs }
        try ensurePairCapacity(pairs)
        lastPairs = pairs

        guard let second = queue.makeCommandBuffer() else { throw GaussianTrainerError.metalUnavailable }
        guard let clear = second.makeBlitCommandEncoder() else { throw GaussianTrainerError.metalUnavailable }
        clear.fill(buffer: ranges, range: 0..<ranges.length, value: 0)
        clear.endEncoding()
        guard let enc = second.makeComputeCommandEncoder() else { throw GaussianTrainerError.metalUnavailable }
        if pairs > 0 {
            enc.setComputePipelineState(pipelines["emitKeys"]!)
            enc.setBuffer(projXY, offset: 0, index: 0)
            enc.setBuffer(offsets, offset: 0, index: 1)
            enc.setBytes(&cam, length: MemoryLayout<CameraUniform>.stride, index: 2)
            enc.setBuffer(keyDepth[0], offset: 0, index: 3)
            enc.setBuffer(keyTile[0], offset: 0, index: 4)
            enc.setBuffer(values[0], offset: 0, index: 5)
            enc.setBytes(&n, length: 4, index: 6)
            dispatch(enc, "emitKeys", count)
            try encodeSort(enc, pairs: pairs)
            var m = UInt32(pairs)
            enc.setComputePipelineState(pipelines["tileRanges"]!)
            enc.setBuffer(keyTile[0], offset: 0, index: 0)
            enc.setBuffer(ranges, offset: 0, index: 1)
            enc.setBytes(&m, length: 4, index: 2)
            dispatch(enc, "tileRanges", pairs)
        }
        enc.setComputePipelineState(pipelines["rasterizeForward"]!)
        enc.setBuffer(ranges, offset: 0, index: 0)
        enc.setBuffer(values[0], offset: 0, index: 1)
        enc.setBuffer(projXY, offset: 0, index: 2)
        enc.setBuffer(conicOp, offset: 0, index: 3)
        enc.setBuffer(rgb, offset: 0, index: 4)
        enc.setBytes(&cam, length: MemoryLayout<CameraUniform>.stride, index: 5)
        enc.setBuffer(outColor, offset: 0, index: 6)
        enc.setBuffer(outCount, offset: 0, index: 7)
        enc.dispatchThreadgroups(MTLSize(width: tilesX, height: tilesY, depth: 1),
                                 threadsPerThreadgroup: MTLSize(width: Self.tile, height: Self.tile, depth: 1))
        enc.endEncoding()
        let priorStep = step
        var completed = false
        defer { if !completed { step = priorStep } }
        if optimize {
            // Rasterisation, loss, backward and Adam stay in one command buffer. Only the pair
            // count requires a CPU readback; don't insert a third CPU/GPU fence every iteration.
            try encodeLoss(second, camera)
            try encodeBackward(second, camera)
            if config.refinement != nil {
                guard let density = second.makeComputeCommandEncoder() else { throw GaussianTrainerError.metalUnavailable }
                density.setComputePipelineState(pipelines["accumulateDensity"]!)
                density.setBuffer(grad2D, offset: 0, index: 0)
                density.setBuffer(tilesTouched, offset: 0, index: 1)
                density.setBuffer(densityStats, offset: 0, index: 2)
                var info = SIMD4(UInt32(count), UInt32(width), UInt32(height), 0)
                density.setBytes(&info, length: 16, index: 3)
                dispatch(density, "accumulateDensity", count); density.endEncoding()
            }
            step += 1
            try encodeAdam(second)
        }
        try commit(second)
        second.waitUntilCompleted()
        if let error = second.error { if optimize { canCheckpoint = false }; throw error }
        completed = true
        return pairs
    }

    private func encodeLoss(_ command: MTLCommandBuffer, _ camera: TrainingCamera) throws {
        let tick = recordsTiming ? Date.timeIntervalSinceReferenceDate : nil
        defer { timed("lossEncodingCPU", since: tick) }
        guard let enc = command.makeComputeCommandEncoder() else { throw GaussianTrainerError.metalUnavailable }
        if loadedTarget != camera.imageIndex {
            let bytes = fullWidth * fullHeight * 4
            targetData.withUnsafeBytes { raw in
                targetSource.contents().copyMemory(from: raw.baseAddress!.advanced(by: camera.imageIndex * bytes), byteCount: bytes)
            }
            if config.subjectWeighting == true {
                if cachesTargetStatistics, let cached = targetFractions[camera.imageIndex] {
                    foregroundFraction = cached
                } else {
                let pixels = fullWidth * fullHeight
                let bytes = targetSource.contents().bindMemory(to: UInt8.self, capacity: pixels * 4)
                var sum: Double = 0
                for i in 0..<pixels { sum += Double(bytes[i * 4 + 3]) / 255 }
                foregroundFraction = Float(sum / Double(pixels))
                if cachesTargetStatistics { targetFractions[camera.imageIndex] = foregroundFraction }
                }
            }
            loadedTarget = camera.imageIndex
        }
        var sizes = SIMD4(UInt32(fullWidth), UInt32(fullHeight), UInt32(width), UInt32(height))
        enc.setComputePipelineState(pipelines["trainingTarget"]!)
        enc.setBuffer(targetSource, offset: 0, index: 0); enc.setBuffer(targets, offset: 0, index: 1)
        enc.setBytes(&sizes, length: 16, index: 2)
        dispatch(enc, "trainingTarget", width * height)
        // Normalised 85% subject / 15% context loss mass, independent of object image area.
        // Empty/full masks use ordinary loss, avoiding infinities and an unintended black target.
        let weighted = config.subjectWeighting == true && foregroundFraction > 0.001 && foregroundFraction < 0.999
        var loss = SIMD4(config.structuralWeight, weighted ? 0.85 / foregroundFraction : 1,
                         weighted ? 0.15 / (1 - foregroundFraction) : 1, 0)
        if config.structuralWeight > 0 {
            var size = SIMD2(UInt32(width), UInt32(height))
            enc.setComputePipelineState(pipelines["structuralStatistics"]!)
            for (i, b) in [outColor, targets, structuralMean, structuralSquare, structuralCross, objective].enumerated() {
                enc.setBuffer(b, offset: 0, index: i)
            }
            enc.setBytes(&size, length: 8, index: 6); enc.setBytes(&loss, length: 16, index: 7)
            dispatch(enc, "structuralStatistics", width * height)
            enc.setComputePipelineState(pipelines["structuralGradient"]!)
            for (i, b) in [outColor, targets, structuralMean, structuralSquare, structuralCross, dLdColor, absError].enumerated() {
                enc.setBuffer(b, offset: 0, index: i)
            }
            enc.setBytes(&size, length: 8, index: 7); enc.setBytes(&loss, length: 16, index: 8)
            dispatch(enc, "structuralGradient", width * height)
            enc.endEncoding(); return
        }
        var pixels = UInt32(width * height)
        enc.setComputePipelineState(pipelines["l1LossGradient"]!)
        enc.setBuffer(outColor, offset: 0, index: 0)
        enc.setBuffer(targets, offset: 0, index: 1)
        enc.setBuffer(dLdColor, offset: 0, index: 2)
        enc.setBuffer(absError, offset: 0, index: 3)
        enc.setBytes(&pixels, length: 4, index: 4)
        enc.setBytes(&loss, length: 16, index: 5)
        dispatch(enc, "l1LossGradient", width * height)
        enc.endEncoding()
    }

    private func encodeBackward(_ command: MTLCommandBuffer, _ camera: TrainingCamera, regs: SIMD4<Float>? = nil) throws {
        var cam = cameraParams(camera)
        var n = UInt32(count)
        var reg = regs ?? SIMD4(config.opacityReg, config.scaleReg, Float(count), 0)
        guard let blit = command.makeBlitCommandEncoder() else { throw GaussianTrainerError.metalUnavailable }
        blit.fill(buffer: grad2D, range: 0..<grad2D.length, value: 0)
        blit.endEncoding()
        guard let enc = command.makeComputeCommandEncoder() else { throw GaussianTrainerError.metalUnavailable }
        enc.setComputePipelineState(pipelines["rasterizeBackward"]!)
        enc.setBuffer(ranges, offset: 0, index: 0)
        enc.setBuffer(values[0], offset: 0, index: 1)
        enc.setBuffer(projXY, offset: 0, index: 2)
        enc.setBuffer(conicOp, offset: 0, index: 3)
        enc.setBuffer(rgb, offset: 0, index: 4)
        enc.setBytes(&cam, length: MemoryLayout<CameraUniform>.stride, index: 5)
        enc.setBuffer(outColor, offset: 0, index: 6)
        enc.setBuffer(outCount, offset: 0, index: 7)
        enc.setBuffer(dLdColor, offset: 0, index: 8)
        enc.setBuffer(grad2D, offset: 0, index: 9)
        enc.dispatchThreadgroups(MTLSize(width: tilesX, height: tilesY, depth: 1),
                                 threadsPerThreadgroup: MTLSize(width: Self.tile, height: Self.tile, depth: 1))
        enc.setComputePipelineState(pipelines["preprocessBackward"]!)
        for (i, b) in [means, logScales, quats, colorOp].enumerated() { enc.setBuffer(b, offset: 0, index: i) }
        enc.setBytes(&cam, length: MemoryLayout<CameraUniform>.stride, index: 4)
        enc.setBuffer(projXY, offset: 0, index: 5)
        enc.setBuffer(grad2D, offset: 0, index: 6)
        for (i, b) in [dMean, dScale, dQuat, dColorOp].enumerated() { enc.setBuffer(b, offset: 0, index: 7 + i) }
        enc.setBytes(&n, length: 4, index: 11)
        enc.setBytes(&reg, length: 16, index: 12)
        dispatch(enc, "preprocessBackward", count)
        enc.endEncoding()
    }

    private func encodeAdam(_ command: MTLCommandBuffer) throws {
        guard let enc = command.makeComputeCommandEncoder() else { throw GaussianTrainerError.metalUnavailable }
        let progress = Float(min(step, config.iterations)) / Float(max(1, config.iterations))
        let lrMean = config.lrMeanInit * sceneExtent * pow(config.lrMeanFinal / config.lrMeanInit, progress)
        let beta1: Float = 0.9, beta2: Float = 0.999
        var params = AdamUniform(
            lrMean: SIMD4(repeating: lrMean), lrScale: SIMD4(repeating: config.lrScale),
            lrQuat: SIMD4(repeating: config.lrQuat),
            lrColorOp: SIMD4(config.lrColor, config.lrColor, config.lrColor, config.lrOpacity),
            beta1: beta1, beta2: beta2, epsilon: 1e-15, bc1: 1 - pow(beta1, Float(step)),
            bc2: 1 - pow(beta2, Float(step)), noiseScale: config.noiseLR * lrMean, step: Float(step),
            pad: config.lineAspectLimit.map { log($0) } ?? 0)
        var n = UInt32(count)
        enc.setComputePipelineState(pipelines["adam"]!)
        for (i, b) in [means, logScales, quats, colorOp, dMean, dScale, dQuat, dColorOp, momentM, momentV].enumerated() {
            enc.setBuffer(b, offset: 0, index: i)
        }
        enc.setBytes(&params, length: MemoryLayout<AdamUniform>.stride, index: 10)
        enc.setBytes(&n, length: 4, index: 11)
        dispatch(enc, "adam", count)
        enc.endEncoding()
    }

    // MARK: Scan and sort

    private func dispatch(_ encoder: MTLComputeCommandEncoder, _ name: String, _ threads: Int) {
        let pipeline = pipelines[name]!
        let width = min(256, pipeline.maxTotalThreadsPerThreadgroup)
        encoder.dispatchThreads(MTLSize(width: max(1, threads), height: 1, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: width, height: 1, depth: 1))
    }

    /// Exclusive prefix sum of `n` uints (recursive block sums; up to 1024³ elements).
    private func encodeScan(_ encoder: MTLComputeCommandEncoder, input: MTLBuffer, output: MTLBuffer, n: Int,
                            level: Int = 0) throws {
        let block = min(1024, pipelines["scanBlocks"]!.maxTotalThreadsPerThreadgroup)
        let blocks = (n + block - 1) / block
        var scratch = scanScratch[level] ?? []
        if scratch.count < 2 || scratch[0].length < blocks * 4 {
            guard let a = device.makeBuffer(length: max(16, blocks * 4), options: .storageModeShared),
                  let b = device.makeBuffer(length: max(16, blocks * 4), options: .storageModeShared) else {
                throw GaussianTrainerError.metalUnavailable
            }
            scratch = [a, b]
            scanScratch[level] = scratch
        }
        var count = UInt32(n)
        encoder.setComputePipelineState(pipelines["scanBlocks"]!)
        encoder.setBuffer(input, offset: 0, index: 0)
        encoder.setBuffer(output, offset: 0, index: 1)
        encoder.setBuffer(scratch[0], offset: 0, index: 2)
        encoder.setBytes(&count, length: 4, index: 3)
        encoder.dispatchThreadgroups(MTLSize(width: blocks, height: 1, depth: 1),
                                     threadsPerThreadgroup: MTLSize(width: block, height: 1, depth: 1))
        guard blocks > 1 else { return }
        try encodeScan(encoder, input: scratch[0], output: scratch[1], n: blocks, level: level + 1)
        encoder.setComputePipelineState(pipelines["addBlockOffsets"]!)
        encoder.setBuffer(output, offset: 0, index: 0)
        encoder.setBuffer(scratch[1], offset: 0, index: 1)
        encoder.setBytes(&count, length: 4, index: 2)
        encoder.dispatchThreadgroups(MTLSize(width: blocks, height: 1, depth: 1),
                                     threadsPerThreadgroup: MTLSize(width: block, height: 1, depth: 1))
    }

    /// Stable LSD radix sort of (tile, depth) pairs: four 8-bit passes on depth, then two on tile.
    private func encodeSort(_ encoder: MTLComputeCommandEncoder, pairs: Int) throws {
        let blocks = (pairs + Self.radixBlock - 1) / Self.radixBlock
        if (histogram?.length ?? 0) < blocks * 256 * 4 {
            histogram = device.makeBuffer(length: blocks * 256 * 4, options: .storageModePrivate)
            histogramScanned = device.makeBuffer(length: blocks * 256 * 4, options: .storageModePrivate)
        }
        guard let histogram, let scanned = histogramScanned else { throw GaussianTrainerError.metalUnavailable }
        var n = UInt32(pairs), b = UInt32(blocks)
        var source = 0
        for (shift, onTile) in [(0, false), (8, false), (16, false), (24, false), (0, true), (8, true)] {
            var s = UInt32(shift)
            let digits = onTile ? keyTile[source] : keyDepth[source]
            encoder.setComputePipelineState(pipelines["radixHistogram"]!)
            encoder.setBuffer(digits, offset: 0, index: 0)
            encoder.setBuffer(histogram, offset: 0, index: 1)
            encoder.setBytes(&n, length: 4, index: 2)
            encoder.setBytes(&s, length: 4, index: 3)
            encoder.setBytes(&b, length: 4, index: 4)
            encoder.dispatchThreadgroups(MTLSize(width: blocks, height: 1, depth: 1),
                                         threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
            try encodeScan(encoder, input: histogram, output: scanned, n: blocks * 256)
            let target = 1 - source
            encoder.setComputePipelineState(pipelines["radixScatter"]!)
            encoder.setBuffer(digits, offset: 0, index: 0)
            encoder.setBuffer(keyDepth[source], offset: 0, index: 1)
            encoder.setBuffer(keyTile[source], offset: 0, index: 2)
            encoder.setBuffer(values[source], offset: 0, index: 3)
            encoder.setBuffer(keyDepth[target], offset: 0, index: 4)
            encoder.setBuffer(keyTile[target], offset: 0, index: 5)
            encoder.setBuffer(values[target], offset: 0, index: 6)
            encoder.setBuffer(scanned, offset: 0, index: 7)
            encoder.setBytes(&n, length: 4, index: 8)
            encoder.setBytes(&s, length: 4, index: 9)
            encoder.setBytes(&b, length: 4, index: 10)
            encoder.dispatchThreadgroups(MTLSize(width: blocks, height: 1, depth: 1),
                                         threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
            source = target
        }
        precondition(source == 0, "an even number of passes leaves the result in the first buffers")
    }

    private func ensurePairCapacity(_ pairs: Int) throws {
        guard pairs > pairCapacity else { return }
        guard pairs <= min(Self.maxPairs, config.pairLimit) else { throw GaussianTrainerError.tooManyPairs }
        let capacity = min(config.pairLimit, max(pairs, pairCapacity * 3 / 2))
        // All six arrays plus radix histograms; never allow growth beyond this phone's budget.
        let needed = capacity * 24 + ((capacity + Self.radixBlock - 1) / Self.radixBlock) * 2048
        guard workingSetBytes - pairCapacity * 24 + needed <= config.memoryBudgetBytes else {
            throw GaussianTrainerError.memoryBudget
        }
        // The previous GPU command has completed. Release before allocating to avoid a 2x peak.
        keyDepth.removeAll(); keyTile.removeAll(); values.removeAll(); pairCapacity = 0
        func make() throws -> MTLBuffer {
            guard let b = device.makeBuffer(length: max(16, capacity * 4), options: .storageModePrivate) else {
                throw GaussianTrainerError.tooManyPairs
            }
            return b
        }
        keyDepth = [try make(), try make()]
        keyTile = [try make(), try make()]
        values = [try make(), try make()]
        pairCapacity = capacity
    }

    // MARK: Budgeted image-gradient refinement

    /// High absolute image-plane gradients select donors, not a scene-wide uniform growth rule.
    /// MCMC opacity/scale compensation plus a small symmetric principal-axis displacement
    /// breaks identical-clone symmetry. Existing, unrelated Adam slots are preserved exactly.
    private func refineGaussians(_ r: Refinement) {
        let stats = densityStats.contents().bindMemory(to: SIMD4<Float>.self, capacity: capacity)
        defer { memset(densityStats.contents(), 0, densityStats.length) }
        guard count < capacity, lastPairs < config.pairLimit * 2 / 3,
              workingSetBytes < config.memoryBudgetBytes * 3 / 4 else { return }
        let c = colorOp.contents().bindMemory(to: SIMD4<Float>.self, capacity: capacity)
        let candidates = (0..<count).filter {
            stats[$0].y >= 2 && stats[$0].x.isFinite && stats[$0].x / stats[$0].y >= r.gradientThreshold &&
            1 / (1 + exp(-c[$0].w)) > 0.02
        }.sorted {
            let a = stats[$0].x / stats[$0].y, b = stats[$1].x / stats[$1].y
            return a == b ? $0 < $1 : a > b
        }
        let donors = Array(candidates.prefix(min(capacity - count, max(1, Int(Float(count) * r.fraction)))))
        guard !donors.isEmpty else { return }
        let old = count, next = count + donors.count
        let m = means.contents().bindMemory(to: SIMD4<Float>.self, capacity: capacity)
        let s = logScales.contents().bindMemory(to: SIMD4<Float>.self, capacity: capacity)
        let q = quats.contents().bindMemory(to: SIMD4<Float>.self, capacity: capacity)
        let mm = momentM.contents().bindMemory(to: SIMD4<Float>.self, capacity: 4 * capacity)
        let vv = momentV.contents().bindMemory(to: SIMD4<Float>.self, capacity: 4 * capacity)
        // GPU layout uses active count; move groups backwards to handle overlapping regions.
        for k in stride(from: 3, through: 0, by: -1) {
            memmove(mm + k * next, mm + k * old, old * 16)
            memmove(vv + k * next, vv + k * old, old * 16)
            for j in old..<next { mm[k * next + j] = .zero; vv[k * next + j] = .zero }
        }
        for (j, source) in donors.enumerated() {
            let child = old + j
            let axis = (0..<3).max { s[source][$0] < s[source][$1] }!
            let raw = q[source], rotation = simd_quatf(ix: raw.y, iy: raw.z, iz: raw.w, r: raw.x).normalized
            var offset = SIMD3<Float>.zero; offset[axis] = exp(s[source][axis]) * 0.25
            offset = rotation.act(offset)
            let center = m[source]
            if r.splitLarge == true && exp(s[source][axis]) > max(0.001, sceneExtent * 0.01) {
                // Split large footprints; coincident cloning alone leaves long needles intact.
                // Keep donor opacity, shrink both children, and separate along the principal axis.
                offset *= 2
                s[source] -= SIMD4<Float>(log(1.6), log(1.6), log(1.6), 0)
            } else {
                let split = Self.relocation(opacity: 1 / (1 + exp(-c[source].w)), copies: 2)
                let shrink = log(split.scale)
                s[source] += SIMD4(shrink, shrink, shrink, 0)
                c[source].w = log(split.opacity / (1 - split.opacity))
            }
            m[source] = center - SIMD4(offset, 0); m[child] = center + SIMD4(offset, 0)
            s[child] = s[source]; q[child] = q[source]; c[child] = c[source]
            for k in 0..<4 { mm[k * next + source] = .zero; vv[k * next + source] = .zero }
        }
        count = next
    }

    // MARK: MCMC relocation

    /// Preserve centre alpha AND the integrated 1D opacity profile after N coincident copies.
    /// The Gaussian profile integral is evaluated in Double instead of an alternating binomial
    /// sum, which becomes unstable when one donor receives many dead points.
    static func relocation(opacity: Float, copies: Int) -> (opacity: Float, scale: Float) {
        guard copies > 1 else { return (opacity, 1) }
        let old = min(0.999999, max(1e-8, Double(opacity)))
        let alpha = -expm1(log1p(-old) / Double(copies))
        // Exact two-copy integral; avoid 129 numerical integration samples for every new pair.
        if copies == 2 {
            return (Float(alpha), Float(old / (2 * alpha - alpha * alpha / sqrt(2))))
        }
        let n = 128, h = 8.0 / 128
        var integral = 0.0
        for i in 0...n {
            let x = Double(i) * h
            let value = -expm1(Double(copies) * log1p(-alpha * exp(-0.5 * x * x)))
            integral += value * (i == 0 || i == n ? 1 : (i % 2 == 0 ? 2 : 4))
        }
        integral *= 2 * h / (3 * sqrt(2 * Double.pi))
        return (Float(alpha), Float(old / max(integral, 1e-12)))
    }

    /// Sample all donors first, then split each group consistently (including its scale).
    private func relocateDeadGaussians() -> Int {
        let c = colorOp.contents().bindMemory(to: SIMD4<Float>.self, capacity: count)
        var dead: [Int] = []
        var alive: [(index: Int, weight: Float)] = []
        var totalWeight: Float = 0
        for i in 0..<count {
            let opacity = 1 / (1 + exp(-c[i].w))
            if opacity < 0.005 { dead.append(i) } else { alive.append((i, opacity)); totalWeight += opacity }
        }
        guard !dead.isEmpty, !alive.isEmpty, totalWeight > 0 else { return 0 }
        var cumulative: [Float] = []
        cumulative.reserveCapacity(alive.count)
        var run: Float = 0
        for entry in alive { run += entry.weight; cumulative.append(run) }
        let m = means.contents().bindMemory(to: SIMD4<Float>.self, capacity: count)
        let s = logScales.contents().bindMemory(to: SIMD4<Float>.self, capacity: count)
        let q = quats.contents().bindMemory(to: SIMD4<Float>.self, capacity: count)
        let mm = momentM.contents().bindMemory(to: SIMD4<Float>.self, capacity: 4 * count)
        let vv = momentV.contents().bindMemory(to: SIMD4<Float>.self, capacity: 4 * count)
        func reset(_ i: Int) {
            for k in 0..<4 { mm[k * count + i] = .zero; vv[k * count + i] = .zero }
            if config.refinement != nil { densityStats.contents().bindMemory(to: SIMD4<Float>.self, capacity: capacity)[i] = .zero }
        }
        var groups: [Int: [Int]] = [:]
        for target in dead {
            let pick = Float.random(in: 0..<run, using: &random)
            var low = 0, high = cumulative.count - 1
            while low < high { let mid = (low + high) / 2; if cumulative[mid] < pick { low = mid + 1 } else { high = mid } }
            let source = alive[low].index
            groups[source, default: []].append(target)
        }
        for (source, targets) in groups {
            let opacity = 1 / (1 + exp(-c[source].w))
            let split = Self.relocation(opacity: opacity, copies: targets.count + 1)
            let logit = log(split.opacity / (1 - split.opacity))
            let shrink = log(split.scale)
            s[source] += SIMD4(shrink, shrink, shrink, 0)
            c[source].w = logit
            reset(source)
            for target in targets {
                m[target] = m[source]; s[target] = s[source]; q[target] = q[source]; c[target] = c[source]
                reset(target)
            }
        }
        return dead.count
    }
}

/// Mirrors `CameraParams` in GaussianTraining.metal.
struct CameraUniform {
    var r0, r1, r2, t, intr: SIMD4<Float>
    var dims: SIMD4<UInt32>
    var lim: SIMD4<Float>
    var opts: SIMD4<Float>
}

/// Mirrors `AdamParams` in GaussianTraining.metal.
struct AdamUniform {
    var lrMean, lrScale, lrQuat, lrColorOp: SIMD4<Float>
    var beta1, beta2, epsilon, bc1: Float
    var bc2, noiseScale, step, pad: Float
}

/// SplitMix64 state is persisted alongside Adam and the partially consumed camera epoch.
struct TrainingRandom: RandomNumberGenerator, Codable {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9e3779b97f4a7c15
        var z = state
        z = (z ^ (z >> 30)) &* 0xbf58476d1ce4e5b9
        z = (z ^ (z >> 27)) &* 0x94d049bb133111eb
        return z ^ (z >> 31)
    }
}

struct TrainingPaused: Error {}

/// Closing this gate prevents new GPU submissions synchronously at willResignActive.
/// CPU checkpoint writes may continue inside the app's finite background task.
final class TrainingRunControl: @unchecked Sendable {
    private let lock = NSLock()
    private var paused = false
    private var cancelled = false
    private var expired = false
    func expire() { lock.lock(); paused = true; expired = true; lock.unlock() }
    func pause() { lock.lock(); paused = true; lock.unlock() }
    func cancel() { lock.lock(); cancelled = true; paused = true; lock.unlock() }
    func check() throws {
        lock.lock(); defer { lock.unlock() }
        if cancelled { throw CancellationError() }
        if paused { throw TrainingPaused() }
    }
    func checkCancellation() throws {
        lock.lock(); defer { lock.unlock() }
        if cancelled { throw CancellationError() }
        if expired { throw TrainingPaused() }
    }
    func commit(_ command: MTLCommandBuffer) throws {
        lock.lock(); defer { lock.unlock() }
        if cancelled { throw CancellationError() }
        if paused { throw TrainingPaused() }
        command.commit()
        command.waitUntilScheduled()
    }
    func publish(_ action: () throws -> Void) throws {
        lock.lock(); defer { lock.unlock() }
        if cancelled { throw CancellationError() }
        if paused { throw TrainingPaused() }
        try action()
    }
}
