import CryptoKit
import Foundation
import ImageIO

/// The keyframe pack the cloud 位姿版 trains from (server: `keyframe-pack.mjs`): up to 64 of the
/// scan's own sharp, exposure-locked keyframes with their ARKit poses, plus person masks. The
/// RealityScan Hub takes images, masks and a pose prior, so LiDAR depth is not part of the pack.
///
///     "PWPACK01" | uint32 LE index length | index JSON | file bytes in index order
///
/// The server accepts only keyframes whose ARKit timestamp and pose are already in the scan's
/// verified frame table, so the pack adds pixels, never new poses.
enum KeyframePack {
    static let mime = "application/x-pocketworld-keyframes"
    static let maxFrames = 64
    static let minFrames = 8

    struct Built: Codable, Equatable {
        let url: URL
        let sha256: String
        let byteSize: Int64
        let frameCount: Int
        let masks: Bool
    }

    enum BuildError: LocalizedError {
        case unreadable
        var errorDescription: String? { "这次扫描的训练数据包无法读取。" }
    }

    /// Up to `limit` keyframes spread evenly over the scan. Frames taken while the person moved
    /// are skipped when enough still ones remain.
    static func select(count: Int, moving: [Bool], limit: Int = maxFrames) -> [Int] {
        TrainingFrameSelection.select(count: count, moving: moving, limit: limit)
    }

    /// Builds the pack from `<scan>/capture/`. Returns nil when the scan has too few keyframes
    /// (the 位姿版 then trains from video frames, as before).
    static func build(scanFolder: URL, captureID: String, into directory: URL, subjectMasks: Bool = false) throws -> Built? {
        let package = scanFolder.appendingPathComponent(TrainingPackageWriter.folderName, isDirectory: true)
        guard let data = try? Data(contentsOf: package.appendingPathComponent("transforms.json")),
              let transforms = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let frames = transforms["frames"] as? [[String: Any]] else { throw BuildError.unreadable }
        let existing = frames.filter { frame in
            (frame["file_path"] as? String).map { FileManager.default.fileExists(atPath: package.appendingPathComponent($0).path) } ?? false
        }
        let chosen = select(count: existing.count, moving: existing.map { $0["subject_moving"] as? Bool ?? false })
            .map { existing[$0] }
        guard chosen.count >= minFrames else { return nil }
        let target = subjectMasks ? try subjectTarget(scanFolder: scanFolder) : nil
        let candidates = target == nil ? [] : try ScanSubjectPhoto.candidates(folder: scanFolder, video: false)
        let candidatesByFile = Dictionary(candidates.map { ($0.file, $0) }, uniquingKeysWith: { first, _ in first })
        let masks = target != nil || chosen.allSatisfy { frame in
            (frame["mask_path"] as? String).map { FileManager.default.fileExists(atPath: package.appendingPathComponent($0).path) } ?? false
        }

        var files: [(path: String, data: Data)] = []
        var subset: [[String: Any]] = []
        for (offset, frame) in chosen.enumerated() {
            let name = String(format: "image_%06d", offset + 1)
            guard let image = frame["file_path"] as? String else { throw BuildError.unreadable }
            files.append(("images/\(name).jpg", try Data(contentsOf: package.appendingPathComponent(image))))
            var copy = frame
            copy["file_path"] = "images/\(name).jpg"
            copy["depth_file_path"] = nil
            copy["mask_path"] = nil
            if let target {
                guard let candidate = candidatesByFile[image], let point = subjectPoint(candidate, target: target),
                      let source = CGImageSourceCreateWithURL(package.appendingPathComponent(image) as CFURL, nil),
                      let cg = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw ScanSubjectPhoto.Failure.missingSubject }
                let mask = try autoreleasepool { try PhotoSubjectSelection.maskPNG(cg, at: point) }
                files.append(("masks/\(name).png", mask))
                copy["mask_path"] = "masks/\(name).png"
            } else if masks, let mask = frame["mask_path"] as? String {
                files.append(("masks/\(name).png", try Data(contentsOf: package.appendingPathComponent(mask))))
                copy["mask_path"] = "masks/\(name).png"
            }
            subset.append(copy)
        }
        var header = transforms
        header["frames"] = subset
        header["ply_file_path"] = nil
        var all: [(path: String, data: Data)] = [
            ("transforms.json", try JSONSerialization.data(withJSONObject: header, options: [.sortedKeys]))
        ]
        if let meta = try? Data(contentsOf: package.appendingPathComponent("meta.json")) { all.append(("meta.json", meta)) }
        all += files

