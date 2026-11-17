import Foundation
import CoreGraphics
import ImageIO
import simd

/// Exact, session-bound subject weights. Original RGB, calibration, and LiDAR remain unchanged.
/// Vision operates only during preparation; resume uses the already persisted mask bytes.
enum TrainingSubject {
    struct Prepared {
        let dataset: TrainingDataset
        let digest: String
        let maskedFrames: Int
    }
    struct Index: Codable, Equatable {
        var version = 1
        let source: String
        let frames: [String]
        let width: Int, height: Int
    }
    enum Failure: LocalizedError {
        case insufficientMasks
        var errorDescription: String? { "部分照片未能确认同一个主体，暂时无法进行主体训练。原素材和已有结果仍保留。" }
    }

    static func prepare(_ dataset: TrainingDataset, scan: URL, sourceDigest: String,
                        expectedDigest: String? = nil, control: TrainingRunControl) throws -> Prepared? {
        guard let analysis = ScanAnalysis.load(from: scan), analysis.mode != "space",
              let target = analysis.targetBox else {
            if expectedDigest != nil { throw TrainingCheckpoint.Failure.changedSource }
            return nil
        }
        let analysisBytes = try Data(contentsOf: scan.appendingPathComponent("analysis.json"))
        let source = TrainingCheckpoint.digest(Data(sourceDigest.utf8) + analysisBytes)
        let index = Index(source: source, frames: dataset.frames.map(\.name), width: dataset.width, height: dataset.height)
        let root = TrainingCheckpoint.root(scan).appendingPathComponent("subject", isDirectory: true)
        let indexURL = root.appendingPathComponent("index.json")
        let fm = FileManager.default
        if fm.fileExists(atPath: indexURL.path) {
            guard let old = try? JSONDecoder().decode(Index.self, from: Data(contentsOf: indexURL)), old == index else {
                throw TrainingCheckpoint.Failure.changedSource
            }
        } else {
            guard expectedDigest == nil else { throw TrainingCheckpoint.Failure.invalid }
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            try JSONEncoder().encode(index).write(to: indexURL, options: .atomic)
        }
        try fm.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: root.path)
        let pixels = dataset.width * dataset.height
        var targets = dataset.targets
        var maskHashes: [String] = [], valid = 0
        for (i, frame) in dataset.frames.enumerated() {
            try control.check()
            let url = root.appendingPathComponent("\(i).bin")
            let mask: Data
            if fm.fileExists(atPath: url.path) {
                mask = try Data(contentsOf: url)
                guard mask.count == pixels else { throw TrainingCheckpoint.Failure.invalid }
            } else {
                guard expectedDigest == nil else { throw TrainingCheckpoint.Failure.invalid }
                mask = try autoreleasepool {
                    let c = dataset.cameras[i], p = target.simdCenter
                    let xyz = SIMD3(simd_dot(c.r0, p), simd_dot(c.r1, p), simd_dot(c.r2, p)) + c.t
                    guard xyz.z > 0 else { return Data(repeating: 255, count: pixels) }
                    let point = CGPoint(x: CGFloat((c.fx * xyz.x / xyz.z + c.cx + 0.5) / Float(dataset.width)),
                                        y: CGFloat((c.fy * xyz.y / xyz.z + c.cy + 0.5) / Float(dataset.height)))
                    guard CGRect(x: 0.01, y: 0.01, width: 0.98, height: 0.98).contains(point),
                          let source = CGImageSourceCreateWithURL(scan.appendingPathComponent("capture").appendingPathComponent(frame.name) as CFURL, nil),
                          let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
                          let png = try? PhotoSubjectSelection.maskPNG(image, at: point),
                          let pngSource = CGImageSourceCreateWithData(png as CFData, nil),
                          let cg = CGImageSourceCreateImageAtIndex(pngSource, 0, nil) else {
                        return Data(repeating: 255, count: pixels)
                    }
                    var bytes = Data(count: pixels)
                    let ok = bytes.withUnsafeMutableBytes { raw -> Bool in
                        guard let ctx = CGContext(data: raw.baseAddress, width: dataset.width, height: dataset.height,
                            bitsPerComponent: 8, bytesPerRow: dataset.width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0) else { return false }
                        ctx.interpolationQuality = .high
                        // Same CGContext orientation as TrainingDataset.draw, with untouched RGB/K.
                        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: dataset.width, height: dataset.height))
                        return true
                    }
                    guard ok else { throw GaussianTrainerError.invalidInput }
                    let fraction = bytes.reduce(0.0) { $0 + Double($1) / 255 } / Double(pixels)
                    return (0.001...0.85).contains(fraction) ? bytes : Data(repeating: 255, count: pixels)
                }
                try control.check()
                try mask.write(to: url, options: .atomic)
                try fm.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
            }
            let fraction = mask.reduce(0.0) { $0 + Double($1) / 255 } / Double(pixels)
            if (0.001...0.85).contains(fraction) { valid += 1 }
            maskHashes.append(TrainingCheckpoint.digest(mask))
            targets.withUnsafeMutableBytes { raw in
                let bytes = raw.bindMemory(to: UInt8.self)
                for p in 0..<pixels { bytes[(i * pixels + p) * 4 + 3] = mask[p] }
            }
        }
        guard valid >= max(8, Int(ceil(Double(dataset.frames.count) * 0.8))) else { throw Failure.insufficientMasks }
        let digest = TrainingCheckpoint.digest(Data(([source] + maskHashes).joined(separator: "\n").utf8))
        if let expectedDigest, expectedDigest != digest { throw TrainingCheckpoint.Failure.changedSource }
        return Prepared(dataset: TrainingDataset(cameras: dataset.cameras, targets: targets, width: dataset.width,
            height: dataset.height, seeds: dataset.seeds, frames: dataset.frames), digest: digest, maskedFrames: valid)
    }
}
