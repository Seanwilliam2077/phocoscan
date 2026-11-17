import Foundation
import CryptoKit

/// Separate from ondevice/: incomplete work never replaces a published result.
enum TrainingCheckpoint {
    static let directory = "ondevice.resume"

    struct Session: Codable {
        let id: UUID
        let plan: TrainingQualityPlan
        let config: GaussianTrainer.Config
        let sourceDigest: String
        var before: TrainingViewMetrics?
        var elapsed: Double = 0
        var peakMetal: Int = 0
        var lastError: Float?
        var subjectDigest: String?
    }
    struct FileRecord: Codable { let size: Int; let sha256: String }
    struct Header: Codable {
        var version = 1
        let generation: UUID
        let session: Session
        let state: GaussianTrainer.State
        let files: [FileRecord]
    }
    enum Failure: LocalizedError {
        case invalid, changedSource
        var errorDescription: String? {
            switch self {
            case .invalid: return "训练进度无法读取，已有结果仍保留。可在菜单中放弃进度后重新训练。"
            case .changedSource: return "扫描素材已变化，无法接着这次训练。已有结果仍保留。"
            }
        }
    }
    static func root(_ scan: URL) -> URL { scan.appendingPathComponent(directory, isDirectory: true) }
    static func exists(_ scan: URL) -> Bool {
        FileManager.default.fileExists(atPath: root(scan).appendingPathComponent("current.json").path)
    }
    static func read(_ scan: URL) throws -> Header? {
        guard exists(scan) else { return nil }
        let url = root(scan).appendingPathComponent("current.json")
        guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) < 128 * 1024,
              let header = try? JSONDecoder().decode(Header.self, from: Data(contentsOf: url)), [1, 2].contains(header.version),
              (1...250_000).contains(header.state.count), (16...2048).contains(header.state.width),
              (16...2048).contains(header.state.height), header.files.count == (header.version == 1 ? 6 : 7),
              (header.version == 1) == (header.state.config.refinement == nil),
              header.session.elapsed.isFinite, header.session.elapsed >= 0,
              header.session.config == header.state.config,
              (1...3000).contains(header.state.config.iterations),
              (0...header.state.config.iterations).contains(header.state.step),
              (8...160).contains(header.session.plan.limits.maxFrames),
              (16...768).contains(header.session.plan.limits.longSide),
              (100...250_000).contains(header.session.plan.limits.maxGaussians),
              (1...(512 * 1024 * 1024)).contains(header.session.plan.metalBudget),
              (1...8_000_000).contains(header.session.plan.pairLimit)
        else { throw Failure.invalid }
        return header
    }

    static func restore(_ scan: URL, header: Header, trainer: GaussianTrainer) throws {
        let folder = root(scan).appendingPathComponent(header.generation.uuidString)
        let expected = trainer.checkpointBuffers.map(\.length)
        let data = try header.files.enumerated().map { i, record -> Data in
            let url = folder.appendingPathComponent("\(i).bin")
            guard record.size == expected[i],
                  try url.resourceValues(forKeys: [.fileSizeKey]).fileSize == record.size else { throw Failure.invalid }
            let bytes = try Data(contentsOf: url, options: .mappedIfSafe)
            guard digest(bytes) == record.sha256 else { throw Failure.invalid }
            return bytes
        }
        try trainer.restore(header.state, buffers: data)
    }

    /// Write new buffers first, atomically switch the small manifest last. A killed/failed
    /// writer leaves the previous generation readable. Only committed generations are loaded.
    static func save(_ scan: URL, session: Session, trainer: GaussianTrainer, control: TrainingRunControl) throws {
        try control.checkCancellation()
        guard trainer.canCheckpoint else { throw Failure.invalid }
        let manager = FileManager.default, base = root(scan), generation = UUID()
        let folder = base.appendingPathComponent(generation.uuidString, isDirectory: true)
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        #if os(iOS)
        try manager.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: base.path)
        try manager.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: folder.path)
        #endif
        var committed = false
        defer { if !committed { try? manager.removeItem(at: folder) } }
        let files = try trainer.checkpointBuffers.enumerated().map { i, buffer -> FileRecord in
            try control.checkCancellation()
            let data = Data(bytesNoCopy: buffer.contents(), count: buffer.length, deallocator: .none)
            let url = folder.appendingPathComponent("\(i).bin")
            try data.write(to: url)
            #if os(iOS)
            try manager.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
            #endif
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.synchronize()
            return FileRecord(size: data.count, sha256: digest(data))
        }
        let header = Header(version: trainer.config.refinement == nil ? 1 : 2, generation: generation, session: session, state: trainer.checkpointState, files: files)
        try control.checkCancellation()
        try JSONEncoder().encode(header).write(to: base.appendingPathComponent("current.json"), options: .atomic)
        committed = true
        #if os(iOS)
        try? manager.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                                   ofItemAtPath: base.appendingPathComponent("current.json").path)
        #endif
        for url in (try? manager.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)) ?? []
        where UUID(uuidString: url.lastPathComponent) != nil && url.lastPathComponent != generation.uuidString {
            try? manager.removeItem(at: url)
        }
    }

    static func remove(_ scan: URL) throws {
        if FileManager.default.fileExists(atPath: root(scan).path) { try FileManager.default.removeItem(at: root(scan)) }
    }

    /// Bind to the exact original poses, point seeds, metadata and selected JPEG bytes.
    /// Hash in bounded chunks; no captures leave the device.
    static func sourceDigest(scan: URL, dataset: TrainingDataset, control: TrainingRunControl) throws -> String {
        let base = scan.appendingPathComponent("capture").standardizedFileURL.resolvingSymlinksInPath()
        var names = ["transforms.json", "points3d.ply"] + dataset.frames.map(\.name)
        if FileManager.default.fileExists(atPath: base.appendingPathComponent("meta.json").path) { names.append("meta.json") }
        var hash = SHA256()
        for name in names {
            try control.checkCancellation()
            let url = base.appendingPathComponent(name).standardizedFileURL.resolvingSymlinksInPath()
            guard url.path.hasPrefix(base.path + "/") else { throw Failure.changedSource }
            hash.update(data: Data(name.utf8)); hash.update(data: Data([0]))
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            while try autoreleasepool(invoking: { () throws -> Bool in
                try control.checkCancellation()
                guard let bytes = try handle.read(upToCount: 1024 * 1024), !bytes.isEmpty else { return false }
                hash.update(data: bytes); return true
            }) {}
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}
