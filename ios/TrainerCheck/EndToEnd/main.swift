import Foundation
import Metal
import simd
import ImageIO
import UniformTypeIdentifiers

enum TrainingPackageWriter { static let folderName = "capture" }
let device = MTLCreateSystemDefaultDevice()!
let library = try device.makeLibrary(URL: URL(fileURLWithPath: CommandLine.arguments[1]))
struct Seeded: RandomNumberGenerator { var state: UInt64; mutating func next() -> UInt64 { state = state &* 6364136223846793005 &+ 1442695040888963407; return state } }
var random = Seeded(state: 7)
func rnd(_ a: Float, _ b: Float) -> Float { Float.random(in: a..<b, using: &random) }
func lookAt(_ eye: SIMD3<Float>, _ target: SIMD3<Float>) -> simd_float4x4 {
    let back = simd_normalize(eye - target), right = simd_normalize(simd_cross(SIMD3(0, 1, 0), back)), up = simd_cross(back, right)
    return simd_float4x4(columns: (SIMD4(right, 0), SIMD4(up, 0), SIMD4(back, 0), SIMD4(eye, 1)))
}
// Ground truth: a coloured "object" on a floor patch, seen by 48 ARKit-style cameras (portrait-held
// phone: landscape sensor images whose up vector is the camera's +x... kept simple: landscape).
var truth: [GaussianSeed] = []
for _ in 0..<5000 {
    let a = rnd(0, 2 * .pi), h = rnd(0, 0.5), r: Float = 0.15 + 0.05 * sin(6 * h)
    truth.append(GaussianSeed(position: SIMD3(r * cos(a), h, r * sin(a)), size: 0.012, color: SIMD3(0.5 + 0.4 * sin(3 * a), 0.3 + 0.6 * h, 0.6)))
}
for _ in 0..<2000 { truth.append(GaussianSeed(position: SIMD3(rnd(-0.6, 0.6), -0.01, rnd(-0.6, 0.6)), size: 0.02, color: SIMD3(0.35, 0.3, 0.25) + SIMD3(repeating: rnd(-0.1, 0.1)))) }
let W = 960, H = 720, views = 48
var frames: [[String: Any]] = []
let root = URL(fileURLWithPath: CommandLine.arguments[2])
let capture = root.appendingPathComponent("scan.scan/capture")
try? FileManager.default.removeItem(at: root.appendingPathComponent("scan.scan"))
try FileManager.default.createDirectory(at: capture.appendingPathComponent("images"), withIntermediateDirectories: true)
var cams: [TrainingCamera] = []
var poses: [simd_float4x4] = []
for k in 0..<views {
    let a = Float(k) / Float(views) * 2 * .pi
    let pose = lookAt(SIMD3(1.1 * sin(a), k % 2 == 0 ? 0.6 : 0.95, 1.1 * cos(a)), SIMD3(0, 0.22, 0))
    poses.append(pose)
    cams.append(TrainingCamera(cameraToWorld: pose, fx: 700, fy: 700, cx: 479.5, cy: 359.5, imageIndex: k))
}
let gt = try GaussianTrainer(device: device, library: library, seeds: truth, cameras: cams, targets: Data(count: W * H * 4 * views), width: W, height: H)
for i in 0..<gt.count { var c = gt.value(gt.colorOp, index: i); c.w = 2; gt.setParameter(gt.colorOp, index: i, value: c) }
for k in 0..<views {
    let image = try gt.render(cameraIndex: k)
    var bytes = [UInt8](repeating: 255, count: W * H * 4)
    for i in 0..<(W * H) { for c in 0..<3 { bytes[i * 4 + c] = UInt8(max(0, min(255, (image[i][c] * 255).rounded()))) } }
    let provider = CGDataProvider(data: Data(bytes) as CFData)!
    let cg = CGImage(width: W, height: H, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: W * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                     bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    let name = String(format: "images/frame_%05d.jpg", k + 1)
    let dest = CGImageDestinationCreateWithURL(capture.appendingPathComponent(name) as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary); CGImageDestinationFinalize(dest)
    let m = poses[k]
    frames.append(["file_path": name, "transform_matrix": (0..<4).map { r in (0..<4).map { c in Double(m[c][r]) } },
                   "fl_x": 700.0, "fl_y": 700.0, "cx": 479.5, "cy": 359.5, "w": W, "h": H, "timestamp": 100 + Double(k) / 3])
}
try JSONSerialization.data(withJSONObject: ["camera_model": "OPENCV", "frames": frames]).write(to: capture.appendingPathComponent("transforms.json"))
try JSONSerialization.data(withJSONObject: ["mode": "object", "points3d": ["voxel_m": 0.01]]).write(to: capture.appendingPathComponent("meta.json"))
// LiDAR-like start: true positions with 1.5 cm noise, colours greyed and noisy.
var ply = Data("ply\nformat binary_little_endian 1.0\nelement vertex \(truth.count)\nproperty float x\nproperty float y\nproperty float z\nproperty uchar red\nproperty uchar green\nproperty uchar blue\nend_header\n".utf8)
for g in truth {
    var p = [g.position.x + rnd(-0.015, 0.015), g.position.y + rnd(-0.015, 0.015), g.position.z + rnd(-0.015, 0.015)]
    p.withUnsafeBytes { ply.append(contentsOf: $0) }
    let c = simd_clamp(0.5 * g.color + 0.25, .zero, SIMD3(repeating: 1)) * 255
    ply.append(contentsOf: [UInt8(c.x), UInt8(c.y), UInt8(c.z)])
}
try ply.write(to: capture.appendingPathComponent("points3d.ply"))

// The app's pipeline from here on.
let dataset = try TrainingDataset.load(scanFolder: root.appendingPathComponent("scan.scan"), limits: .init(maxFrames: 160, longSide: 384, maxGaussians: 250_000))
print("dataset:", dataset.cameras.count, "views at", dataset.width, "×", dataset.height, "seeds", dataset.seeds.count)
var config = GaussianTrainer.Config(); config.iterations = 2000
let trainer = try GaussianTrainer(device: device, library: library, seeds: dataset.seeds, cameras: dataset.cameras, targets: dataset.targets, width: dataset.width, height: dataset.height, config: config)
let split = TrainingQualityPlan.splitViews(count: dataset.cameras.count)
try trainer.setTrainingViews(split.train)
let heldBefore = try TrainingViewMetrics.evaluate(trainer: trainer, dataset: dataset, indices: split.validation)
func psnr() throws -> Float {
    var total: Float = 0
    for k in 0..<dataset.cameras.count {
        let image = try trainer.render(cameraIndex: k)
        var mse: Double = 0
        dataset.targets.withUnsafeBytes { raw in
            let b = raw.bindMemory(to: UInt8.self), n = dataset.width * dataset.height
            for i in 0..<n { for c in 0..<3 { let d = Double(image[i][c]) - Double(b[(k * n + i) * 4 + c]) / 255; mse += d * d } }
        }
        total += Float(10 * log10(1 / (mse / Double(dataset.width * dataset.height * 3))))
    }
    return total / Float(dataset.cameras.count)
}
let before = try psnr()
let clock = Date()
for i in 1...config.iterations {
    trainer.setResolution(divisor: TrainingQualityPlan.resolutionDivisor(iteration: i, total: config.iterations))
    try trainer.trainStep()
}
let heldAfter = try TrainingViewMetrics.evaluate(trainer: trainer, dataset: dataset, indices: split.validation)
let after = try psnr()
print(String(format: "end-to-end: PSNR %.1f → %.1f dB in %.1f s (%d steps)", before, after, Date().timeIntervalSince(clock), config.iterations))
print(String(format: "held out %d views: PSNR %.2f → %.2f dB, MAE %.4f → %.4f; trainer buffers %.1f MiB", heldAfter.views,
             heldBefore.psnr, heldAfter.psnr, heldBefore.mae, heldAfter.mae, Double(trainer.workingSetBytes)/1048576))
precondition(heldAfter.psnr > heldBefore.psnr + 6, "held-out views must improve")
let p = trainer.parameters()
let out = root.appendingPathComponent("out"); try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
let kept = try TrainingOutput.writePLY(means: p.means, logScales: p.logScales, quats: p.quats, colorOp: p.colorOp, to: out.appendingPathComponent("scene.ply"))
try TrainingOutput.writeCameras(dataset.frames, to: out.appendingPathComponent("cameras.json"))
print("wrote", kept, "gaussians;", (try Data(contentsOf: out.appendingPathComponent("scene.ply"))).count / 1024, "KB")
