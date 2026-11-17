import BackgroundTasks
import Foundation
import UserNotifications
import Combine

struct NativeReconstructionEnvelope: Decodable { let reconstruction: NativeReconstruction? }
struct NativeDualConsent: Encodable {
    let consentVersion = "2026-11-03-native-dual-v1"
    /// The versions to start. Nil is left out of the request and means 快速预览 + 精细重建, the only
    /// request a server without version selection understands.
    var roles: [String]? = nil
    var keyframesSha256: String? = nil
}
struct NativeRetryRequest: Encodable { let failedTaskId: String; let id: String; var keyframesSha256: String? = nil }
struct NativeArkitTrainingRequest: Encodable {
    let consentVersion = NativeArkitTrainingIntent.consentVersion
    let id: String
    /// Train from this uploaded keyframe pack instead of video frames (omitted when absent).
    let keyframesSha256: String?
}

@MainActor
protocol NativeReconstructionTransport: AnyObject {
    var connectionIdentity: APIConnectionIdentity? { get }
    /// Whether the connected server offers cloud training from ARKit poses.
    var supportsArkitTraining: Bool { get }
    /// Whether the connected server can start one chosen version; older servers start
    /// 快速预览 and 精细重建 together whatever is asked.
    var supportsVersionSelection: Bool { get }
    func nativeReconstruction(captureID: String) async throws -> NativeReconstruction?
    /// Starts the listed versions and returns the reconstruction; an empty list only opens it.
    /// Nil asks for 快速预览 + 精细重建 the way servers without version selection expect.
    func startNativeReconstruction(captureID: String, roles: [String]?) async throws -> NativeReconstruction
    var supportsSfMKeyframes: Bool { get }
    func startNativeReconstruction(captureID: String, roles: [String]?, keyframesSha256: String?) async throws -> NativeReconstruction
    func retryNativeReconstruction(_ intent: NativeReconstructionRetry) async throws -> NativeReconstruction
    /// Adds the optional cloud ARKit pose-prior task (idempotent per reconstruction).
    func startArkitTraining(_ intent: NativeArkitTrainingIntent) async throws -> NativeReconstruction
    /// Whether the server trains the 位姿版 from the phone's keyframe pack.
    var supportsArkitKeyframes: Bool { get }
    /// Uploads (or resumes) the keyframe pack; returns the SHA-256 the server stored.
    func uploadKeyframes(captureID: String, pack: URL, sha256: String,
                         progress: @escaping @MainActor @Sendable (Double) -> Void) async throws -> String
    func prepareNativeReconstruction(_ reconstruction: NativeReconstruction, variant: ReconstructionVariant,
                                     source: NativeReconstructionSource) async throws -> PreparedReconstructionVariant
    /// A previously downloaded result whose files still match their SHA-256, or nil.
    func cachedNativeReconstruction(_ reconstruction: NativeReconstruction, variant: ReconstructionVariant,
                                    identity: APIConnectionIdentity) async -> PreparedReconstructionVariant?
}

extension NativeReconstructionTransport {
    var supportsSfMKeyframes: Bool { false }
    func startNativeReconstruction(captureID: String, roles: [String]?, keyframesSha256: String?) async throws -> NativeReconstruction {
        guard keyframesSha256 == nil else { throw ReconstructionStudyError.unavailable }
        return try await startNativeReconstruction(captureID: captureID, roles: roles)
    }
    var supportsArkitTraining: Bool { false }
    var supportsArkitKeyframes: Bool { false }
    var supportsVersionSelection: Bool { false }
    func uploadKeyframes(captureID: String, pack: URL, sha256: String,
                         progress: @escaping @MainActor @Sendable (Double) -> Void) async throws -> String {
        throw ReconstructionStudyError.unavailable
    }
    func startArkitTraining(_ intent: NativeArkitTrainingIntent) async throws -> NativeReconstruction {
        throw ReconstructionStudyError.unavailable
    }
    func cachedNativeReconstruction(_ reconstruction: NativeReconstruction, variant: ReconstructionVariant,
                                    identity: APIConnectionIdentity) async -> PreparedReconstructionVariant? { nil }
}

