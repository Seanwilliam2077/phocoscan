import Foundation
import Metal
import simd

// Mac GPU checks for GaussianTrainer: CPU reference render, finite-difference gradients, convergence.
let device = MTLCreateSystemDefaultDevice()!
let library = try device.makeLibrary(URL: URL(fileURLWithPath: CommandLine.arguments[1]))
var rng = SystemRandomNumberGenerator()
struct Seeded: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 { state = state &* 6364136223846793005 &+ 1442695040888963407; return state }
}
var random = Seeded(state: 42)
func rnd(_ a: Float, _ b: Float) -> Float { Float.random(in: a..<b, using: &random) }

func lookAt(_ eye: SIMD3<Float>, _ target: SIMD3<Float>) -> simd_float4x4 {
    let back = simd_normalize(eye - target)
    let right = simd_normalize(simd_cross(SIMD3(0, 1, 0), back))
    let up = simd_cross(back, right)
    return simd_float4x4(columns: (SIMD4(right, 0), SIMD4(up, 0), SIMD4(back, 0), SIMD4(eye, 1)))
}

// MARK: CPU reference forward (same rules as the shader)
func cpuRender(_ t: GaussianTrainer, _ cam: TrainingCamera) -> [SIMD3<Float>] {
    let p = t.parameters()
    let W = t.width, H = t.height
    struct G { var xy: SIMD2<Float>; var conic: SIMD3<Float>; var op: Float; var col: SIMD3<Float>; var depth: Float; var rect: SIMD4<Int> }
    var gs: [G] = []
    let tanX = Float(W) / (2 * cam.fx), tanY = Float(H) / (2 * cam.fy)
    let tilesX = (W + 15) / 16, tilesY = (H + 15) / 16
    for i in 0..<t.count {
        let m = SIMD3(p.means[i].x, p.means[i].y, p.means[i].z)
        let pc = SIMD3(simd_dot(cam.r0, m), simd_dot(cam.r1, m), simd_dot(cam.r2, m)) + cam.t
        if pc.z < 0.02 { continue }
        var q = p.quats[i]; q /= simd_length(q)
        let (w, x, y, z) = (q.x, q.y, q.z, q.w)
        let R = simd_float3x3(SIMD3(1 - 2 * (y * y + z * z), 2 * (x * y + w * z), 2 * (x * z - w * y)),
                              SIMD3(2 * (x * y - w * z), 1 - 2 * (x * x + z * z), 2 * (y * z + w * x)),
                              SIMD3(2 * (x * z + w * y), 2 * (y * z - w * x), 1 - 2 * (x * x + y * y)))
        let s = SIMD3(exp(p.logScales[i].x), exp(p.logScales[i].y), exp(p.logScales[i].z))
        let M = simd_float3x3(R[0] * s.x, R[1] * s.y, R[2] * s.z)
        let S = M * M.transpose
        let invz = 1 / pc.z
        let cx = min(max(pc.x * invz, -1.3 * tanX), 1.3 * tanX), cy = min(max(pc.y * invz, -1.3 * tanY), 1.3 * tanY)
        let t0 = cam.fx * invz * cam.r0 + (-cam.fx * cx * invz) * cam.r2
        let t1 = cam.fy * invz * cam.r1 + (-cam.fy * cy * invz) * cam.r2
        let A = simd_dot(t0, S * t0) + 0.3, B = simd_dot(t0, S * t1), C = simd_dot(t1, S * t1) + 0.3
        let det = A * C - B * B
        if !(det > 1e-12) { continue }
        let mid = 0.5 * (A + C), lambda = mid + sqrt(max(0.1, mid * mid - det))
        let radius = min(ceil(3 * sqrt(lambda)), 256)
        let xy = SIMD2(cam.fx * pc.x * invz + cam.cx, cam.fy * pc.y * invz + cam.cy)
        let x0 = max(0, Int(floor((xy.x - radius) / 16))), x1 = min(tilesX, Int(floor((xy.x + radius) / 16)) + 1)
        let y0 = max(0, Int(floor((xy.y - radius) / 16))), y1 = min(tilesY, Int(floor((xy.y + radius) / 16)) + 1)
        if x1 <= x0 || y1 <= y0 { continue }
        let c = p.colorOp[i]
        gs.append(G(xy: xy, conic: SIMD3(C / det, -B / det, A / det), op: 1 / (1 + exp(-c.w)),
                    col: simd_max(.zero, 0.5 + 0.28209479 * SIMD3(c.x, c.y, c.z)), depth: pc.z, rect: SIMD4(x0, y0, x1, y1)))
    }
    gs.sort { $0.depth < $1.depth }
    var image = [SIMD3<Float>](repeating: .zero, count: W * H)
    for py in 0..<H { for px in 0..<W {
        let tx = px / 16, ty = py / 16
        var T: Float = 1, col = SIMD3<Float>.zero
        for g in gs where tx >= g.rect.x && tx < g.rect.z && ty >= g.rect.y && ty < g.rect.w {
            let d = g.xy - SIMD2(Float(px), Float(py))
            let power = -0.5 * (g.conic.x * d.x * d.x + g.conic.z * d.y * d.y) - g.conic.y * d.x * d.y
            if power > 0 { continue }
            let alpha = min(0.99, g.op * exp(power))
            if alpha < 1 / 255 { continue }
            let next = T * (1 - alpha)
            if next < 1e-4 { break }
            col += g.col * alpha * T; T = next
        }
        image[py * W + px] = col
    } }
    return image
}

