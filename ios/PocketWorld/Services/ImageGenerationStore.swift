import Foundation
import CryptoKit
import UIKit

@MainActor
final class ImageGenerationStore: ObservableObject {
    struct Envelope: Decodable { let image: ImageGeneration }
    struct Listing: Decodable { let images: [ImageGeneration] }
    struct Entry: Codable, Identifiable {
        var image: ImageGeneration
        var submitted = false
        var requestedAttempt: String?
        var scanSource: ScanSubjectPhoto.Source?
        var id: String { image.id }
    }
    nonisolated static let consent = "2026-11-10-single-image-v1"
    @Published private(set) var entries: [Entry] = []
    @Published private(set) var busyID: String?
    @Published private(set) var progress: Double = 0
    @Published var error: String?
    let api: APIClient
    private let identity: APIConnectionIdentity?
    private var operation: Task<Void, Never>?
    private static var deletionRevisions: [String: Int] = [:]
    private var deletionRevision: Int { Self.deletionRevisions[identity?.cacheKey ?? "offline", default: 0] }
    init(api: APIClient) {
        self.api = api; identity = api.connectionIdentity
        if let identity, let folder = try? Self.directory(identity: identity),
           let data = try? Data(contentsOf: folder.appendingPathComponent("library.json")),
           let saved = try? JSONDecoder().decode([Entry].self, from: data),
           saved.allSatisfy({ (try? $0.image.validate()) != nil }) { entries = saved }
    }
    static func directory(identity: APIConnectionIdentity) throws -> URL {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let dir = support.appendingPathComponent("ImageGenerations/" + identity.cacheKey, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    private func persist() throws {
        guard let identity else { throw APIError.configuration("请先连接服务器。") }
        try api.requireConnection(identity)
        try JSONEncoder().encode(entries).write(to: Self.directory(identity: identity).appendingPathComponent("library.json"), options: .atomic)
    }
    func sourceURL(_ id: String) -> URL? {
        guard UUID(uuidString: id) != nil, let identity, let dir = try? Self.directory(identity: identity) else { return nil }
        return dir.appendingPathComponent(id).appendingPathComponent("image.jpg")
    }
    func add(data: Data) throws {
        guard let image = UIImage(data: data) else { throw APIError.configuration("无法读取这张图片。") }
        try add(image: image)
    }
    @discardableResult
    func add(image: UIImage, scanSource: ScanSubjectPhoto.Source? = nil) throws -> String {
        guard let identity else { throw APIError.configuration("请先连接服务器，建立本机作品库。") }
        try api.requireConnection(identity)
        if let scanSource, let existing = entries.first(where: { $0.scanSource?.captureID == scanSource.captureID }) { return existing.id }
        let jpeg = try Self.normalizedJPEG(image)
        let id = UUID().uuidString.lowercased(), hash = SHA256.hash(data: jpeg).map { String(format: "%02x", $0) }.joined()
        let folder = try Self.directory(identity: identity).appendingPathComponent(id)
        let item = ImageGeneration(id: id, sha256: hash, byteSize: jpeg.count, status: "draft", sourceKind: "ai_single_image", createdAt: Date().ISO8601Format())
        let previous = entries
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try jpeg.write(to: folder.appendingPathComponent("image.jpg"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            entries.insert(Entry(image: item, scanSource: scanSource), at: 0)
            try persist()
        } catch {
            entries = previous
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
        return id
    }
    /// Shared camera/album boundary: upright pixels, bounded resolution, no source metadata.
    static func normalizedJPEG(_ input: UIImage) throws -> Data {
        var pixelSize = CGSize(width: input.size.width * input.scale, height: input.size.height * input.scale)
        if let cg = input.cgImage {
            switch input.imageOrientation {
            case .left, .leftMirrored, .right, .rightMirrored:
                pixelSize = CGSize(width: cg.height, height: cg.width)
            default: pixelSize = CGSize(width: cg.width, height: cg.height)
            }
        }
        guard pixelSize.width.isFinite, pixelSize.height.isFinite, pixelSize.width > 0, pixelSize.height > 0 else { throw APIError.configuration("无法读取这张图片。") }
        let scale = min(1, 2048 / max(pixelSize.width, pixelSize.height))
        let size = CGSize(width: max(1, (pixelSize.width * scale).rounded()), height: max(1, (pixelSize.height * scale).rounded()))
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        // Normalize orientation and strip GPS/EXIF before any upload.
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill();context.fill(CGRect(origin: .zero, size: size)); input.draw(in: CGRect(origin: .zero, size: size))
        }
        guard let jpeg = image.jpegData(compressionQuality: 0.92), jpeg.count <= 20 * 1024 * 1024 else { throw APIError.configuration("图片过大。") }
        return jpeg
    }
    func refresh() async {
        guard busyID == nil else { return }
        let revision = deletionRevision
        do {
            try api.requireConnection(identity)
            let list: Listing = try await api.get("/v2/image-generations")
            guard revision == deletionRevision, busyID == nil else { return }
            if let identity, let data = try? Data(contentsOf: Self.directory(identity: identity).appendingPathComponent("library.json")),
               let saved = try? JSONDecoder().decode([Entry].self, from: data),
               saved.allSatisfy({ (try? $0.image.validate()) != nil }) { entries = saved }
            for image in list.images {
                try image.validate()
                if let i = entries.firstIndex(where: { $0.id == image.id }) {
                    guard entries[i].image.sha256 == image.sha256 else { throw ReconstructionStudyError.invalidManifest }
                    entries[i].image = image; entries[i].submitted = true
                    if image.attemptId == entries[i].requestedAttempt { entries[i].requestedAttempt = nil }
                } else { entries.append(Entry(image: image, submitted: true)) }
            }
            try persist()
        } catch { if entries.contains(where: { $0.image.pending }) { self.error = error.localizedDescription } }
    }
    func generate(_ id: String) {
        guard busyID == nil, let i = entries.firstIndex(where: { $0.id == id }) else { return }
        guard api.serverFeatures.contains("single-image-generation") else { error = "服务器尚未启用单图生成。"; return }
        if entries[i].requestedAttempt == nil { entries[i].requestedAttempt = UUID().uuidString.lowercased() }
        do { try persist() } catch { self.error = error.localizedDescription; return }
        busyID = id; error = nil; progress = 0
        operation = Task { [self] in
            defer { busyID = nil; operation = nil }
            do {
                let initial = entries.first(where: { $0.id == id })!
                struct Create: Encodable { let id: String; let sha256: String; let byteSize: Int; let consentVersion = ImageGenerationStore.consent }
                let registered: Envelope = try await api.json("/v2/image-generations", body: Create(id: id, sha256: initial.image.sha256, byteSize: initial.image.byteSize))
                try replace(registered.image)
                if registered.image.status == "draft" {
                    guard let file = sourceURL(id), FileManager.default.fileExists(atPath: file.path) else { throw APIError.configuration("本机原图已丢失，请重新选图。") }
                    try await api.uploadPrivateFile(path: "/v2/image-generations/\(id)/image-upload", file: file, mime: "image/jpeg", hash: initial.image.sha256) { [self] value in progress = value }
                }
                try Task.checkCancellation()
                struct Start: Encodable { let id: String; let consentVersion = ImageGenerationStore.consent }
                let result: Envelope = try await api.json("/v2/image-generations/\(id)/start", body: Start(id: initial.requestedAttempt!))
                try replace(result.image, clearIntent: true)
            } catch APIError.serverBusy {
                if let i = entries.firstIndex(where: { $0.id == id }) { entries[i].requestedAttempt = nil; try? persist() }
                error = APIError.serverBusy.localizedDescription
            } catch is CancellationError { error = "上传已暂停，收到的部分已保留。" }
            catch { self.error = error.localizedDescription }
        }
    }
    private func replace(_ image: ImageGeneration, clearIntent: Bool = false) throws {
        try image.validate();try api.requireConnection(identity)
        guard let i = entries.firstIndex(where: { $0.id == image.id }), entries[i].image.sha256 == image.sha256 else { throw ReconstructionStudyError.invalidManifest }
        entries[i].image = image;entries[i].submitted = true
        if clearIntent { entries[i].requestedAttempt = nil }; try persist()
    }
    func recoverDelivery(_ id: String) async {
        guard busyID == nil else { return }
        guard api.serverFeatures.contains("single-image-result-recovery") else {
            await refresh(); error = "服务器结果修复尚未启用，请暂勿重新生成。"; return
        }
        busyID = id; error = nil
        defer { busyID = nil }
        do {
            try api.requireConnection(identity)
            let result: Envelope = try await api.json("/v2/image-generations/\(id)/retry-delivery", body: [String: String]())
            try replace(result.image, clearIntent: true)
        } catch { self.error = error.localizedDescription }
    }
    func pause() { operation?.cancel() }
    func cancel(_ id: String) async {
        do { let response: Envelope = try await api.json("/v2/image-generations/\(id)/cancel", body: [String:String]());try replace(response.image, clearIntent: true) }
        catch { self.error = error.localizedDescription }
    }
    @discardableResult
    func delete(_ id: String) async -> Bool {
        guard busyID == nil else { error = "有上传正在进行，请稍后删除。"; return false }
        guard let entry = entries.first(where: { $0.id == id }) else { return true }
        guard !entry.image.pending else { error = "生成结束或取消后才能删除。"; return false }
        let scope = identity?.cacheKey ?? "offline"
        Self.deletionRevisions[scope, default: 0] += 1; busyID = id; error = nil
        defer { busyID = nil; Self.deletionRevisions[scope, default: 0] += 1 }
        do {
            try api.requireConnection(identity)
            if entry.submitted || entry.requestedAttempt != nil {
                do { try await api.delete("/v2/image-generations/\(id)") }
                catch APIError.server(let code, _) where code == 404 { /* idempotent recovery */ }
            }
            let previous = entries
            entries.removeAll { $0.id == id }
            do { try persist() } catch { entries = previous; throw error }
            if let source = sourceURL(id) { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
}