        let index: [String: Any] = [
            "version": 1, "captureId": captureID,
            "files": all.map { ["path": $0.path, "byteSize": $0.data.count, "sha256": hex(SHA256.hash(data: $0.data))] }
        ]
        let indexData = try JSONSerialization.data(withJSONObject: index, options: [.sortedKeys])
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("keyframes-\(captureID).pwpack")
        try? FileManager.default.removeItem(at: url)
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        var size: Int64 = 0
        func write(_ chunk: Data) throws {
            try handle.write(contentsOf: chunk)
            hasher.update(data: chunk)
            size += Int64(chunk.count)
        }
        var length = UInt32(indexData.count).littleEndian
        try write(Data("PWPACK01".utf8))
        try write(Data(bytes: &length, count: 4))
        try write(indexData)
        for file in all { try write(file.data) }
        try handle.synchronize()
        return Built(url: url, sha256: hex(hasher.finalize()), byteSize: size, frameCount: subset.count, masks: masks)
    }

    /// Training includes close detail views: only the anchor seed must be visible. Requiring
    /// the full target box (the single-photo picker rule) would reject legitimate close-ups.
    static func subjectPoint(_ frame: ScanSubjectPhoto.Candidate, target: ScanTargetBox) -> CGPoint? {
        guard let point = CaptureFraming.project(target.simdCenter, cameraToWorld: frame.pose,
            intrinsics: frame.intrinsics, resolution: frame.size, display: .identity),
              (0..<1).contains(point.x), (0..<1).contains(point.y) else { return nil }
        return point
    }

    static func subjectTarget(scanFolder: URL) throws -> ScanTargetBox? {
        guard let bytes = try? Data(contentsOf: scanFolder.appendingPathComponent("analysis.json")) else { return nil }
        let json = try JSONSerialization.jsonObject(with: bytes) as? [String: Any]
        guard ["object", "portrait"].contains(json?["mode"] as? String ?? ""), let target = json?["targetBox"] as? [String: Any] else { return nil }
        return try JSONDecoder().decode(ScanTargetBox.self, from: JSONSerialization.data(withJSONObject: target))
    }
    /// Keep exactly the same uploaded bytes across retries; Vision is not rerun after a lost response.
    static func cachedSubjectPack(scanFolder: URL, captureID: String) throws -> Built? {
        let cache = scanFolder.appendingPathComponent("cloud-subject-pack-v1", isDirectory: true)
        let record = cache.appendingPathComponent("pack.json")
        if let data = try? Data(contentsOf: record) {
            let old = try JSONDecoder().decode(Built.self, from: data)
            let url = cache.appendingPathComponent("keyframes-\(captureID).pwpack")
            let bytes = try Data(contentsOf: url, options: .mappedIfSafe)
            guard old.masks, bytes.count == old.byteSize, hex(SHA256.hash(data: bytes)) == old.sha256 else { throw BuildError.unreadable }
            return Built(url: url, sha256: old.sha256, byteSize: old.byteSize, frameCount: old.frameCount, masks: old.masks)
        }
        guard let result = try build(scanFolder: scanFolder, captureID: captureID, into: cache, subjectMasks: true) else { return nil }
        guard result.masks else { throw BuildError.unreadable }
        try JSONEncoder().encode(result).write(to: record, options: .atomic)
        return result
    }

    private static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}

extension KeyframePack {
    struct FileIndex: Codable, Sendable {
        struct Entry: Codable, Sendable { let path: String; let byteSize: Int; let sha256: String }
        let version: Int
        let captureId: String
        let files: [Entry]
    }
    struct Split: Sendable { let indexBase64: String; let index: FileIndex; let folder: URL }
    /// Keep the original index bytes so committing individual files reproduces the exact pack hash.
    static func split(_ url: URL, into folder: URL) throws -> Split {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        let prefix = try handle.read(upToCount: 12) ?? Data()
        guard prefix.count == 12, prefix.prefix(8) == Data("PWPACK01".utf8) else { throw BuildError.unreadable }
        let length = prefix.suffix(4).enumerated().reduce(0) { $0 | Int($1.element) << (8 * $1.offset) }
        guard length > 0, length < 1024 * 1024 else { throw BuildError.unreadable }
        let raw = try handle.read(upToCount: length) ?? Data()
        let index = try JSONDecoder().decode(FileIndex.self, from: raw)
        guard raw.count == length, index.version == 1, UUID(uuidString: index.captureId) != nil, index.files.count <= 130 else { throw BuildError.unreadable }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for file in index.files {
            guard ReconstructionStudy.isSHA256(file.sha256), (1...20*1024*1024).contains(file.byteSize) else { throw BuildError.unreadable }
            let data = try handle.read(upToCount: file.byteSize) ?? Data()
            guard data.count == file.byteSize, hex(SHA256.hash(data: data)) == file.sha256 else { throw BuildError.unreadable }
            try data.write(to: folder.appendingPathComponent(file.sha256), options: .atomic)
        }
        guard (try handle.read(upToCount: 1))?.isEmpty != false else { throw BuildError.unreadable }
        return Split(indexBase64: raw.base64EncodedString(), index: index, folder: folder)
    }
}