func psnr(_ a: [SIMD4<Float>], _ target: Data, image: Int, pixels: Int) -> Float {
    var mse: Double = 0
    target.withUnsafeBytes { raw in
        let b = raw.bindMemory(to: UInt8.self)
        for i in 0..<pixels {
            for c in 0..<3 {
                let d = Double(a[i][c]) - Double(b[(image * pixels + i) * 4 + c]) / 255
                mse += d * d
            }
        }
    }
    mse /= Double(pixels * 3)
    return Float(10 * log10(1 / max(mse, 1e-12)))
}

// MARK: 1. Forward matches the CPU reference (projection, binning, sort, blending)
do {
    let W = 96, H = 72
    var seeds: [GaussianSeed] = []
    for _ in 0..<600 {
        seeds.append(GaussianSeed(position: SIMD3(rnd(-0.6, 0.6), rnd(-0.6, 0.6), rnd(-0.6, 0.6)), size: rnd(0.01, 0.08),
                                  color: SIMD3(rnd(0, 1), rnd(0, 1), rnd(0, 1))))
    }
    let cams = (0..<3).map { k -> TrainingCamera in
        let a = Float(k) * 2.1
        return TrainingCamera(cameraToWorld: lookAt(SIMD3(2 * sin(a), 0.4, 2 * cos(a)), .zero), fx: 80, fy: 80, cx: 47.5, cy: 35.5, imageIndex: 0)
    }
    let trainer = try GaussianTrainer(device: device, library: library, seeds: seeds, cameras: cams,
                                      targets: Data(count: W * H * 4), width: W, height: H)
    // Random anisotropy and opacity so the test is not only spheres.
    for i in 0..<trainer.count {
        trainer.setParameter(trainer.logScales, index: i, value: SIMD4(log(rnd(0.01, 0.1)), log(rnd(0.01, 0.1)), log(rnd(0.01, 0.1)), 0))
        trainer.setParameter(trainer.quats, index: i, value: simd_normalize(SIMD4(rnd(-1, 1), rnd(-1, 1), rnd(-1, 1), rnd(-1, 1))))
        var c = trainer.value(trainer.colorOp, index: i); c.w = rnd(-2, 2)
        trainer.setParameter(trainer.colorOp, index: i, value: c)
    }
    var worst: Float = 0
    for k in 0..<3 {
        let gpu = try trainer.render(cameraIndex: k)
        let cpu = cpuRender(trainer, cams[k])
        for i in 0..<(W * H) { worst = max(worst, simd_reduce_max(simd_abs(SIMD3(gpu[i].x, gpu[i].y, gpu[i].z) - cpu[i]))) }
    }
    print(String(format: "1. forward vs CPU reference: max pixel difference %.2e  %@", worst, worst < 2e-3 ? "OK" : "FAIL"))
}

