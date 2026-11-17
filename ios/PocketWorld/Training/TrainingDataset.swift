import CoreGraphics
import Foundation
import ImageIO
import simd

/// Training inputs from a scan's keyframe package (`<scan>/capture/`): keyframes downscaled to
/// the training size, their ARKit poses and intrinsics, and starting Gaussians from the LiDAR
/// point cloud. Platform-neutral (ImageIO / CoreGraphics only).
struct TrainingDataset {
    let cameras: [TrainingCamera]
    let targets: Data          // RGBA8, width × height per camera, in camera order
    let width: Int
    let height: Int
    let seeds: [GaussianSeed]
    /// Source frames (for the viewer's camera path): original size and intrinsics.
    let frames: [Frame]

    struct Frame {
        let name: String
        let timestamp: Double
        let cameraToWorld: simd_float4x4
        let width: Int, height: Int
        let fx: Float, fy: Float, cx: Float, cy: Float
    }

    struct Limits: Codable {
        var maxFrames = 160
        var longSide = 512
        var maxGaussians = 250_000
    }

    enum LoadError: LocalizedError {
        case noPackage, noPoints, tooFewFrames, unreadableImage
        var errorDescription: String? {
            switch self {
            case .noPackage: return "这次扫描没有训练数据包（更新前录制的扫描没有），请重新扫描。"
            case .noPoints: return "这次扫描没有 LiDAR 点云，本机训练需要带 LiDAR 的 iPhone Pro。"
            case .tooFewFrames: return "清晰的关键帧太少，无法训练。"
            case .unreadableImage: return "有关键帧图片无法读取。"
            }
        }
    }

    static func available(scanFolder: URL) -> Bool { unavailableReason(scanFolder: scanFolder) == nil }

    /// Fast input preflight for the generate button; decoding/training still validates all data.
    static func unavailableReason(scanFolder: URL) -> String? {
        let package = scanFolder.appendingPathComponent("capture")
        guard let data = try? Data(contentsOf: package.appendingPathComponent("transforms.json")),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let frames = object["frames"] as? [[String: Any]] else { return "没有训练数据包" }
        guard frames.count >= 8 else { return "只有 \(frames.count) 张关键帧，至少需要 8 张" }
        guard FileManager.default.fileExists(atPath: package.appendingPathComponent("points3d.ply").path) else { return "缺少 LiDAR 点云" }
        let selected = TrainingFrameSelection.select(count: frames.count, moving: frames.map { $0["subject_moving"] as? Bool ?? false }, limit: 160)
        guard selected.count >= 8 else { return "静止关键帧不足 8 张" }
        for i in selected {
            guard let name = frames[i]["file_path"] as? String,
                  FileManager.default.fileExists(atPath: package.appendingPathComponent(name).path) else { return "关键帧图片缺失" }
        }
        return nil
    }