struct NativeReconstructionCache: Codable {
    var results: [String: NativeReconstruction] = [:]
    /// The versions the user chose by capture ID, kept until the server shows them.
    var versionRequests: [String: NativeVersionRequest] = [:]
    var retries: [String: NativeReconstructionRetry] = [:]
    /// Approved cloud ARKit trainings by capture ID, kept until the server shows the task.
    var arkitTrainings: [String: NativeArkitTrainingIntent] = [:]

    private enum CodingKeys: String, CodingKey { case results, versionRequests, acceptedStarts, retries, arkitTrainings }

    init() {}
    // Caches written before a field existed still load; missing fields start empty.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        results = try c.decodeIfPresent([String: NativeReconstruction].self, forKey: .results) ?? [:]
        versionRequests = try c.decodeIfPresent([String: NativeVersionRequest].self, forKey: .versionRequests) ?? [:]
        // Before version selection, a saved start always meant 快速预览 + 精细重建.
        let legacy = try c.decodeIfPresent([String: NativeReconstructionSource].self, forKey: .acceptedStarts) ?? [:]
        for (id, source) in legacy where versionRequests[id] == nil {
            versionRequests[id] = NativeVersionRequest(source: source, roles: NativeVersionRequest.videoRoles)
        }
        retries = try c.decodeIfPresent([String: NativeReconstructionRetry].self, forKey: .retries) ?? [:]
        arkitTrainings = try c.decodeIfPresent([String: NativeArkitTrainingIntent].self, forKey: .arkitTrainings) ?? [:]
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(results, forKey: .results)
        try c.encode(versionRequests, forKey: .versionRequests)
        try c.encode(retries, forKey: .retries)
        try c.encode(arkitTrainings, forKey: .arkitTrainings)
    }
}

@MainActor
protocol NativeReconstructionPersistence {
    func load(identity: APIConnectionIdentity) throws -> NativeReconstructionCache
    func save(_ cache: NativeReconstructionCache, identity: APIConnectionIdentity) throws
}

