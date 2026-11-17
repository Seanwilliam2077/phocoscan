import Foundation
import Security
import CryptoKit
import Combine

enum APIError: LocalizedError {
    case configuration(String)
    case server(Int, String)
    case invalidResponse
    case serverBusy
    var errorDescription: String? {
        switch self {
        case .configuration(let message): return message
        case .server(let code, let message): return "\(message)（\(code)）"
        case .serverBusy: return "服务器繁忙中，请稍后重试。"
        case .invalidResponse: return "服务器返回的数据无法读取。请检查服务版本。"
        }
    }
}

enum CredentialStore {
    static func account(_ base: String) -> String { SHA256.hash(data: Data(base.utf8)).map { String(format: "%02x", $0) }.joined() }
    static func read(for base: String) -> AuthResponse? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.pocketworld.player", kSecAttrAccount as String: account(base), kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var output: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &output) == errSecSuccess, let data = output as? Data else { return nil }
        return try? JSONDecoder().decode(AuthResponse.self, from: data)
    }
    static func write(_ value: AuthResponse, for base: String) throws {
        let data = try JSONEncoder().encode(value)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.pocketworld.player", kSecAttrAccount as String: account(base)]
        let attributes: [String: Any] = [kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let update = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if update == errSecItemNotFound {
            var insertion = query
            attributes.forEach { insertion[$0.key] = $0.value }
            guard SecItemAdd(insertion as CFDictionary, nil) == errSecSuccess else { throw APIError.configuration("无法安全保存测试账号。请重试。") }
        } else if update != errSecSuccess {
            throw APIError.configuration("无法更新测试账号凭证。")
        }
    }
}

struct APIConnectionIdentity: Codable, Equatable, Sendable {
    let base: String
    let userID: String
    var cacheKey: String { CredentialStore.account(base + "|" + userID) }
}

private final class PrivateAPISessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