    static func load(scanFolder: URL, limits: Limits = Limits()) throws -> TrainingDataset {
        guard limits.maxFrames >= 8, limits.longSide >= 16, limits.longSide <= 2048,
              limits.maxGaussians >= 100 else { throw GaussianTrainerError.invalidInput }
        let package = scanFolder.appendingPathComponent("capture", isDirectory: true)
        guard let data = try? Data(contentsOf: package.appendingPathComponent("transforms.json")),
              let transforms = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let all = transforms["frames"] as? [[String: Any]] else { throw LoadError.noPackage }
        let moving = all.map { $0["subject_moving"] as? Bool ?? false }
        let chosen = TrainingFrameSelection.select(count: all.count, moving: moving, limit: limits.maxFrames).map { all[$0] }
        var frames: [Frame] = []
        for entry in chosen {
            try Task.checkCancellation()
            guard let file = entry["file_path"] as? String,
                  let rows = entry["transform_matrix"] as? [[Double]], rows.count == 4, rows.allSatisfy({ $0.count == 4 }),
                  let w = entry["w"] as? Int, let h = entry["h"] as? Int,
                  let fx = entry["fl_x"] as? Double, let fy = entry["fl_y"] as? Double,
                  let cx = entry["cx"] as? Double, let cy = entry["cy"] as? Double,
                  w > 0, h > 0, w <= 16384, h <= 16384, fx.isFinite, fy.isFinite, fx > 0, fy > 0,
                  cx.isFinite, cy.isFinite, rows.joined().allSatisfy(\.isFinite) else { continue }
            let m = simd_float4x4(rows: rows.map { SIMD4<Float>($0.map(Float.init)) })
            frames.append(Frame(name: file, timestamp: entry["timestamp"] as? Double ?? Double(frames.count),
                                cameraToWorld: m, width: w, height: h, fx: Float(fx), fy: Float(fy), cx: Float(cx), cy: Float(cy)))
        }
        guard frames.count >= 8, let first = frames.first else { throw LoadError.tooFewFrames }
        let scale = min(1, Float(limits.longSide) / Float(max(first.width, first.height)))
        let width = max(16, Int((Float(first.width) * scale).rounded()))
        let height = max(16, Int((Float(first.height) * scale).rounded()))
        var targets = Data(count: width * height * 4 * frames.count)
        var cameras: [TrainingCamera] = []
        for (index, frame) in frames.enumerated() {
            try Task.checkCancellation()
            let url = package.appendingPathComponent(frame.name)
            guard let image = downscaled(url: url, longSide: max(width, height)) else { throw LoadError.unreadableImage }
            let ok = targets.withUnsafeMutableBytes { raw -> Bool in
                draw(image, into: raw.baseAddress!.advanced(by: index * width * height * 4), width: width, height: height)
            }
            guard ok else { throw LoadError.unreadableImage }
            let sx = Float(width) / Float(frame.width), sy = Float(height) / Float(frame.height)
            // Pixel centres at integer coordinates in both resolutions.
            cameras.append(TrainingCamera(cameraToWorld: frame.cameraToWorld, fx: frame.fx * sx, fy: frame.fy * sy,
                                          cx: (frame.cx + 0.5) * sx - 0.5, cy: (frame.cy + 0.5) * sy - 0.5, imageIndex: index))
        }
        var voxel: Float = 0.01
        if let metaData = try? Data(contentsOf: package.appendingPathComponent("meta.json")),
           let meta = try? JSONSerialization.jsonObject(with: metaData) as? [String: Any],
           let points = meta["points3d"] as? [String: Any], let value = points["voxel_m"] as? Double {
            if value.isFinite, value > 0, value <= 0.5 { voxel = Float(value) }
        }
        let seeds = try readPoints(package.appendingPathComponent("points3d.ply"), size: voxel * 0.8, limit: limits.maxGaussians)
        return TrainingDataset(cameras: cameras, targets: targets, width: width, height: height, seeds: seeds, frames: frames)
    }

    /// Binary PLY written by `TrainingPackageWriter.writePLY`: float x, y, z; uchar r, g, b.
    static func readPoints(_ url: URL, size: Float, limit: Int) throws -> [GaussianSeed] {
        guard limit > 0, size.isFinite, size > 0 else { throw LoadError.noPoints }
        guard let data = try? Data(contentsOf: url),
              let end = data.range(of: Data("end_header\n".utf8)) else { throw LoadError.noPoints }
        let header = String(decoding: data[..<end.lowerBound], as: UTF8.self)
        guard header.contains("format binary_little_endian"),
              let line = header.split(separator: "\n").first(where: { $0.hasPrefix("element vertex ") }),
              let count = Int(line.split(separator: " ").last ?? ""), count > 0,
              count <= (data.count - end.upperBound) / 15 else { throw LoadError.noPoints }
        let stride = max(1, (count + limit - 1) / limit)
        var seeds: [GaussianSeed] = []
        seeds.reserveCapacity(count / stride + 1)
        data.withUnsafeBytes { raw in
            let base = raw.baseAddress!.advanced(by: end.upperBound)
            for i in Swift.stride(from: 0, to: count, by: stride) {
                let record = base.advanced(by: i * 15)
                let p = SIMD3(record.loadUnaligned(as: Float.self), record.loadUnaligned(fromByteOffset: 4, as: Float.self),
                              record.loadUnaligned(fromByteOffset: 8, as: Float.self))
                let c = record.advanced(by: 12).assumingMemoryBound(to: UInt8.self)
                guard p.x.isFinite, p.y.isFinite, p.z.isFinite else { continue }
                seeds.append(GaussianSeed(position: p, size: size * Float(stride).squareRoot(),
                                          color: SIMD3(Float(c[0]), Float(c[1]), Float(c[2])) / 255))
            }
        }
        guard seeds.count >= 100 else { throw LoadError.noPoints }
        return seeds
    }