// MARK: 2. Gradients match finite differences
do {
    let W = 64, H = 48
    var seeds: [GaussianSeed] = []
    for k in 0..<5 { // ≥ 8 cm apart in depth: a finite step must not swap the draw order
        seeds.append(GaussianSeed(position: SIMD3(rnd(-0.25, 0.25), rnd(-0.2, 0.2), -0.2 + 0.1 * Float(k)), size: 0.08,
                                  color: SIMD3(rnd(0.2, 0.8), rnd(0.2, 0.8), rnd(0.2, 0.8))))
    }
    let cam = TrainingCamera(cameraToWorld: lookAt(SIMD3(0.3, 0.2, 1.6), .zero), fx: 60, fy: 60, cx: 31.5, cy: 23.5, imageIndex: 0)
    var smooth = GaussianTrainer.Config()
    smooth.minAlpha = 0; smooth.radiusSigmas = 40; smooth.maxRadius = 4096 // no cut-offs: a differentiable forward
    let trainer = try GaussianTrainer(device: device, library: library, seeds: seeds, cameras: [cam],
                                      targets: Data(count: W * H * 4), width: W, height: H, config: smooth)
    for i in 0..<trainer.count {
        trainer.setParameter(trainer.logScales, index: i, value: SIMD4(log(rnd(0.05, 0.12)), log(rnd(0.05, 0.12)), log(rnd(0.05, 0.12)), 0))
        trainer.setParameter(trainer.quats, index: i, value: simd_normalize(SIMD4(rnd(0.5, 1), rnd(-0.5, 0.5), rnd(-0.5, 0.5), rnd(-0.5, 0.5))) * 1.3)
        var c = trainer.value(trainer.colorOp, index: i); c.w = rnd(-1, 0.5)
        trainer.setParameter(trainer.colorOp, index: i, value: c)
    }
    let weights = (0..<(W * H)).map { _ in SIMD4<Float>(rnd(-1, 1), rnd(-1, 1), rnd(-1, 1), 0) }
    func loss() throws -> Double {
        let image = try trainer.render(cameraIndex: 0)
        var total: Double = 0
        for i in 0..<(W * H) { total += Double(simd_dot(SIMD3(image[i].x, image[i].y, image[i].z), SIMD3(weights[i].x, weights[i].y, weights[i].z))) }
        return total
    }
    let analytic = try trainer.gradients(cameraIndex: 0, dLdPixel: weights)
    var report: [(String, Float, Float)] = []
    let groups: [(String, MTLBuffer, [SIMD4<Float>], [Int], Float)] = [
        ("mean", trainer.means, analytic.mean, [0, 1, 2], 1e-3),
        ("logScale", trainer.logScales, analytic.scale, [0, 1, 2], 1e-3),
        ("quat", trainer.quats, analytic.quat, [0, 1, 2, 3], 1e-3),
        ("colour/opacity", trainer.colorOp, analytic.colorOp, [0, 1, 2, 3], 1e-3),
    ]
    for (name, buffer, grad, components, eps) in groups {
        var maxRel: Float = 0, maxAbs: Float = 0
        for i in 0..<trainer.count { for c in components {
            let original = trainer.value(buffer, index: i)
            var plus = original; plus[c] += eps
            trainer.setParameter(buffer, index: i, value: plus)
            let lp = try loss()
            var minus = original; minus[c] -= eps
            trainer.setParameter(buffer, index: i, value: minus)
            let lm = try loss()
            trainer.setParameter(buffer, index: i, value: original)
            let numeric = Float((lp - lm) / Double(2 * eps))
            let a = grad[i][c]
            let scale = max(abs(numeric), abs(a), 1e-1)
            maxRel = max(maxRel, abs(numeric - a) / scale)
            if abs(numeric - a) / scale > 0.05 {
                let m = trainer.value(trainer.means, index: i)
                print("   mismatch", name, "gaussian", i, "component", c, "analytic", a, "numeric", numeric, "mean", m)
            }
            maxAbs = max(maxAbs, abs(numeric))
        } }
        report.append((name, maxRel, maxAbs))
    }
    for (name, rel, mag) in report {
        print(String(format: "2. gradient %-15@ worst relative error %.3f (largest gradient %.2f)  %@", name, rel, mag, rel < 0.05 ? "OK" : "CHECK"))
    }
}

