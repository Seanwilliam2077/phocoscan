import Foundation

/// Metadata is measured from the saved AVAsset, not inferred from camera settings.
struct CapturedVideo: Codable, Sendable {
    let url: URL
    let previewURL: URL?
    let capturedAt: Date
    let durationSeconds: Double
    let width: Int
    let height: Int
    let fps: Double
    /// The exact game/backend session that initiated this recording. Legacy sidecars may omit it.
    let sessionID: String?

    init(url: URL, previewURL: URL?, capturedAt: Date, durationSeconds: Double,
         width: Int, height: Int, fps: Double, sessionID: String? = nil) {
        self.url = url
        self.previewURL = previewURL
        self.capturedAt = capturedAt
        self.durationSeconds = durationSeconds
        self.width = width
        self.height = height
        self.fps = fps
        self.sessionID = sessionID
    }

    static func directory() throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory,
                                               in: .userDomainMask,
                                               appropriateFor: nil,
                                               create: true)
        var folder = base.appendingPathComponent("Captures", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        try? folder.setResourceValues(resourceValues)
        return folder
    }

    var sidecarURL: URL { url.deletingPathExtension().appendingPathExtension("capture.json") }

    func saveSidecar() throws {
        try JSONEncoder().encode(self).write(to: sidecarURL, options: .atomic)
    }

    /// Call only after the parent has durably saved its own copy and session association,
    /// or when the player explicitly discards this capture. Never follows arbitrary paths.
    func deleteLocalFiles() throws {
        let managedDirectory = try Self.directory().standardizedFileURL.resolvingSymlinksInPath()
        let files = [url, previewURL, sidecarURL].compactMap { $0 }
        for file in files {
            let parent = file.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
            guard file.isFileURL, parent == managedDirectory else {
                throw NSError(domain: "PocketWorld.Capture", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "拒绝删除采集目录以外的文件。"])
            }
        }
        for file in files where FileManager.default.fileExists(atPath: file.path) {
            try FileManager.default.removeItem(at: file)
        }
    }

    /// Allows a saved recording to be recovered even if the app exited before its callback.
    static func savedCaptures() -> [CapturedVideo] {
        guard let directory = try? directory(),
              let files = try? FileManager.default.contentsOfDirectory(at: directory,
                    includingPropertiesForKeys: nil) else { return [] }
        return files.filter { $0.lastPathComponent.hasSuffix(".capture.json") }
            .compactMap { try? JSONDecoder().decode(CapturedVideo.self, from: Data(contentsOf: $0)) }
            .map { saved in
                CapturedVideo(url: directory.appendingPathComponent(saved.url.lastPathComponent),
                    previewURL: saved.previewURL.map { directory.appendingPathComponent($0.lastPathComponent) },
                    capturedAt: saved.capturedAt, durationSeconds: saved.durationSeconds,
                    width: saved.width, height: saved.height, fps: saved.fps,
                    sessionID: saved.sessionID)
            }
            .filter { FileManager.default.fileExists(atPath: $0.url.path) }
            .sorted { $0.capturedAt > $1.capturedAt }
    }
}