    private static func downscaled(url: URL, longSide: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceThumbnailMaxPixelSize: longSide,
                                        kCGImageSourceCreateThumbnailWithTransform: false]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// Draws into RGBA8 (sRGB bytes, as stored in the JPEG) at exactly width × height.
    private static func draw(_ image: CGImage, into base: UnsafeMutableRawPointer, width: Int, height: Int) -> Bool {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: base, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return true
    }
}

/// A bounded policy based on measured process headroom, not just a marketed device name.
struct TrainingQualityPlan: Codable {
    let limits: TrainingDataset.Limits
    let metalBudget: Int
    let pairLimit: Int

    static func make(physicalMemory: UInt64, availableMemory: Int) throws -> TrainingQualityPlan {
        let mib = 1024 * 1024
        guard availableMemory >= 384 * mib else { throw GaussianTrainerError.memoryBudget }
        let side = physicalMemory >= 7 * 1024 * 1024 * 1024 && availableMemory >= 1536 * mib ? 768
            : (availableMemory >= 768 * mib ? 512 : 384)
        let targetBudget = min(256 * mib, availableMemory / 4)
        let frames = min(160, targetBudget / (side * side * 4))
        let metal = min(512 * mib, availableMemory / 3)
        let points = availableMemory >= 1024 * mib ? 250_000 : 100_000
        return TrainingQualityPlan(limits: .init(maxFrames: max(8, frames), longSide: side, maxGaussians: points),
                                   metalBudget: metal, pairLimit: min(8_000_000, metal / 48))
    }

    static func resolutionDivisor(iteration: Int, total: Int) -> Int {
        Double(iteration) < Double(total) * 0.3 ? 2 : 1
    }

    /// Held-out views remain available for rendering/export but never enter stochastic training.
    static func splitViews(count: Int) -> (train: [Int], validation: [Int]) {
        let validation = count >= 16 ? Array(stride(from: 7, to: count, by: 8)) : []
        let held = Set(validation)
        return ((0..<count).filter { !held.contains($0) }, validation)
    }
}

struct TrainingViewMetrics: Codable {
    let views: Int
    let mae: Double
    let psnr: Double

    static func evaluate(trainer: GaussianTrainer, dataset: TrainingDataset, indices: [Int], subjectOnly: Bool = false) throws -> TrainingViewMetrics {
        guard !indices.isEmpty else { throw GaussianTrainerError.invalidInput }
        trainer.setResolution(divisor: 1)
        var absolute = 0.0, squared = 0.0, mass = 0.0
        var evaluated = 0
        let pixels = dataset.width * dataset.height
        for index in indices {
            try Task.checkCancellation()
            guard dataset.cameras.indices.contains(index) else { throw GaussianTrainerError.invalidInput }
            let image = try trainer.render(cameraIndex: index)
            try dataset.targets.withUnsafeBytes { raw in
                let bytes = raw.bindMemory(to: UInt8.self)
                let offset = dataset.cameras[index].imageIndex * pixels * 4
                if subjectOnly {
                    let fraction = (0..<pixels).reduce(0.0) { $0 + Double(bytes[offset + $1 * 4 + 3]) / 255 } / Double(pixels)
                    if fraction <= 0.001 || fraction >= 0.999 { return }
                }
                evaluated += 1
                for p in 0..<pixels {
                    let weight = subjectOnly ? Double(bytes[offset + p * 4 + 3]) / 255 : 1
                    for c in 0..<3 {
                        let diff = Double(image[p][c]) - Double(bytes[offset + p * 4 + c]) / 255
                        guard diff.isFinite else { throw GaussianTrainerError.invalidInput }
                        absolute += weight * abs(diff); squared += weight * diff * diff; mass += weight
                    }
                }
            }
        }
        guard mass > 0 else { throw GaussianTrainerError.invalidInput }
        return TrainingViewMetrics(views: evaluated, mae: absolute / mass, psnr: -10 * log10(max(squared / mass, 1e-12)))
    }
}