private struct NativeReconstructionDisk: NativeReconstructionPersistence {
    private func file(identity: APIConnectionIdentity) throws -> URL {
        let support = try FileManager.default.url(for: .applicationSupportDirectory,
            in: .userDomainMask, appropriateFor: nil, create: true)
        var directory = support.appendingPathComponent("NativeReconstructionState", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
        return directory.appendingPathComponent(identity.cacheKey + ".json")
    }
    func load(identity: APIConnectionIdentity) throws -> NativeReconstructionCache {
        let url = try file(identity: identity)
        guard FileManager.default.fileExists(atPath: url.path) else { return NativeReconstructionCache() }
        return try JSONDecoder().decode(NativeReconstructionCache.self, from: Data(contentsOf: url))
    }
    func save(_ cache: NativeReconstructionCache, identity: APIConnectionIdentity) throws {
        try JSONEncoder().encode(cache).write(to: file(identity: identity),
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}

/// One source, one independent task state per version the user chose. The choice and
/// retry UUIDs reach disk before any POST, so a lost response can only resume the same request.
@MainActor
final class NativeReconstructionStore: ObservableObject {
    @Published private(set) var results: [String: NativeReconstruction] = [:]
    @Published private(set) var errors: [String: String] = [:]
    @Published private(set) var busyCaptureIDs: Set<String> = []
    @Published private(set) var scopeKey: String?
    @Published private(set) var isConnected = false
    /// Result files verified and stored on this phone during this session.
    @Published private(set) var downloadedVariantIDs: Set<String> = []
    @Published private(set) var downloadErrors: [String: String] = [:]
    private let transport: NativeReconstructionTransport
    private let persistence: NativeReconstructionPersistence
    private var identity: APIConnectionIdentity?
    private var sources: [String: NativeReconstructionSource] = [:]
    private var cache = NativeReconstructionCache()
    private var generation = UUID()
    // Polls do not lock generation buttons. Revisions fence late GETs so they cannot
    // overwrite a version added while that read was in flight.
    private var refreshingCaptureIDs: Set<String> = []
    private var mutationRevision: [String: UInt64] = [:]
    private func beginMutation(_ captureID: String) {
        mutationRevision[captureID, default: 0] &+= 1
        busyCaptureIDs.insert(captureID)
    }

    init(transport: NativeReconstructionTransport, persistence: NativeReconstructionPersistence? = nil) {
        self.transport = transport; self.persistence = persistence ?? NativeReconstructionDisk()
    }
    func configure(identity: APIConnectionIdentity, captures: [CaptureV2Status], connected: Bool) {
        generation = UUID(); busyCaptureIDs = []; refreshingCaptureIDs = []; mutationRevision = [:]
        let changed = self.identity != identity
        self.identity = identity; scopeKey = identity.cacheKey; isConnected = connected
        sources = Dictionary(captures.compactMap { capture in
            (try? NativeReconstructionSource(status: capture)).map { (capture.id, $0) }
        }, uniquingKeysWith: { first, _ in first })
        if changed {
            cache = (try? persistence.load(identity: identity)) ?? NativeReconstructionCache()
            results = [:]; errors = [:]
        }
        var valid: [String: NativeReconstruction] = [:]
        for (id, result) in cache.results {
            guard let source = sources[id], let checked = try? result.validated(source: source) else { continue }
            valid[id] = checked
        }
        // An empty list while changing credentials is not evidence of deletion.
        // Keep the private cache until an authenticated capture list is known.
        if connected { cache.results = valid }
        results = valid
    }
    func suspend() { isConnected = false; generation = UUID(); busyCaptureIDs = []; refreshingCaptureIDs = []; mutationRevision = [:] }

    /// Forgets a deleted capture on this phone: task states, consent and retry records,
    /// and the downloaded 3DGS files.
    func forget(captureID: String) {
        mutationRevision[captureID, default: 0] &+= 1
        let reconstructionID = results[captureID]?.id ?? cache.results[captureID]?.id
        results[captureID] = nil
        errors[captureID] = nil
        sources[captureID] = nil
        cache.results[captureID] = nil
        cache.versionRequests[captureID] = nil
        cache.retries = cache.retries.filter { $0.value.source.captureID != captureID }
        cache.arkitTrainings[captureID] = nil
        try? persist()
        guard let reconstructionID, let key = scopeKey,
              let support = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                         appropriateFor: nil, create: false) else { return }
        let folder = support.appendingPathComponent("NativeReconstructionModels", isDirectory: true)
            .appendingPathComponent(key, isDirectory: true)
            .appendingPathComponent(reconstructionID, isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
    }
    func registerVerified(_ capture: CaptureV2Status) throws {
        let source = try NativeReconstructionSource(status: capture)
        if let previous = sources[capture.id], previous != source { throw ReconstructionStudyError.invalidManifest }
        sources[capture.id] = source
    }
    func result(captureID: String) -> NativeReconstruction? { results[captureID] }
    func isBusy(_ captureID: String) -> Bool { busyCaptureIDs.contains(captureID) }
    /// A chosen version whose request the server has not answered yet.
    func hasPendingVersionRequest(_ captureID: String) -> Bool { cache.versionRequests[captureID] != nil }
    func isVersionRequested(_ captureID: String, role: String) -> Bool {
        cache.versionRequests[captureID]?.roles.contains(role) == true
    }
    func hasPendingRetry(_ captureID: String) -> Bool { cache.retries.values.contains { $0.source.captureID == captureID } }
    func hasPendingArkitTraining(_ captureID: String) -> Bool { cache.arkitTrainings[captureID] != nil }
    /// Whether one version can be generated on its own. A server without this starts 快速预览 and
    /// 精细重建 together, so the app then only offers both.
    var canSelectVersions: Bool { isConnected && transport.supportsVersionSelection }
    var canTrainArkitInCloud: Bool { isConnected && transport.supportsArkitTraining }
    var trainsFromKeyframes: Bool { isConnected && transport.supportsArkitKeyframes }
    /// Upload progress of a keyframe pack, per capture, while it is being sent.
    @Published private(set) var keyframeUploadRoles: [String: String] = [:]
    @Published private(set) var keyframeUploadProgress: [String: Double] = [:]
    func isDownloaded(_ variantID: String) -> Bool { downloadedVariantIDs.contains(variantID) }

    /// Verified captures that still need a status check: running tasks, a saved
    /// retry, or a chosen version whose response was not received.
    func captureIDsNeedingSync() -> [String] {
        sources.keys.filter { id in
            results[id]?.isPending == true || hasPendingRetry(id) || hasPendingArkitTraining(id)
                || hasPendingVersionRequest(id)
        }.sorted()
    }

    /// Ready results not yet verified on this phone in this session.
    func readyVariantsToDownload() -> [(captureID: String, variant: ReconstructionVariant)] {
        results.keys.sorted().flatMap { id in
            (results[id]?.readyResults ?? []).filter { !downloadedVariantIDs.contains($0.id) }
                .map { (captureID: id, variant: $0) }
        }
    }

    /// Downloads and verifies a ready result (cached files are re-hashed, not refetched).
    @discardableResult
    func prefetch(captureID: String, variant: ReconstructionVariant) async -> Bool {
        do { _ = try await prepare(captureID: captureID, variant: variant); return true }
        catch { downloadErrors[variant.id] = "下载未完成，重试仅下载结果。"; return false }
    }

    private func context(_ captureID: String) throws -> (APIConnectionIdentity, NativeReconstructionSource, UUID) {
        guard isConnected, let identity, identity == transport.connectionIdentity,
              let source = sources[captureID] else { throw ReconstructionStudyError.changedServer }
        return (identity, source, generation)
    }
    private func require(_ context: (APIConnectionIdentity, NativeReconstructionSource, UUID)) throws {
        guard isConnected, identity == context.0, transport.connectionIdentity == context.0,
              generation == context.2, sources[context.1.captureID] == context.1 else {
            throw ReconstructionStudyError.changedServer
        }
        try Task.checkCancellation()
    }
    private func persist() throws {
        guard let identity else { throw ReconstructionStudyError.changedServer }
        try persistence.save(cache, identity: identity)
    }
    private func saveBeforeMutation(_ update: (inout NativeReconstructionCache) -> Void) throws {
        guard let identity else { throw ReconstructionStudyError.changedServer }
        var candidate = cache
        update(&candidate)
        try persistence.save(candidate, identity: identity)
        cache = candidate
    }
    private func record(_ value: NativeReconstruction,
                        context: (APIConnectionIdentity, NativeReconstructionSource, UUID)) throws {
        try require(context)
        let id = context.1.captureID
        let checked = try value.validated(source: context.1, previous: results[id])
        if let sha = cache.versionRequests[id]?.keyframesSha256, let task = checked.task(role: "refined"), task.input?.keyframes?.sha256 != sha {
            throw ReconstructionStudyError.invalidManifest
        }
        for intent in cache.retries.values where intent.source.captureID == id {
            if let sha = intent.keyframesSha256, let task = (checked.tasks + checked.previousAttempts).first(where: { $0.id == intent.id }), task.input?.keyframes?.sha256 != sha {
                throw ReconstructionStudyError.invalidManifest
            }
        }
        cache.results[id] = checked
        // A chosen version leaves the saved request once the server shows it.
        if let request = cache.versionRequests[id], request.roles.allSatisfy({ checked.task(role: $0) != nil }) {
            cache.versionRequests.removeValue(forKey: id)
        }
        for intent in Array(cache.retries.values) where intent.source.captureID == id {
            if checked.tasks.contains(where: { $0.id == intent.id })
                || checked.previousAttempts.contains(where: { $0.id == intent.id }) {
                cache.retries.removeValue(forKey: intent.failedTaskId)
            }
        }
        if let intent = cache.arkitTrainings[id],
           checked.tasks.contains(where: { $0.id == intent.id })
            || checked.previousAttempts.contains(where: { $0.id == intent.id }) {
            cache.arkitTrainings.removeValue(forKey: id)
        }
        results[id] = checked // Keep the accepted response even if local caching fails.
        try persist()
    }

    /// Starts the versions the user just chose (快速预览 / 精细重建) for a verified scan. Nothing
    /// starts without this call: uploading a scan only verifies it.
    func generate(captureID: String, roles: [String]) async {
        guard !isBusy(captureID) else { return }
        beginMutation(captureID); errors[captureID] = nil
        let operation = generation
        defer { if operation == generation { busyCaptureIDs.remove(captureID) } }
        do {
            try await request(roles: roles, context: try context(captureID))
        } catch is CancellationError {
        } catch { if operation == generation { errors[captureID] = error.localizedDescription } }
    }

    /// Saves the chosen versions (together with a choice still waiting for its answer), then
    /// asks the server for the ones it does not show yet. An empty choice opens the reconstruction.
    private func request(roles: [String],
                         context current: (APIConnectionIdentity, NativeReconstructionSource, UUID)) async throws {
        guard Set(roles).count == roles.count,
              roles.allSatisfy(NativeVersionRequest.videoRoles.contains) else {
            throw ReconstructionStudyError.invalidManifest
        }
        let id = current.1.captureID
        let saved = cache.versionRequests[id]
        if let saved, saved.source != current.1 { throw ReconstructionStudyError.invalidManifest }
        var missing = NativeVersionRequest(source: current.1, roles: (roles + (saved?.roles ?? []))
            .filter { results[id]?.task(role: $0) == nil })
        if results[id] != nil && missing.roles.isEmpty {
            if saved != nil { try saveBeforeMutation { $0.versionRequests[id] = nil } }
            return
        }
        guard transport.supportsVersionSelection || missing.roles == NativeVersionRequest.videoRoles else {
            throw APIError.configuration("这台服务器还不能单独选择版本，只能同时生成快速预览和精细重建。")
        }
        if missing.roles.contains("refined") {
            missing.keyframesSha256 = saved?.keyframesSha256
            if saved == nil { missing.keyframesSha256 = try await subjectKeyframes(captureID: id, context: current) }
        }
        try require(current)
        // A persisted user decision, never a timer, authorizes this POST.
        try saveBeforeMutation { $0.versionRequests[id] = missing }
        try await send(missing, context: current)
    }

    /// Posts a saved choice. A server without version selection is only ever sent the request for
    /// both versions, because it would start both whatever was chosen.
    private func send(_ request: NativeVersionRequest,
                      context current: (APIConnectionIdentity, NativeReconstructionSource, UUID)) async throws {
        let id = current.1.captureID
        guard request.keyframesSha256 == nil || transport.supportsSfMKeyframes else { throw ReconstructionStudyError.unavailable }
        let selectable = transport.supportsVersionSelection
        guard selectable || request.roles == NativeVersionRequest.videoRoles else {
            try saveBeforeMutation { $0.versionRequests[id] = nil }
            throw APIError.configuration("这台服务器不能单独生成所选版本，这次请求已取消。")
        }
        try require(current)
        let value: NativeReconstruction
        do { value = try await transport.startNativeReconstruction(captureID: id, roles: selectable ? request.roles : nil, keyframesSha256: request.keyframesSha256) }
        catch APIError.serverBusy {
            try saveBeforeMutation { $0.versionRequests[id] = nil }
            throw APIError.serverBusy
        }
        try record(value, context: current)
        guard request.roles.allSatisfy({ value.task(role: $0) != nil }) else {
            throw ReconstructionStudyError.invalidManifest
        }
    }

    // A busy response definitively rejects creation. Do not auto-submit it on the next poll.
    private func submitRetry(_ intent: NativeReconstructionRetry) async throws -> NativeReconstruction {
        guard intent.keyframesSha256 == nil || transport.supportsSfMKeyframes else { throw ReconstructionStudyError.unavailable }
        do { return try await transport.retryNativeReconstruction(intent) }
        catch APIError.serverBusy {
            try saveBeforeMutation { $0.retries[intent.failedTaskId] = nil }
            throw APIError.serverBusy
        }
    }
    private func submitArkit(_ intent: NativeArkitTrainingIntent) async throws -> NativeReconstruction {
        do { return try await transport.startArkitTraining(intent) }
        catch APIError.serverBusy {
            try saveBeforeMutation { $0.arkitTrainings[intent.source.captureID] = nil }
            throw APIError.serverBusy
        }
    }

    func refresh(captureID: String) async {
        guard !isBusy(captureID), isConnected, !refreshingCaptureIDs.contains(captureID) else { return }
        refreshingCaptureIDs.insert(captureID)
        let operation = generation
        let revision = mutationRevision[captureID, default: 0]
        var ownsMutation = false
        defer {
            if operation == generation {
                refreshingCaptureIDs.remove(captureID)
                if ownsMutation { busyCaptureIDs.remove(captureID) }
            }
        }
        do {
            let current = try context(captureID)
            let fetched = try await transport.nativeReconstruction(captureID: captureID)
            try require(current)
            guard revision == mutationRevision[captureID, default: 0], !isBusy(captureID) else { return }
            if let value = fetched {
                try record(value, context: current)
            } else {
                try require(current)
                // Never erase an already verified ready result on an absent or
                // stale response; an operator must resolve a lineage mismatch.
                guard results[captureID] == nil else { throw ReconstructionStudyError.invalidManifest }
            }
            // Mutating replay takes its own lock; the GET above never owns it.
            if cache.versionRequests[captureID] != nil || cache.arkitTrainings[captureID] != nil
                || cache.retries.values.contains(where: { $0.source.captureID == captureID }) {
                beginMutation(captureID); ownsMutation = true
            }
            // Only replay what the user already chose and this phone saved: the chosen versions
            // the server does not show yet, then retry and training UUIDs.
            if let request = cache.versionRequests[captureID] {
                guard request.source == current.1 else { throw ReconstructionStudyError.invalidManifest }
                try await send(request, context: current)
            }
            for intent in Array(cache.retries.values) where intent.source.captureID == captureID {
                try require(current)
                guard intent.source == current.1 else { throw ReconstructionStudyError.invalidManifest }
                let value = try await submitRetry(intent)
                try record(value, context: current)
            }
            if let intent = cache.arkitTrainings[captureID] {
                try require(current)
                guard intent.source == current.1 else { throw ReconstructionStudyError.invalidManifest }
                let value = try await submitArkit(intent)
                try record(value, context: current)
            }
            errors[captureID] = nil
        } catch is CancellationError {
        } catch {
            if operation == generation && (ownsMutation || revision == mutationRevision[captureID, default: 0]) {
                errors[captureID] = "连接中断或状态待核对：\(error.localizedDescription)"
            }
        }
    }

    func retry(captureID: String, failedTaskID: String) async {
        guard !isBusy(captureID) else { return }
        beginMutation(captureID); errors[captureID] = nil
        let operation = generation
        defer { if operation == generation { busyCaptureIDs.remove(captureID) } }
        do {
            let current = try context(captureID)
            guard let result = results[captureID], let task = result.tasks.first(where: { $0.id == failedTaskID }) else {
                throw ReconstructionStudyError.unavailable
            }
            var intent = try NativeReconstructionRetry.create(reconstruction: result, task: task,
                source: current.1, existing: cache.retries[failedTaskID])
            if cache.retries[failedTaskID] == nil && task.role == "refined" && task.input?.keyframes == nil {
                intent.keyframesSha256 = try await subjectKeyframes(captureID: captureID, context: current)
            }
            try require(current)
            try saveBeforeMutation { $0.retries[failedTaskID] = intent }
            try require(current)
            let value = try await submitRetry(intent)
            try record(value, context: current)
        } catch is CancellationError {
        } catch { if operation == generation { errors[captureID] = error.localizedDescription } }
    }

    private var keyframeOperations: [String: Task<Void, Never>] = [:]
    func beginArkitTraining(captureID: String) {
        guard keyframeOperations[captureID] == nil else { return }
        keyframeOperations[captureID] = Task { [weak self] in
            await self?.startArkitTraining(captureID: captureID)
            self?.keyframeOperations[captureID] = nil
        }
    }
    func pauseKeyframeUpload(captureID: String) {
        keyframeOperations[captureID]?.cancel()
        errors[captureID] = "关键帧上传已暂停，点生成可从断点继续。"
    }

    /// Cloud training from this scan's own ARKit poses, on the A10. The user's choice is saved
    /// before the request, so a lost response is retried with the same task ID.
    func startArkitTraining(captureID: String) async {
        guard !isBusy(captureID) else { return }
        beginMutation(captureID); errors[captureID] = nil
        let operation = generation
        defer { if operation == generation { busyCaptureIDs.remove(captureID) } }
        do {
            let current = try context(captureID)
            if results[captureID] == nil {
                // 位姿版 on its own: open the reconstruction without starting 快速预览 or 精细重建.
                guard transport.supportsVersionSelection else { throw ReconstructionStudyError.unavailable }
                try await request(roles: [], context: current)
            }
            guard let result = results[captureID] else { throw ReconstructionStudyError.unavailable }
            var keyframes = cache.arkitTrainings[captureID]?.keyframesSha256
            if cache.arkitTrainings[captureID] == nil && transport.supportsArkitKeyframes {
                keyframes = try await uploadKeyframes(captureID: captureID, context: current)
            }
            let intent = try NativeArkitTrainingIntent.create(reconstruction: result, source: current.1,
                                                              existing: cache.arkitTrainings[captureID],
                                                              keyframesSha256: keyframes)
            try saveBeforeMutation { $0.arkitTrainings[captureID] = intent }
            try require(current)
            let value = try await submitArkit(intent)
            try record(value, context: current)
        } catch is CancellationError {
        } catch { if operation == generation { errors[captureID] = error.localizedDescription } }
    }

    private func subjectKeyframes(captureID: String,
                                  context: (APIConnectionIdentity, NativeReconstructionSource, UUID)) async throws -> String? {
        guard transport.supportsSfMKeyframes else { return nil }
        let folder = try ARScanRecorder.packagesDirectory().appendingPathComponent(captureID + ".scan", isDirectory: true)
        guard FileManager.default.fileExists(atPath: folder.appendingPathComponent("capture/transforms.json").path),
              try KeyframePack.subjectTarget(scanFolder: folder) != nil else { return nil }
        return try await uploadKeyframes(captureID: captureID, context: context, subjectMasks: true)
    }

    /// Builds this scan's keyframe pack and uploads it (resumable). Nil when the scan predates
    /// keyframes or has too few of them: the 位姿版 then trains from video frames as before.
    private func uploadKeyframes(captureID: String,
                                 context: (APIConnectionIdentity, NativeReconstructionSource, UUID), subjectMasks: Bool = false) async throws -> String? {
        guard let folder = try? ARScanRecorder.packagesDirectory().appendingPathComponent(captureID + ".scan", isDirectory: true),
              FileManager.default.fileExists(atPath: folder.appendingPathComponent("capture/transforms.json").path) else { return nil }
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("keyframes-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        keyframeUploadRoles[captureID] = subjectMasks ? "refined" : "arkit"
        keyframeUploadProgress[captureID] = 0
        defer { keyframeUploadProgress[captureID] = nil; keyframeUploadRoles[captureID] = nil }
        let built = try await Task.detached(priority: .userInitiated) {
            if subjectMasks { return try KeyframePack.cachedSubjectPack(scanFolder: folder, captureID: captureID) }
            // Reuse the exact subject pack if high quality already uploaded it.
            if FileManager.default.fileExists(atPath: folder.appendingPathComponent("cloud-subject-pack-v1/pack.json").path) {
                return try KeyframePack.cachedSubjectPack(scanFolder: folder, captureID: captureID)
            }
            return try KeyframePack.build(scanFolder: folder, captureID: captureID, into: scratch)
        }.value
        guard let built else { return nil }
        try require(context)
        let stored = try await transport.uploadKeyframes(captureID: captureID, pack: built.url, sha256: built.sha256) { [weak self] fraction in
            self?.keyframeUploadProgress[captureID] = fraction
        }
        try require(context)
        guard stored == built.sha256 else { throw ReconstructionStudyError.invalidManifest }
        return stored
    }

    /// Online: re-checks the server and downloads/verifies. Offline (or on a network
    /// failure): opens the copy already verified on this phone. A server answer such
    /// as "no longer available" is never overridden by the local copy.
    func prepare(captureID: String, variant: ReconstructionVariant) async throws -> PreparedReconstructionVariant {
        guard isConnected else {
            if let cached = await cachedPrepared(captureID: captureID, variant: variant) { return cached }
            throw ReconstructionStudyError.unavailable
        }
        let current = try context(captureID)
        guard let result = results[captureID], result.readyResults.contains(variant) else {
            throw ReconstructionStudyError.unavailable
        }
        do {
            let prepared = try await transport.prepareNativeReconstruction(result, variant: variant, source: current.1)
            try require(current)
            downloadedVariantIDs.insert(variant.id)
            downloadErrors[variant.id] = nil
            return prepared
        } catch let error as URLError {
            if let cached = await cachedPrepared(captureID: captureID, variant: variant) { return cached }
            throw error
        }
    }

    private func cachedPrepared(captureID: String, variant: ReconstructionVariant) async -> PreparedReconstructionVariant? {
        guard let identity, let result = results[captureID], result.readyResults.contains(variant),
              let prepared = await transport.cachedNativeReconstruction(result, variant: variant, identity: identity),
              self.identity == identity, results[captureID]?.readyResults.contains(variant) == true else { return nil }
        downloadedVariantIDs.insert(variant.id)
            downloadErrors[variant.id] = nil
        return prepared
    }
}

/// App-wide follow-up on cloud reconstructions: polls every verified capture that
/// is still processing, announces finished or failed branches with a local
/// notification, and downloads + verifies ready results so they are on the phone.
/// Polling only reads state; it never starts or retries work on its own beyond the
/// requests the user already authorized (see `NativeReconstructionStore.refresh`).
@MainActor
final class ReconstructionSync: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = ReconstructionSync()
    nonisolated static let backgroundTaskID = "com.pocketworld.mvp.reconstruction-sync"
    private static let statusKey = "PocketWorld.knownTaskStatuses"

    let cloud = CaptureV2UploadStore()
    /// Set when the user taps a notification; the gallery opens that scan.
    @Published var openCaptureID: String?
    @Published private(set) var isSyncing = false
    private var knownStatuses: [String: String]

    override init() {
        knownStatuses = UserDefaults.standard.dictionary(forKey: Self.statusKey) as? [String: String] ?? [:]
        super.init()
    }

    func activate() { UNUserNotificationCenter.current().delegate = self }

    func requestNotificationPermission() {
        Task { _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) }
    }

    /// One pass: refresh pending captures, announce transitions, then download ready results.
    func syncOnce(download: Bool = true) async {
        let store = cloud.reconstructions
        guard store.isConnected, !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }
        for id in store.captureIDsNeedingSync() {
            if Task.isCancelled { return }
            await store.refresh(captureID: id)
        }
        await announceChanges()
        guard download else { return }
        for item in store.readyVariantsToDownload() {
            if Task.isCancelled { return }
            await store.prefetch(captureID: item.captureID, variant: item.variant)
        }
    }

    private func announceChanges() async {
        var changed = false
        for (captureID, result) in cloud.reconstructions.results {
            for task in result.tasks {
                let previous = knownStatuses[task.id]
                guard previous != task.status else { continue }
                knownStatuses[task.id] = task.status
                changed = true
                // Announce only transitions seen from a running state, never a first sighting.
                guard let previous, ["queued", "processing"].contains(previous) else { continue }
                if task.status == "ready" || task.status == "failed" {
                    await notify(captureID: captureID, role: task.role, ready: task.status == "ready")
                }
            }
        }
        if changed { UserDefaults.standard.set(knownStatuses, forKey: Self.statusKey) }
    }

    private func notify(captureID: String, role: String, ready: Bool) async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard [.authorized, .provisional].contains(settings.authorizationStatus) else { return }
        let name = "「\(ScanNameStore.shared.displayName(for: captureID))」"
        let version = NativeRoleName.long(role)
        let content = UNMutableNotificationContent()
        content.title = ready ? "\(version)已生成" : "\(version)未能生成"
        content.body = ready
            ? "\(name)的\(version)已完成，正在下载到手机，打开即可查看 3DGS。"
            : "\(name)的\(version)没有成功，其他版本不受影响，可在 App 中单独重试。"
        content.sound = .default
        content.userInfo = ["captureID": captureID]
        let request = UNNotificationRequest(identifier: "reconstruction-\(captureID)-\(role)-\(ready ? "ready" : "failed")",
                                            content: content, trigger: nil)
        try? await center.add(request)
    }

    // MARK: Background refresh (opportunistic; iOS decides when it runs)

    nonisolated static func registerBackgroundTask() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: backgroundTaskID, using: nil) { task in
            guard let refresh = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            Task { @MainActor in await ReconstructionSync.shared.runBackground(refresh) }
        }
    }

    func scheduleBackgroundRefreshIfNeeded() {
        guard !cloud.reconstructions.captureIDsNeedingSync().isEmpty else { return }
        let request = BGAppRefreshTaskRequest(identifier: Self.backgroundTaskID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    private func runBackground(_ task: BGAppRefreshTask) async {
        let work = Task { @MainActor in
            if !cloud.isConnected && !cloud.backendInput.isEmpty { await cloud.connect() }
            await syncOnce(download: false) // Large downloads wait for the foreground.
        }
        task.expirationHandler = { work.cancel() }
        await work.value
        scheduleBackgroundRefreshIfNeeded()
        task.setTaskCompleted(success: !work.isCancelled)
    }

    // MARK: UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        let id = response.notification.request.content.userInfo["captureID"] as? String
        await MainActor.run { self.openCaptureID = id }
    }
}