// MARK: 3. Training recovers a synthetic scene
do {
    let W = 128, H = 96, views = 24
    var truth: [GaussianSeed] = []
    for _ in 0..<3000 {
        let p = SIMD3(rnd(-0.5, 0.5), rnd(-0.5, 0.5), rnd(-0.5, 0.5))
        // Colour varies smoothly with position plus some detail.
        let c = simd_clamp(SIMD3(0.5 + 0.5 * sin(4 * p.x), 0.5 + 0.5 * cos(5 * p.y), 0.5 + 0.4 * sin(6 * p.z + p.x)) + SIMD3(rnd(-0.1, 0.1), rnd(-0.1, 0.1), rnd(-0.1, 0.1)), .zero, SIMD3(repeating: 1))
        truth.append(GaussianSeed(position: p, size: rnd(0.02, 0.05), color: c))
    }
    let cams = (0..<views).map { k -> TrainingCamera in
        let a = Float(k) / Float(views) * 2 * .pi
        let h: Float = k % 2 == 0 ? 0.3 : 0.9
        return TrainingCamera(cameraToWorld: lookAt(SIMD3(2.2 * sin(a), h, 2.2 * cos(a)), .zero), fx: 110, fy: 110, cx: 63.5, cy: 47.5, imageIndex: k)
    }
    let gt = try GaussianTrainer(device: device, library: library, seeds: truth, cameras: cams,
                                 targets: Data(count: W * H * 4 * views), width: W, height: H)
    for i in 0..<gt.count { var c = gt.value(gt.colorOp, index: i); c.w = 1.5; gt.setParameter(gt.colorOp, index: i, value: c) }
    var targets = Data(count: W * H * 4 * views)
    for k in 0..<views {
        let image = try gt.render(cameraIndex: k)
        targets.withUnsafeMutableBytes { raw in
            let b = raw.bindMemory(to: UInt8.self)
            for i in 0..<(W * H) { for c in 0..<3 { b[(k * W * H + i) * 4 + c] = UInt8(max(0, min(255, (image[i][c] * 255).rounded()))) }; b[(k * W * H + i) * 4 + 3] = 255 }
        }
    }
    // Start: positions jittered by ~4 cm, colours grey — like a rough LiDAR init.
    let start = truth.map { GaussianSeed(position: $0.position + SIMD3(rnd(-0.04, 0.04), rnd(-0.04, 0.04), rnd(-0.04, 0.04)), size: 0.03, color: SIMD3(repeating: 0.5)) }
    var config = GaussianTrainer.Config()
    config.iterations = 1500
    let trainer = try GaussianTrainer(device: device, library: library, seeds: start, cameras: cams, targets: targets,
                                      width: W, height: H, config: config)
    func meanPSNR() throws -> Float {
        var total: Float = 0
        for k in 0..<views { total += psnr(try trainer.render(cameraIndex: k), targets, image: k, pixels: W * H) }
        return total / Float(views)
    }
    let before = try meanPSNR()
    let clock = Date()
    var relocated = 0
    for _ in 0..<config.iterations { relocated += try trainer.trainStep().relocated }
    let seconds = Date().timeIntervalSince(clock)
    let after = try meanPSNR()
    print(String(format: "3. synthetic scene: PSNR %.1f dB → %.1f dB after %d steps (%.1f ms/step on this Mac, %d relocations)  %@",
                 before, after, config.iterations, seconds / Double(config.iterations) * 1000, relocated, after > before + 8 ? "OK" : "CHECK"))
}

// Covariance-noise regression: isolate Adam with zero gradients/learning rates.
func perturbSize(_ size: Float) throws -> SIMD3<Float> {
    let pipeline = try device.makeComputePipelineState(function: library.makeFunction(name: "adam")!)
    let buffers = (0..<10).map { _ in device.makeBuffer(length: 64, options: .storageModeShared)! }
    for b in buffers { memset(b.contents(), 0, 64) }
    buffers[1].contents().storeBytes(of: SIMD4<Float>(repeating: log(size)), as: SIMD4<Float>.self)
    buffers[2].contents().storeBytes(of: SIMD4<Float>(1,0,0,0), as: SIMD4<Float>.self)
    buffers[3].contents().storeBytes(of: SIMD4<Float>(0,0,0,-10), as: SIMD4<Float>.self)
    var p = AdamUniform(lrMean: .zero, lrScale: .zero, lrQuat: .zero, lrColorOp: .zero,
                        beta1: 0.9, beta2: 0.999, epsilon: 1e-8, bc1: 0.1, bc2: 0.001, noiseScale: 1, step: 1, pad: 0)
    var n: UInt32 = 1
    let command = device.makeCommandQueue()!.makeCommandBuffer()!, e = command.makeComputeCommandEncoder()!
    e.setComputePipelineState(pipeline)
    for (i,b) in buffers.enumerated() { e.setBuffer(b, offset: 0, index: i) }
    e.setBytes(&p, length: MemoryLayout<AdamUniform>.stride, index: 10);e.setBytes(&n, length: 4, index: 11)
    e.dispatchThreads(MTLSize(width: 1,height: 1,depth: 1), threadsPerThreadgroup: MTLSize(width: 1,height: 1,depth: 1))
    e.endEncoding();command.commit();command.waitUntilCompleted()
    precondition(command.status == .completed)
    let v = buffers[0].contents().load(as: SIMD4<Float>.self);return SIMD3(v.x,v.y,v.z)
}
let smallNoise = try perturbSize(0.01), largeNoise = try perturbSize(0.02)
let noiseRatio = simd_length(largeNoise) / simd_length(smallNoise)
print("MCMC covariance scaling: sigma x2 -> displacement x\(noiseRatio) (expected 4)")
guard simd_length(largeNoise - 4 * smallNoise) < 1e-7 else { exit(1) }