/// Writes a trained model as a standard 3DGS PLY (degree-0 colour) and the viewer's camera path.
enum TrainingOutput {
    static func writePLY(means: [SIMD4<Float>], logScales: [SIMD4<Float>], quats: [SIMD4<Float>],
                         colorOp: [SIMD4<Float>], to url: URL, dropBelowOpacity: Float = 0.005) throws -> Int {
        guard !means.isEmpty, means.count == logScales.count, means.count == quats.count,
              means.count == colorOp.count else { throw GaussianTrainerError.invalidInput }
        var keep: [Int] = []
        for i in means.indices {
            for value in [means[i], logScales[i], quats[i], colorOp[i]] {
                guard (0..<4).allSatisfy({ value[$0].isFinite }) else { throw GaussianTrainerError.invalidInput }
            }
            guard simd_length(quats[i]) > 1e-8 else { throw GaussianTrainerError.invalidInput }
            let opacity = 1 / (1 + exp(-colorOp[i].w))
            let p = means[i]
            if opacity >= dropBelowOpacity, p.x.isFinite, p.y.isFinite, p.z.isFinite { keep.append(i) }
        }
        guard !keep.isEmpty else { throw GaussianTrainerError.invalidInput }
        let names = ["x", "y", "z", "nx", "ny", "nz", "f_dc_0", "f_dc_1", "f_dc_2", "opacity",
                     "scale_0", "scale_1", "scale_2", "rot_0", "rot_1", "rot_2", "rot_3"]
        var data = Data(("ply\nformat binary_little_endian 1.0\ncomment phocoscan on-device training\nelement vertex \(keep.count)\n"
            + names.map { "property float \($0)\n" }.joined() + "end_header\n").utf8)
        data.reserveCapacity(data.count + keep.count * names.count * 4)
        for i in keep {
            let q = quats[i] / max(1e-8, simd_length(quats[i]))
            let values: [Float] = [means[i].x, means[i].y, means[i].z, 0, 0, 0,
                                   colorOp[i].x, colorOp[i].y, colorOp[i].z, colorOp[i].w,
                                   logScales[i].x, logScales[i].y, logScales[i].z, q.x, q.y, q.z, q.w]
            values.withUnsafeBytes { data.append(contentsOf: $0) }
        }
        try data.write(to: url, options: .atomic)
        return keep.count
    }

    /// Camera path in the model's frame (= the ARKit world): OpenGL camera-to-world, row-major.
    static func writeCameras(_ frames: [TrainingDataset.Frame], to url: URL) throws {
        let start = frames.map(\.timestamp).min() ?? 0
        var previous = -1.0
        let entries: [[String: Any]] = frames.sorted { $0.timestamp < $1.timestamp }.compactMap { frame in
            let time = frame.timestamp - start
            guard time > previous else { return nil }
            previous = time
            let m = frame.cameraToWorld
            let rows = (0..<4).flatMap { r in (0..<4).map { c in Double(m[c][r]) } }
            return ["sourceFrame": frame.name, "timeSeconds": time, "width": frame.width, "height": frame.height,
                    "fx": Double(frame.fx), "fy": Double(frame.fy), "cx": Double(frame.cx), "cy": Double(frame.cy),
                    "cameraToWorld": rows]
        }
        let path: [String: Any] = ["version": 1, "coordinateSystem": "opengl_camera_to_world", "matrixLayout": "row-major",
                                   "scale": "unknown", "frames": entries]
        try JSONSerialization.data(withJSONObject: path).write(to: url, options: .atomic)
    }
}

/// Shared cloud/local frame selection, independent of UI and subject segmentation.
enum TrainingFrameSelection {
    static func select(count: Int, moving: [Bool], limit: Int) -> [Int] {
        let still = (0..<count).filter { !(moving.indices.contains($0) && moving[$0]) }
        let pool = still.count >= min(limit, 16) ? still : Array(0..<count)
        guard pool.count > limit else { return pool }
        return (0..<limit).map { pool[Int((Double($0) + 0.5) * Double(pool.count) / Double(limit))] }
    }
}