@MainActor
final class APIClient {
    private(set) var baseURL: URL?
    private(set) var auth: AuthResponse?
    /// Optional capabilities the connected server advertises in `/health` (empty for older servers).
    private(set) var serverFeatures: Set<String> = []
    private let session: URLSession
    init(configuration: URLSessionConfiguration = .default) {
        let config = configuration
        config.timeoutIntervalForRequest = 90
        config.timeoutIntervalForResource = 1800
        config.waitsForConnectivity = false
        session = URLSession(configuration: config, delegate: PrivateAPISessionDelegate(), delegateQueue: nil)
    }
    static func normalized(_ string: String) throws -> String {
        let input = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parts = URLComponents(string: input), let scheme = parts.scheme?.lowercased(), ["https", "http"].contains(scheme),
              let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.path.isEmpty || parts.path == "/" else {
            throw APIError.configuration("请填写完整的服务器根地址，例如 https://your-server.example；不能包含账号或路径。")
        }
        #if !DEBUG
        guard scheme == "https" else { throw APIError.configuration("发布版本需要 HTTPS 服务器。") }
        #else
        if scheme == "http" {
            guard ["9.135.79.113", "127.0.0.1", "localhost", "::1"].contains(host.lowercased()) else {
                throw APIError.configuration("Debug 的 HTTP 仅用于已指定的 A10 内网服务器或本机；其他服务请使用 HTTPS。")
            }
        }
        #endif
        var normalized = parts
        normalized.scheme = scheme; normalized.host = host.lowercased(); normalized.path = ""
        guard let value = normalized.url?.absoluteString else { throw APIError.configuration("服务器地址无效。") }
        return value
    }
    func restore(base: String) {
        guard let normalized = try? Self.normalized(base) else { baseURL = nil; auth = nil; return }
        baseURL = URL(string: normalized)
        auth = CredentialStore.read(for: normalized)
    }
    var connectionIdentity: APIConnectionIdentity? {
        guard let baseURL, let auth else { return nil }
        return APIConnectionIdentity(base: baseURL.absoluteString, userID: auth.userId)
    }
    func requireConnection(_ identity: APIConnectionIdentity?) throws {
        guard let identity, connectionIdentity == identity else { throw ReconstructionStudyError.changedServer }
    }
    func connect(to string: String) async throws -> String {
        let normalized = try Self.normalized(string)
        let candidate = URL(string: normalized)!
        var check = URLRequest(url: candidate.appendingPathComponent("health"))
        check.timeoutInterval = 8
        let (data, response) = try await session.data(for: check)
        try validate(data, response)
        struct Health: Decodable { let ok: Bool; let features: [String]? }
        let health = try JSONDecoder().decode(Health.self, from: data)
        guard health.ok else { throw APIError.invalidResponse }
        var credentials = CredentialStore.read(for: normalized)
        if credentials == nil {
            var request = URLRequest(url: candidate.appendingPathComponent("v1/auth/anonymous"))
            request.httpMethod = "POST"; request.httpBody = Data("{}".utf8)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let (responseData, response) = try await session.data(for: request)
            try validate(responseData, response)
            let result = try JSONDecoder().decode(AuthResponse.self, from: responseData)
            guard UUID(uuidString: result.userId) != nil, !result.token.isEmpty else { throw APIError.invalidResponse }
            try CredentialStore.write(result, for: normalized)
            credentials = result
        }
        baseURL = candidate; auth = credentials
        serverFeatures = Set(health.features ?? [])
        return normalized
    }
    private func request(path: String, method: String) throws -> URLRequest {
        guard let baseURL, let auth else { throw APIError.configuration("请先在首页连接测试服务器。") }
        guard path.hasPrefix("/"), !path.hasPrefix("//"), !path.contains("\\"),
              let url = URL(string: path, relativeTo: baseURL)?.absoluteURL,
              url.scheme == baseURL.scheme, url.host == baseURL.host, url.port == baseURL.port,
              url.user == nil, url.password == nil, url.fragment == nil else { throw APIError.invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(auth.token)", forHTTPHeaderField: "Authorization")
        return request
    }
    private func validate(_ data: Data, _ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            struct ErrorResponse: Decodable { struct Detail: Decodable { let message: String; let code: String? }; let error: Detail }
            let detail = try? JSONDecoder().decode(ErrorResponse.self, from: data).error
            if http.statusCode == 503 && detail?.code == "server_busy" { throw APIError.serverBusy }
            let message = detail?.message ?? "请求未成功，请稍后重试"
            throw APIError.server(http.statusCode, message)
        }
    }
    func get<T: Decodable>(_ path: String, as: T.Type = T.self) async throws -> T {
        let identity = connectionIdentity
        let request = try request(path: path, method: "GET")
        let (data, response) = try await session.data(for: request)
        try requireConnection(identity)
        try validate(data, response)
        return try JSONDecoder().decode(T.self, from: data)
    }
    func json<T: Decodable, B: Encodable>(_ path: String, method: String = "POST", body: B, as: T.Type = T.self) async throws -> T {
        let identity = connectionIdentity
        var request = try request(path: path, method: method)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await session.data(for: request)
        try requireConnection(identity)
        try validate(data, response)
        return try JSONDecoder().decode(T.self, from: data)
    }
    func upload<T: Decodable>(_ path: String, file: URL, mime: String, sha256: String? = nil,
                              as: T.Type = T.self) async throws -> T {
        let identity = connectionIdentity
        var request = try request(path: path, method: "PUT")
        request.timeoutInterval = 1800
        request.setValue(mime, forHTTPHeaderField: "Content-Type")
        if let sha256 { request.setValue(sha256, forHTTPHeaderField: "X-Content-SHA256") }
        let (data, response) = try await session.upload(for: request, fromFile: file)
        try requireConnection(identity)
        try validate(data, response)
        return try JSONDecoder().decode(T.self, from: data)
    }
    /// Resumable original-video upload with progress (see ResumableUpload.swift). Falls back to the
    /// single-request PUT when the server predates `/rgb-upload` and answers 404.
    func uploadCaptureVideo(capturePath: String, file: URL, mime: String, sha256: String,
                            sender: UploadBodySending,
                            progress: @escaping @MainActor @Sendable (Double) -> Void) async throws -> CaptureV2Status {
        let identity = connectionIdentity
        let size = (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value ?? 0
        guard size > 0 else { throw APIError.configuration("原片为空，无法上传。") }
        do {
            return try await resumableUpload(path: capturePath + "/rgb-upload", file: file, size: size, mime: mime, sha256: sha256,
                                             sender: sender, progress: progress)
        } catch APIError.server(404, _) {
            // Older server without resumable uploads: one request, no resume.
            try requireConnection(identity)
            let response: CaptureV2Envelope = try await upload(capturePath + "/rgb", file: file, mime: mime, sha256: sha256)
            return response.capture
        }
    }
    /// The capture's keyframe pack for the cloud 位姿版 (`/keyframes-upload`, same resumable protocol).
    func uploadKeyframePack(captureID: String, file: URL, sha256: String,
                            progress: @escaping @MainActor @Sendable (Double) -> Void) async throws -> CaptureV2Status {
        guard UUID(uuidString: captureID) != nil else { throw ReconstructionStudyError.invalidManifest }
        let size = (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value ?? 0
        guard size > 0 else { throw APIError.configuration("关键帧数据包为空。") }
        if serverFeatures.contains("keyframe-files") {
            return try await uploadIndividualKeyframes(captureID: captureID, file: file, sha256: sha256, progress: progress)
        }
        return try await resumableUpload(path: "/v2/captures/\(captureID)/keyframes-upload", file: file, size: size,
                                         mime: KeyframePack.mime, sha256: sha256, sender: BackgroundUploadSender.shared,
                                         progress: progress)
    }
    private func resumableUpload(path: String, file: URL, size: Int64, mime: String, sha256: String,
                                 sender: UploadBodySending,
                                 progress: @escaping @MainActor @Sendable (Double) -> Void) async throws -> CaptureV2Status {
        let identity = connectionIdentity
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("upload-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let declaration = RGBUploadDeclaration(sha256: sha256, byteSize: size, mime: mime)
        do {
            return try await ResumableUpload.run(byteSize: size,
                declare: { try await self.json(path, body: declaration) as RGBUploadEnvelope },
                send: { offset in
                    try self.requireConnection(identity)
                    // Copying the remainder of a large video happens off the main thread.
                    let body = try await Task.detached(priority: .userInitiated) {
                        try ResumableUpload.body(of: file, from: offset, in: scratch)
                    }.value
                    defer { if body != file { try? FileManager.default.removeItem(at: body) } }
                    var request = try self.request(path: path, method: "PATCH")
                    request.setValue(ResumableUpload.offsetContentType, forHTTPHeaderField: "Content-Type")
                    request.setValue(String(offset), forHTTPHeaderField: "Upload-Offset")
                    let (data, response) = try await sender.send(request, fromFile: body) { sent in
                        let fraction = min(1, Double(offset + sent) / Double(size))
                        Task { @MainActor in progress(fraction) }
                    }
                    try self.requireConnection(identity)
                    try self.validate(data, response)
                    return try JSONDecoder().decode(RGBUploadEnvelope.self, from: data)
                },
                pause: { stalls in
                    try await Task.sleep(nanoseconds: UInt64(min(30, 1 << min(stalls + 1, 5))) * 1_000_000_000)
                })
        }
    }
    func uploadData<T: Decodable>(_ path: String, data: Data, mime: String, sha256: String,
                                  as: T.Type = T.self) async throws -> T {
        let identity = connectionIdentity
        var request = try request(path: path, method: "PUT")
        request.timeoutInterval = 1800
        request.setValue(mime, forHTTPHeaderField: "Content-Type")
        request.setValue(sha256, forHTTPHeaderField: "X-Content-SHA256")
        let (responseData, response) = try await session.upload(for: request, from: data)
        try requireConnection(identity)
        try validate(responseData, response)
        return try JSONDecoder().decode(T.self, from: responseData)
    }
    func download(_ path: String, to destination: URL) async throws {
        let identity = connectionIdentity
        let request = try request(path: path, method: "GET")
        let (temporary, response) = try await session.download(for: request)
        try requireConnection(identity)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let data = (try? Data(contentsOf: temporary)) ?? Data()
            try validate(data, response)
            throw APIError.invalidResponse
        }
        if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
        try FileManager.default.moveItem(at: temporary, to: destination)
    }
    func delete(_ path: String) async throws {
        let identity = connectionIdentity
        let request = try request(path: path, method: "DELETE")
        let (data, response) = try await session.data(for: request)
        try requireConnection(identity)
        try validate(data, response)
    }
}

// MARK: - Private FF / SfM result studies (external RGB video; no capture reward)

private struct ReconstructionStudyList: Decodable { let studies: [ReconstructionStudy] }
private struct ReconstructionStudyEnvelope: Decodable { let study: ReconstructionStudy }

/// Study endpoints are same-origin private files, not arbitrary redirects. Keep
/// a malformed response from writing beyond the manifest's bounded file size.
private final class StudyDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let byteLimit: Int64
    init(byteLimit: Int) { self.byteLimit = Int64(byteLimit) }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {}
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > byteLimit || totalBytesExpectedToWrite > byteLimit { downloadTask.cancel() }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

extension APIClient {
    func reconstructionStudies() async throws -> [ReconstructionStudy] {
        try Task.checkCancellation()
        guard let originalBase = baseURL, let originalUser = auth?.userId else {
            throw ReconstructionStudyError.unavailable
        }
        let response: ReconstructionStudyList = try await get("/v2/reconstruction-studies")
        try Task.checkCancellation()
        try requireStudyConnection(base: originalBase, userID: originalUser)
        guard response.studies.count <= 500,
              Set(response.studies.map(\.id)).count == response.studies.count else {
            throw ReconstructionStudyError.invalidManifest
        }
        return try response.studies.map { try $0.validated() }
    }

    func prepareReconstruction(study: ReconstructionStudy,
                               variant: ReconstructionVariant) async throws -> PreparedReconstructionVariant {
        try Task.checkCancellation()
        _ = try study.validated()
        try variant.validate(studyID: study.id)
        guard study.variants.contains(variant), let originalBase = baseURL,
              let originalUser = auth?.userId else { throw ReconstructionStudyError.unavailable }

        // Re-check ownership and immutable lineage before using a list item or cache.
        let envelope: ReconstructionStudyEnvelope = try await get("/v2/reconstruction-studies/\(study.id)")
        let current = try envelope.study.validated()
        guard current.id == study.id, current.sourceVideoSha256 == study.sourceVideoSha256,
              current.variants.contains(variant) else { throw ReconstructionStudyError.invalidManifest }
        try Task.checkCancellation()
        try requireStudyConnection(base: originalBase, userID: originalUser)

        let cacheScope = CredentialStore.account(originalBase.absoluteString + "|" + originalUser)
        let directory = try await Task.detached(priority: .utility) {
            let support = try FileManager.default.url(for: .applicationSupportDirectory,
                in: .userDomainMask, appropriateFor: nil, create: true)
            var directory = support.appendingPathComponent("ReconstructionStudies", isDirectory: true)
                .appendingPathComponent(cacheScope, isDirectory: true)
                .appendingPathComponent(study.id, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            try directory.setResourceValues(values)
            return directory
        }.value
        try Task.checkCancellation()
        try requireStudyConnection(base: originalBase, userID: originalUser)

        let modelURL = directory.appendingPathComponent("\(variant.id)-\(variant.sha256).\(variant.format)")
        let cameraURL = directory.appendingPathComponent("\(variant.id)-\(variant.cameraSha256).cameras.json")
        try await checkedStudyDownload(variant.filePath, to: modelURL,
            byteSize: variant.byteSize, hash: variant.sha256, base: originalBase, userID: originalUser)
        try Task.checkCancellation()
        try requireStudyConnection(base: originalBase, userID: originalUser)
        try await checkedStudyDownload(variant.cameraPath, to: cameraURL,
            byteSize: variant.cameraByteSize, hash: variant.cameraSha256, base: originalBase, userID: originalUser)
        try Task.checkCancellation()
        try requireStudyConnection(base: originalBase, userID: originalUser)
        let cameras = try await Task.detached(priority: .userInitiated) {
            try Self.validateStudyModel(modelURL, variant: variant)
            let data = try Data(contentsOf: cameraURL) // Manifest caps this at 4 MiB.
            return try JSONDecoder().decode(SceneCameraPath.self, from: data).validated()
        }.value
        try Task.checkCancellation()
        try requireStudyConnection(base: originalBase, userID: originalUser)
        return PreparedReconstructionVariant(variant: variant, modelURL: modelURL, cameras: cameras)
    }

    private func requireStudyConnection(base: URL, userID: String) throws {
        guard baseURL == base, auth?.userId == userID else { throw ReconstructionStudyError.changedServer }
    }

    private func checkedStudyDownload(_ path: String, to destination: URL,
                                      byteSize: Int, hash: String, base: URL, userID: String) async throws {
        try Task.checkCancellation()
        try requireStudyConnection(base: base, userID: userID)
        if FileManager.default.fileExists(atPath: destination.path) {
            let valid = try await Task.detached(priority: .utility) {
                try Self.validStudyFile(destination, byteSize: byteSize, hash: hash)
            }.value
            try Task.checkCancellation()
            try requireStudyConnection(base: base, userID: userID)
            if valid { return }
            try FileManager.default.removeItem(at: destination)
        }
        let staging = destination.deletingLastPathComponent()
            .appendingPathComponent(UUID().uuidString + ".download")
        defer { try? FileManager.default.removeItem(at: staging) }
        try Task.checkCancellation()
        try requireStudyConnection(base: base, userID: userID)
        let request = try request(path: path, method: "GET")
        let (temporary, response) = try await session.download(for: request,
            delegate: StudyDownloadDelegate(byteLimit: byteSize))
        defer { try? FileManager.default.removeItem(at: temporary) }
        try Task.checkCancellation()
        try requireStudyConnection(base: base, userID: userID)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              response.url == request.url,
              response.expectedContentLength == -1 || response.expectedContentLength == Int64(byteSize) else {
            throw ReconstructionStudyError.unavailable
        }
        try FileManager.default.moveItem(at: temporary, to: staging)
        try Task.checkCancellation()
        let valid = try await Task.detached(priority: .utility) {
            try Self.validStudyFile(staging, byteSize: byteSize, hash: hash)
        }.value
        guard valid else { throw ReconstructionStudyError.hashMismatch }
        try Task.checkCancellation()
        // Files use immutable hashes. Concurrent opens may have installed the same file.
        if FileManager.default.fileExists(atPath: destination.path) {
            let otherValid = try await Task.detached(priority: .utility) {
                try Self.validStudyFile(destination, byteSize: byteSize, hash: hash)
            }.value
            guard otherValid else { throw ReconstructionStudyError.hashMismatch }
        } else {
            try FileManager.default.moveItem(at: staging, to: destination)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                                                 ofItemAtPath: destination.path)
        }
    }

    nonisolated private static func validStudyFile(_ url: URL, byteSize: Int, hash: String) throws -> Bool {
        guard try url.resourceValues(forKeys: [.fileSizeKey]).fileSize == byteSize else { return false }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var digest = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            try Task.checkCancellation()
            digest.update(data: data)
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined() == hash
    }

    nonisolated private static func validateStudyModel(_ url: URL, variant: ReconstructionVariant) throws {
        if url.pathExtension == "spz", variant.mobile != nil { return } // Server-validated immutable derivative; SplatIO validates while loading.
        if variant.format == "splat" { return } // Exact 32-byte record count was validated above.
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let prefix = try handle.read(upToCount: 65_536) ?? Data()
        guard let end = prefix.range(of: Data("end_header\n".utf8)) else {
            throw ReconstructionStudyError.invalidModel
        }
        let header = String(decoding: prefix[..<end.upperBound], as: UTF8.self)
        let lines = header.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard lines.first == "ply", lines.contains("format binary_little_endian 1.0"),
              lines.contains("element vertex \(variant.pointCount)"),
              (0..<45).allSatisfy({ lines.contains("property float f_rest_\($0)") }),
              ["x", "y", "z", "opacity", "f_dc_0", "f_dc_1", "f_dc_2", "scale_0", "scale_1", "scale_2",
               "rot_0", "rot_1", "rot_2", "rot_3"].allSatisfy({ lines.contains("property float \($0)") }) else {
            throw ReconstructionStudyError.invalidModel
        }
    }
}

// MARK: - Native capture dual reconstruction (separate from external studies)

extension APIClient: NativeReconstructionTransport {
    var supportsArkitTraining: Bool { serverFeatures.contains("arkit-prior-training") }
    var supportsSfMKeyframes: Bool { serverFeatures.contains("sfm-subject-keyframes") }
    var supportsArkitKeyframes: Bool { serverFeatures.contains("arkit-keyframes") }
    var supportsVersionSelection: Bool { serverFeatures.contains("reconstruction-selection") }
    func uploadKeyframes(captureID: String, pack: URL, sha256: String,
                         progress: @escaping @MainActor @Sendable (Double) -> Void) async throws -> String {
        let capture = try await uploadKeyframePack(captureID: captureID, file: pack, sha256: sha256, progress: progress)
        guard capture.id == captureID, let stored = capture.keyframes?.sha256 else { throw ReconstructionStudyError.invalidManifest }
        return stored
    }
    func nativeReconstruction(captureID: String) async throws -> NativeReconstruction? {
        guard UUID(uuidString: captureID) != nil else { throw ReconstructionStudyError.invalidManifest }
        let envelope: NativeReconstructionEnvelope = try await get("/v2/captures/\(captureID)/reconstructions")
        return envelope.reconstruction
    }
    func startNativeReconstruction(captureID: String, roles: [String]?) async throws -> NativeReconstruction {
        try await startNativeReconstruction(captureID: captureID, roles: roles, keyframesSha256: nil)
    }
    func startNativeReconstruction(captureID: String, roles: [String]?, keyframesSha256: String?) async throws -> NativeReconstruction {
        guard UUID(uuidString: captureID) != nil else { throw ReconstructionStudyError.invalidManifest }
        let envelope: NativeReconstructionEnvelope = try await json("/v2/captures/\(captureID)/reconstructions",
                                                                    body: NativeDualConsent(roles: roles, keyframesSha256: keyframesSha256))
        guard let value = envelope.reconstruction else { throw ReconstructionStudyError.invalidManifest }
        return value
    }
    func retryNativeReconstruction(_ intent: NativeReconstructionRetry) async throws -> NativeReconstruction {
        guard [intent.id, intent.failedTaskId, intent.reconstructionID].allSatisfy({ UUID(uuidString: $0) != nil }) else {
            throw ReconstructionStudyError.invalidManifest
        }
        let envelope: NativeReconstructionEnvelope = try await json("/v2/video-reconstructions/\(intent.reconstructionID)/retry",
            body: NativeRetryRequest(failedTaskId: intent.failedTaskId, id: intent.id, keyframesSha256: intent.keyframesSha256))
        guard let value = envelope.reconstruction else { throw ReconstructionStudyError.invalidManifest }
        return value
    }
    func startArkitTraining(_ intent: NativeArkitTrainingIntent) async throws -> NativeReconstruction {
        guard UUID(uuidString: intent.id) != nil, UUID(uuidString: intent.source.captureID) != nil else {
            throw ReconstructionStudyError.invalidManifest
        }
        let envelope: NativeReconstructionEnvelope = try await json(
            "/v2/captures/\(intent.source.captureID)/reconstructions/arkit-prior",
            body: NativeArkitTrainingRequest(id: intent.id, keyframesSha256: intent.keyframesSha256))
        guard let value = envelope.reconstruction, value.id == intent.reconstructionID else {
            throw ReconstructionStudyError.invalidManifest
        }
        return value
    }
    func prepareNativeReconstruction(_ reconstruction: NativeReconstruction, variant: ReconstructionVariant,
                                     source: NativeReconstructionSource) async throws -> PreparedReconstructionVariant {
        _ = try reconstruction.validated(source: source)
        try variant.validate(reconstructionID: reconstruction.id)
        guard reconstruction.readyResults.contains(variant), let identity = connectionIdentity,
              let base = baseURL else { throw ReconstructionStudyError.unavailable }
        guard let current = try await nativeReconstruction(captureID: source.captureID) else {
            throw ReconstructionStudyError.unavailable
        }
        _ = try current.validated(source: source, previous: reconstruction)
        guard current.readyResults.contains(variant) else { throw ReconstructionStudyError.invalidManifest }
        try requireConnection(identity); try Task.checkCancellation()
        let directory = try await Task.detached(priority: .utility) {
            let support = try FileManager.default.url(for: .applicationSupportDirectory,
                in: .userDomainMask, appropriateFor: nil, create: true)
            var folder = support.appendingPathComponent("NativeReconstructionModels", isDirectory: true)
                .appendingPathComponent(identity.cacheKey, isDirectory: true)
                .appendingPathComponent(reconstruction.id, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            try folder.setResourceValues(values)
            return folder
        }.value
        try requireConnection(identity); try Task.checkCancellation()
        let model = directory.appendingPathComponent("\(variant.id)-\(variant.downloadSHA256).\(variant.downloadFormat)")
        let camera = directory.appendingPathComponent("\(variant.id)-\(variant.cameraSha256).cameras.json")
        try await checkedStudyDownload(variant.downloadPath, to: model, byteSize: variant.downloadByteSize,
            hash: variant.downloadSHA256, base: base, userID: identity.userID)
        try requireConnection(identity); try Task.checkCancellation()
        try await checkedStudyDownload(variant.cameraPath, to: camera, byteSize: variant.cameraByteSize,
            hash: variant.cameraSha256, base: base, userID: identity.userID)
        let cameras = try await Task.detached(priority: .userInitiated) {
            try Self.validateStudyModel(model, variant: variant)
            return try JSONDecoder().decode(SceneCameraPath.self, from: Data(contentsOf: camera)).validated()
        }.value
        try requireConnection(identity); try Task.checkCancellation()
        return PreparedReconstructionVariant(variant: variant, modelURL: model, cameras: cameras)
    }

    func cachedNativeReconstruction(_ reconstruction: NativeReconstruction, variant: ReconstructionVariant,
                                    identity: APIConnectionIdentity) async -> PreparedReconstructionVariant? {
        guard reconstruction.readyResults.contains(variant) else { return nil }
        let key = identity.cacheKey, reconstructionID = reconstruction.id
        return await Task.detached(priority: .userInitiated) { () -> PreparedReconstructionVariant? in
            guard let support = try? FileManager.default.url(for: .applicationSupportDirectory,
                in: .userDomainMask, appropriateFor: nil, create: false) else { return nil }
            let folder = support.appendingPathComponent("NativeReconstructionModels", isDirectory: true)
                .appendingPathComponent(key, isDirectory: true)
                .appendingPathComponent(reconstructionID, isDirectory: true)
            let model = folder.appendingPathComponent("\(variant.id)-\(variant.downloadSHA256).\(variant.downloadFormat)")
            let camera = folder.appendingPathComponent("\(variant.id)-\(variant.cameraSha256).cameras.json")
            guard (try? Self.validStudyFile(model, byteSize: variant.downloadByteSize, hash: variant.downloadSHA256)) == true,
                  (try? Self.validStudyFile(camera, byteSize: variant.cameraByteSize, hash: variant.cameraSha256)) == true,
                  (try? Self.validateStudyModel(model, variant: variant)) != nil,
                  let data = try? Data(contentsOf: camera),
                  let cameras = try? JSONDecoder().decode(SceneCameraPath.self, from: data).validated() else {
                return nil
            }
            return PreparedReconstructionVariant(variant: variant, modelURL: model, cameras: cameras)
        }.value
    }
}

// MARK: - Native capture package upload (v2)

struct CaptureV2Status: Codable, Identifiable, Sendable {
    struct Part: Codable, Sendable {
        let sha256: String
        let byteSize: Int
        let mime: String?
    }
    struct Receipt: Codable, Sendable {
        let captureReceiptId: String
        let verifiedAt: String
        let scope: String
        let frameCount: Int?
        let depthFrameCount: Int?
        let depthStatus: String?
        let decodeVerified: Bool?
    }

    let id: String
    let environment: String
    let consentVersion: String
    let status: String
    let rgb: Part?
    let metadata: Part?
    let receipt: Receipt?
    /// The keyframe pack stored for the cloud 位姿版, when one was uploaded.
    var keyframes: KeyframesPart? = nil

    struct KeyframesPart: Codable, Sendable {
        let sha256: String
        let byteSize: Int
        let frameCount: Int
        let masks: Bool
    }

    var verifiedReceipt: Receipt? {
        guard status == "rgb_metadata_verified", let receipt,
              receipt.scope == "rgb_metadata_verified",
              UUID(uuidString: receipt.captureReceiptId) != nil, UUID(uuidString: id) != nil,
              let rgb, let metadata, rgb.byteSize > 0, metadata.byteSize > 0,
              ReconstructionStudy.isSHA256(rgb.sha256), ReconstructionStudy.isSHA256(metadata.sha256) else { return nil }
        return receipt
    }
}

private struct CaptureV2Envelope: Decodable { let capture: CaptureV2Status }
private struct CaptureV2List: Decodable { let captures: [CaptureV2Status] }
private struct CaptureV2Create: Encodable {
    let captureId: String
    let environment: String
    let consentVersion: String
}
private struct CaptureV2Empty: Encodable {}

private struct CaptureUploadIntent: Codable {
    let captureId: String
    let backendBase: String
    let ownerID: String?
    let environment: String
    let consentVersion: String
    let videoSHA256: String
    let metadataSHA256: String
}

private struct PreparedNativeCapture: Sendable {
    let id: String
    let videoURL: URL
    let videoSHA256: String
    let metadataData: Data
    let metadataSHA256: String
}

private enum NativeUploadError: LocalizedError {
    case invalidPackage(String)
    case changedBackend
    case changedBytes
    case serverMismatch
    case notConnected
    case deleteNeedsServer

    var errorDescription: String? {
        switch self {
        case .invalidPackage(let message): return "扫描文件无法提交：\(message)"
        case .changedBackend: return "这次扫描已绑定首次提交的服务器。请连接原服务器；更换服务需要先核对账号与草稿归属。"
        case .changedBytes: return "本机原片或元数据与首次提交时不同。已保留原件，请先检查文件。"
        case .serverMismatch: return "服务器记录与本机扫描的编号或哈希不一致；已停止提交以保护原件。"
        case .notConnected: return "请先连接设置中的测试服务器。"
        case .deleteNeedsServer: return "这次扫描上传过。请先连接上传时的服务器，才能把服务器上的原片和 3DGS 一起删除。"
        }
    }
}

@MainActor
final class CaptureV2UploadStore: ObservableObject {
    @Published var backendInput: String {
        didSet { if !isConnected { reconstructions.suspend() } }
    }
    @Published private(set) var connectionLabel = "尚未连接"
    @Published private(set) var statuses: [String: CaptureV2Status] = [:]
    @Published private(set) var activeCaptureID: String?
    @Published private(set) var activePhase = ""
    @Published private(set) var isBusy = false
    @Published var errorMessage: String?

    var imageAPI: APIClient { api }
    private let api: APIClient
    let reconstructions: NativeReconstructionStore
    private var connectedBase: String?
    private static let backendKey = "PocketWorld.v2.backend"
    private static let consentVersion = "capture-evaluation-2026-11-02-v1"

    init(configuration: URLSessionConfiguration = .default) {
        let client = APIClient(configuration: configuration)
        api = client; reconstructions = NativeReconstructionStore(transport: client)
        #if DEBUG
        let defaultBase = "http://9.135.79.113:8787"
        #else
        let defaultBase = ""
        #endif
        let previous = UserDefaults.standard.string(forKey: Self.backendKey) ?? defaultBase
        backendInput = previous
        if !previous.isEmpty {
            api.restore(base: previous)
            if let identity = api.connectionIdentity {
                statuses = Self.loadStatusCache(identity: identity)
                reconstructions.configure(identity: identity, captures: Array(statuses.values), connected: false)
            }
            connectionLabel = "上次地址 · 请点连接核对"
        }
    }

    var isConnected: Bool {
        guard let connectedBase else { return false }
        return (try? APIClient.normalized(backendInput)) == connectedBase
    }
    var connectionDisplay: String {
        if connectedBase != nil && !isConnected { return "地址已更改 · 请重新连接" }
        return connectionLabel
    }
    var connectedDestination: String? { isConnected ? connectedBase : nil }
    var reconstructionAccountID: String? { isConnected ? api.auth?.userId : nil }
    func reconstructionStudies() async throws -> [ReconstructionStudy] {
        guard isConnected, api.baseURL?.absoluteString == connectedBase else { throw NativeUploadError.notConnected }
        return try await api.reconstructionStudies()
    }
    func prepareReconstruction(study: ReconstructionStudy,
                               variant: ReconstructionVariant) async throws -> PreparedReconstructionVariant {
        guard isConnected, api.baseURL?.absoluteString == connectedBase else { throw NativeUploadError.notConnected }
        return try await api.prepareReconstruction(study: study, variant: variant)
    }
    var verifiedReceiptCount: Int {
        Self.verifiedReceiptCount(captures: Array(statuses.values))
    }
    nonisolated static func verifiedReceiptCount(captures: [CaptureV2Status]) -> Int {
        Set(captures.compactMap { $0.verifiedReceipt?.captureReceiptId }).count
    }
    func status(for id: String) -> CaptureV2Status? { statuses[id] }
    func firstEnvironment(for id: String) -> String? { try? Self.readIntent(id: id)?.environment }
    func statusLabel(for id: String) -> String {
        guard let status = statuses[id] else { return "本机已保存 · 未上传" }
        if let receipt = status.verifiedReceipt {
            let prefix = isConnected ? "原片已上传并核验" : "上次上传已核验"
            return receipt.depthStatus == "pending_upload"
                ? "\(prefix) · 深度留在手机"
                : prefix
        }
        if status.rgb != nil || status.metadata != nil { return "上传未完成 · 可重试" }
        return "服务器草稿 · 可提交"
    }

    /// One-tap delete of a scan. When it was ever submitted, the server copy goes first
    /// (original video, metadata and every 3DGS result, `DELETE /v2/captures/:id`), then
    /// the 3DGS files downloaded to this phone; the local folder (video, depth, training
    /// package) is removed last, so a failed server request leaves everything retryable.
    func deleteScan(folderURL: URL, preserveLinkedImages: Bool = false) async -> Bool {
        let id = folderURL.deletingPathExtension().lastPathComponent
        guard !isBusy else { return false }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            let root = try ARScanRecorder.packagesDirectory().standardizedFileURL.resolvingSymlinksInPath()
            let folder = folderURL.standardizedFileURL.resolvingSymlinksInPath()
            guard folder.pathExtension == "scan", UUID(uuidString: id) != nil,
                  folder.deletingLastPathComponent() == root else {
                throw NativeUploadError.invalidPackage("文件不在应用扫描目录内。")
            }
            let intent = try? Self.readIntent(id: id)
            let linkedImages = ImageGenerationStore(api: api)
            let linked = linkedImages.entries.filter { $0.scanSource?.captureID == id }
            guard !linked.contains(where: { $0.image.pending }) else {
                throw APIError.configuration("关联的单图作品正在生成，请完成或取消后再删除。")
            }
            if let intent, let identity = api.connectionIdentity,
               intent.backendBase != identity.base || (intent.ownerID != nil && intent.ownerID != identity.userID) {
                throw NativeUploadError.changedBackend
            }
            // Coverage cleanup concerns scans only. Image works own an independent
            // JPEG and result; keep their source lineage even when the scan is gone.
            if !preserveLinkedImages && !linked.isEmpty {
                guard isConnected else { throw NativeUploadError.deleteNeedsServer }
                for entry in linked {
                    guard await linkedImages.delete(entry.id) else {
                        throw APIError.configuration(linkedImages.error ?? "关联的单图结果未删除，原始素材仍保留。")
                    }
                }
            }
            if statuses[id] != nil || intent != nil {
                guard isConnected, let base = connectedBase, let identity = api.connectionIdentity else {
                    throw NativeUploadError.deleteNeedsServer
                }
                if let intent, intent.backendBase != base || (intent.ownerID != nil && intent.ownerID != identity.userID) {
                    throw NativeUploadError.changedBackend
                }
                do { try await api.delete("/v2/captures/" + id) }
                catch APIError.server(let code, _) where code == 404 { /* never created or already deleted */ }
                try api.requireConnection(identity)
                statuses[id] = nil
                persistStatusCache(identity: identity)
                reconstructions.forget(captureID: id)
                if let url = try? Self.intentURL(id: id) { try? FileManager.default.removeItem(at: url) }
            }
            await OnDeviceTrainingStore.shared.cancelIfTraining(captureID: id)
            try FileManager.default.removeItem(at: folder)
            CaptureEnvironmentMemory.clear(captureID: id)
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func connect() async {
        guard !isBusy else { return }
        isBusy = true
        errorMessage = nil
        connectionLabel = "正在连接"
        defer { isBusy = false }
        do {
            let candidate = backendInput.trimmingCharacters(in: .whitespacesAndNewlines)
            let previousIdentity = api.connectionIdentity
            let base = try await api.connect(to: candidate)
            if let identity = api.connectionIdentity, identity != previousIdentity {
                statuses = Self.loadStatusCache(identity: identity)
                reconstructions.configure(identity: identity, captures: Array(statuses.values), connected: false)
            }
            let list: CaptureV2List = try await api.get("/v2/captures")
            guard let identity = api.connectionIdentity,
                  Set(list.captures.map(\.id)).count == list.captures.count else { throw APIError.invalidResponse }
            connectedBase = base
            backendInput = base
            statuses = Dictionary(uniqueKeysWithValues: list.captures.map { ($0.id, $0) })
            UserDefaults.standard.set(base, forKey: Self.backendKey)
            persistStatusCache(identity: identity)
            reconstructions.configure(identity: identity, captures: list.captures, connected: true)
            connectionLabel = "已连接 · 可上传本机扫描"
        } catch {
            connectedBase = nil
            reconstructions.suspend()
            connectionLabel = "连接失败 · 原片仍在本机"
            errorMessage = error.localizedDescription
        }
    }

    func upload(packageURL: URL, selectedEnvironment: String) async {
        guard !isBusy else { return }
        guard isConnected, let base = connectedBase, let identity = api.connectionIdentity else {
            errorMessage = NativeUploadError.notConnected.localizedDescription
            return
        }
        isBusy = true
        errorMessage = nil
        activeCaptureID = packageURL.deletingPathExtension().lastPathComponent
        activePhase = "正在核对本机原件"
        defer {
            isBusy = false
            activeCaptureID = nil
        }
        do {
            let prepared = try await Task.detached(priority: .userInitiated) {
                try Self.prepare(packageURL: packageURL)
            }.value
            try api.requireConnection(identity)
            let intent = try Self.persistedIntent(for: prepared, base: base, ownerID: identity.userID,
                selectedEnvironment: selectedEnvironment)
            activePhase = "正在创建扫描记录"
            let create: CaptureV2Envelope = try await api.json("/v2/captures",
                body: CaptureV2Create(captureId: prepared.id, environment: intent.environment,
                    consentVersion: intent.consentVersion))
            var remote = try record(create.capture, matching: prepared, identity: identity)
            let path = "/v2/captures/" + prepared.id

            if remote.verifiedReceipt == nil {
                if remote.rgb == nil {
                    activePhase = "正在上传原始视频"
                    // Resumable: a dropped connection or a locked screen continues from the last byte
                    // the server holds; the background session keeps sending while suspended.
                    let capture = try await api.uploadCaptureVideo(capturePath: path, file: prepared.videoURL,
                        mime: "video/quicktime", sha256: prepared.videoSHA256,
                        sender: BackgroundUploadSender.shared) { [weak self] fraction in
                            let phase = "正在上传原始视频 \(Int(fraction * 100))% · 中断后从断点继续"
                            if self?.activePhase != phase { self?.activePhase = phase }
                        }
                    remote = try record(capture, matching: prepared, identity: identity)
                }
                if remote.metadata == nil {
                    activePhase = "正在上传逐帧相机信息"
                    let response: CaptureV2Envelope = try await api.uploadData(path + "/metadata",
                        data: prepared.metadataData, mime: "application/json",
                        sha256: prepared.metadataSHA256)
                    remote = try record(response.capture, matching: prepared, identity: identity)
                }
                activePhase = "正在等待服务器核验"
                let response: CaptureV2Envelope = try await api.json(path + "/complete",
                    body: CaptureV2Empty())
                remote = try record(response.capture, matching: prepared, identity: identity)
            }
            guard remote.verifiedReceipt != nil,
                  remote.rgb?.sha256 == prepared.videoSHA256,
                  remote.metadata?.sha256 == prepared.metadataSHA256 else {
                throw NativeUploadError.serverMismatch
            }
            activePhase = "原片与相机信息已核验"
            try api.requireConnection(identity)
            // Uploading only verifies the scan. No 3DGS starts here: the user picks each
            // version on the scan page (`NativeReconstructionStore.generate`).
            try reconstructions.registerVerified(remote)
        } catch {
            activePhase = "提交未完成 · 本机原件已保留"
            errorMessage = error.localizedDescription
        }
    }

    private func record(_ status: CaptureV2Status, matching prepared: PreparedNativeCapture,
                        identity: APIConnectionIdentity) throws -> CaptureV2Status {
        try api.requireConnection(identity)
        guard connectedBase == identity.base, isConnected else { throw NativeUploadError.changedBackend }
        guard status.id == prepared.id,
              status.rgb == nil || status.rgb?.sha256 == prepared.videoSHA256,
              status.metadata == nil || status.metadata?.sha256 == prepared.metadataSHA256 else {
            throw NativeUploadError.serverMismatch
        }
        statuses[status.id] = status
        persistStatusCache(identity: identity)
        return status
    }

    private static func cacheURL(identity: APIConnectionIdentity) throws -> URL {
        let support = try FileManager.default.url(for: .applicationSupportDirectory,
            in: .userDomainMask, appropriateFor: nil, create: true)
        return support.appendingPathComponent("capture-status-" + identity.cacheKey + ".json")
    }
    private static func loadStatusCache(identity: APIConnectionIdentity) -> [String: CaptureV2Status] {
        guard let url = try? cacheURL(identity: identity),
              let data = try? Data(contentsOf: url),
              let values = try? JSONDecoder().decode([CaptureV2Status].self, from: data) else { return [:] }
        return Dictionary(values.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }
    private func persistStatusCache(identity: APIConnectionIdentity) {
        do {
            let url = try Self.cacheURL(identity: identity)
            let data = try JSONEncoder().encode(Array(statuses.values))
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            // The server remains authoritative. A new connection can restore its receipts.
            errorMessage = "服务器已接收操作，但本机未保存状态缓存：\(error.localizedDescription)"
        }
    }

    private static func intentURL(id: String) throws -> URL {
        let support = try FileManager.default.url(for: .applicationSupportDirectory,
            in: .userDomainMask, appropriateFor: nil, create: true)
        let directory = support.appendingPathComponent("CaptureUploadIntents", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(id + ".json")
    }
    private static func readIntent(id: String) throws -> CaptureUploadIntent? {
        let url = try intentURL(id: id)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(CaptureUploadIntent.self, from: Data(contentsOf: url))
    }
    private static func persistedIntent(for capture: PreparedNativeCapture, base: String, ownerID: String,
                                        selectedEnvironment: String) throws -> CaptureUploadIntent {
        if let existing = try readIntent(id: capture.id) {
            guard existing.backendBase == base, existing.ownerID == ownerID else { throw NativeUploadError.changedBackend }
            guard existing.videoSHA256 == capture.videoSHA256 &&
                  existing.metadataSHA256 == capture.metadataSHA256 else { throw NativeUploadError.changedBytes }
            return existing
        }
        guard ["indoor", "outdoor", "unknown"].contains(selectedEnvironment) else {
            throw NativeUploadError.invalidPackage("请选择室内、室外或未知场景。")
        }
        let intent = CaptureUploadIntent(captureId: capture.id, backendBase: base, ownerID: ownerID,
            environment: selectedEnvironment, consentVersion: consentVersion,
            videoSHA256: capture.videoSHA256, metadataSHA256: capture.metadataSHA256)
        try JSONEncoder().encode(intent).write(to: intentURL(id: capture.id),
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        return intent
    }

    nonisolated private static func prepare(packageURL: URL) throws -> PreparedNativeCapture {
        let manager = FileManager.default
        let support = try manager.url(for: .applicationSupportDirectory,
            in: .userDomainMask, appropriateFor: nil, create: true)
        let root = support.appendingPathComponent("ScanPackages", isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath()
        let folder = packageURL.standardizedFileURL.resolvingSymlinksInPath()
        guard folder.pathExtension == "scan",
              folder.deletingLastPathComponent() == root else {
            throw NativeUploadError.invalidPackage("文件不在应用扫描目录内。")
        }
        let manifestURL = folder.appendingPathComponent("manifest.json")
        let manifestData = try Data(contentsOf: manifestURL)
        guard let manifest = try JSONSerialization.jsonObject(with: manifestData) as? [String: Any],
              let id = manifest["captureID"] as? String,
              UUID(uuidString: id) != nil,
              id == folder.deletingPathExtension().lastPathComponent,
              manifest["schemaVersion"] as? Int == 1,
              manifest["videoFile"] as? String == "video.mov",
              manifest["framesFile"] as? String == "frames.jsonl",
              let expectedVideoHash = manifest["videoSHA256"] as? String,
              let expectedFramesHash = manifest["framesSHA256"] as? String else {
            throw NativeUploadError.invalidPackage("清单格式或扫描编号无效。")
        }
        let videoURL = folder.appendingPathComponent("video.mov")
        let framesData = try Data(contentsOf: folder.appendingPathComponent("frames.jsonl"))
        guard sha256(framesData) == expectedFramesHash,
              try sha256(videoURL) == expectedVideoHash,
              let framesJSONL = String(data: framesData, encoding: .utf8) else {
            throw NativeUploadError.invalidPackage("视频或逐帧表的哈希不匹配。")
        }
        let metadataData = try JSONSerialization.data(withJSONObject:
            ["manifest": manifest, "framesJSONL": framesJSONL], options: [.sortedKeys])
        return PreparedNativeCapture(id: id, videoURL: videoURL,
            videoSHA256: expectedVideoHash, metadataData: metadataData,
            metadataSHA256: sha256(metadataData))
    }
    nonisolated private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    nonisolated private static func sha256(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var digest = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 1_048_576) ?? Data()
            if chunk.isEmpty { break }
            digest.update(data: chunk)
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
}


extension APIClient {
    /// Shared file upload used by single images and individual keyframe files. Cancellation
    /// stops this foreground request; the server retains the acknowledged prefix.
    func uploadPrivateFile(path: String, file: URL, mime: String, hash: String,
                           progress: @escaping @MainActor @Sendable (Double) -> Void) async throws {
        let identity = connectionIdentity
        let size = Int64(try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        guard size > 0 else { throw APIError.invalidResponse }
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let declaration = RGBUploadDeclaration(sha256: hash, byteSize: size, mime: mime)
        _ = try await ResumableUpload.transfer(byteSize: size, declare: {
            let reply: RGBUploadEnvelope = try await self.json(path, body: declaration)
            guard reply.upload?.sha256 == hash, reply.upload?.mime == mime else { throw ResumableUploadError.serverStateMismatch }
            return reply
        }, send: { offset in
            try self.requireConnection(identity)
            let body = try await Task.detached { try ResumableUpload.body(of: file, from: offset, in: scratch) }.value
            defer { if body != file { try? FileManager.default.removeItem(at: body) } }
            var request = try self.request(path: path, method: "PATCH")
            request.setValue(ResumableUpload.offsetContentType, forHTTPHeaderField: "Content-Type")
            request.setValue(String(offset), forHTTPHeaderField: "Upload-Offset")
            let (data, response) = try await self.session.upload(for: request, fromFile: body)
            try self.requireConnection(identity); try self.validate(data, response)
            let reply = try JSONDecoder().decode(RGBUploadEnvelope.self, from: data)
            progress(Double(reply.upload?.offset ?? offset) / Double(size))
            return reply
        }, pause: { stalls in try await Task.sleep(nanoseconds: UInt64(min(8, 1 << min(stalls, 3))) * 1_000_000_000) })
    }

    func prepareImageResult(_ value: ImageGeneration) async throws -> URL {
        try value.validate()
        guard let result = value.result, let identity = connectionIdentity, let baseURL else { throw ReconstructionStudyError.unavailable }
        let dir = try ImageGenerationStore.directory(identity: identity).appendingPathComponent(value.id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent(result.spz.sha256 + ".spz")
        // Hash-checked cached files open offline without making another request.
        if (try? Self.validStudyFile(file, byteSize: result.spz.byteSize, hash: result.spz.sha256)) == true { return file }
        try await checkedStudyDownload(result.spz.path, to: file, byteSize: result.spz.byteSize,
                                       hash: result.spz.sha256, base: baseURL, userID: identity.userID)
        return file
    }
}

extension APIClient {
    func originalNativeResult(_ variant: ReconstructionVariant, captureID: String) async throws -> URL {
        guard UUID(uuidString: captureID) != nil, let identity = connectionIdentity, let baseURL else { throw ReconstructionStudyError.unavailable }
        let folder = try ImageGenerationStore.directory(identity: identity).appendingPathComponent("OriginalExports")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent(variant.sha256 + "." + variant.format)
        try await checkedStudyDownload(variant.filePath, to: destination, byteSize: variant.byteSize, hash: variant.sha256, base: baseURL, userID: identity.userID)
        return destination
    }
}

extension APIClient {
    private func uploadIndividualKeyframes(captureID: String, file: URL, sha256: String,
                                          progress: @escaping @MainActor @Sendable (Double) -> Void) async throws -> CaptureV2Status {
        let identity = connectionIdentity
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("keyframe-files-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let split = try await Task.detached(priority: .utility) { try KeyframePack.split(file, into: folder) }.value
        guard split.index.captureId == captureID else { throw ReconstructionStudyError.invalidManifest }
        let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        struct Declaration: Encodable { let sha256: String; let byteSize: Int; let indexBase64: String }
        struct Declared: Decodable { let complete: Bool; let capture: CaptureV2Status }
        let route = "/v2/captures/\(captureID)/keyframe-files"
        let declared: Declared = try await json(route, body: Declaration(sha256: sha256, byteSize: size, indexBase64: split.indexBase64))
        if declared.complete { return declared.capture }
        var completed = 0
        for entry in split.index.files {
            try Task.checkCancellation(); try requireConnection(identity)
            let start = completed
            try await uploadPrivateFile(path: route + "/files/" + entry.sha256, file: folder.appendingPathComponent(entry.sha256),
                                        mime: "application/octet-stream", hash: entry.sha256) { fraction in
                progress(min(1, Double(start) / Double(size) + fraction * Double(entry.byteSize) / Double(size)))
            }
            completed += entry.byteSize
        }
        let result: CaptureV2Envelope = try await json(route + "/commit", body: CaptureV2Empty())
        progress(1);return result.capture
    }
}
