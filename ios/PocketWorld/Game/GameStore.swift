import Foundation
import SwiftUI
import CryptoKit

@MainActor
final class GameStore: ObservableObject {
    @Published var state: GameSnapshot
    @Published var serverURL: String
    @Published var isBusy = false
    @Published var statusMessage: String?
    @Published var errorMessage: String?
    @Published var connectionLabel = "尚未连接"
    @Published var selectedCardID: String?
    let quests = Quest.load()
    let api = APIClient()
    private var syncing = false
    private var needsBackupDecision = false

    init() {
        let base = UserDefaults.standard.string(forKey: "PocketWorld.serverURL") ?? ""
        serverURL = base
        let local = Self.readState(base: base)
        state = local ?? GameSnapshot()
        needsBackupDecision = !base.isEmpty && (local == nil || UserDefaults.standard.bool(forKey: Self.backupDecisionKey(base)))
        if needsBackupDecision { UserDefaults.standard.set(true, forKey: Self.backupDecisionKey(base)) }
        if !GameRules.validGrid(state) { state.grid = Array(repeating: nil, count: 9) }
        if !base.isEmpty { api.restore(base: base); connectionLabel = "待连接 · 可离线布置" }
        if state.cards.isEmpty { seedCards() }
        log("app_opened", properties: ["previousVisit": state.lastOpenedAt ?? "first", "source": "native_app"])
        state.lastOpenedAt = Date().ISO8601Format()
        persist()
    }
    private static func saveURL(base: String) -> URL {
        let suffix = base.isEmpty ? "offline" : CredentialStore.account(base)
        return AppFiles.root.appendingPathComponent("game-\(suffix).json")
    }
    private static func backupDecisionKey(_ base: String) -> String { "PocketWorld.backupPending." + CredentialStore.account(base) }
    private static func readState(base: String) -> GameSnapshot? {
        guard let data = try? Data(contentsOf: saveURL(base: base)) else { return nil }
        return try? JSONDecoder().decode(GameSnapshot.self, from: data)
    }
    @discardableResult func persist() -> Bool {
        state.updatedAt = Date().ISO8601Format()
        do {
            let data = try JSONEncoder().encode(state)
            try data.write(to: Self.saveURL(base: serverURL), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            return true
        } catch { errorMessage = "本地存档未能保存：\(error.localizedDescription)"; return false }
    }
    private func seedCards() {
        let entrance = WorldCard(id: "starter-entrance", kind: .entrance)
        let post = WorldCard(id: "starter-post", kind: .post)
        let tee = WorldCard(id: "starter-road-tee", kind: .road, roadShape: .tee)
        let cross = WorldCard(id: "starter-road-cross", kind: .road, roadShape: .cross)
        state.cards = [entrance, post, tee, cross]
        state.grid = [entrance.id, tee.id, nil, post.id, cross.id, nil, nil, nil, nil]
    }
    func finishOnboarding(name: String, theme: String) {
        let firstVisit = !state.onboarded
        state.townName = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(24))
        if state.townName.isEmpty { state.townName = "风慢慢小站" }
        state.theme = theme; state.onboarded = true
        log(firstVisit ? "onboarding_completed" : "town_preferences_updated", properties: ["theme": theme]); persist()
    }
    func configureServer(_ value: String) async {
        guard !isBusy, !syncing else { return }
        isBusy = true; defer { isBusy = false }
        do {
            let oldBase = serverURL
            let normalized = try await api.connect(to: value)
            if oldBase != normalized {
                guard persist() else { api.restore(base: oldBase); return }
                if let existing = Self.readState(base: normalized) {
                    state = existing; needsBackupDecision = UserDefaults.standard.bool(forKey: Self.backupDecisionKey(normalized))
                } else {
                    needsBackupDecision = true
                    if !oldBase.isEmpty { state = GameSnapshot(); seedCards() }
                }
                if needsBackupDecision { UserDefaults.standard.set(true, forKey: Self.backupDecisionKey(normalized)) }
                serverURL = normalized
                UserDefaults.standard.set(normalized, forKey: "PocketWorld.serverURL")
            }
            connectionLabel = "已连接测试服务器"
            persist()
            isBusy = false
            await refresh()
            statusMessage = "连接成功，可以把风景寄回小站了。"
        } catch { errorMessage = friendly(error); connectionLabel = "连接未成功 · 草稿仍在本机" }
    }
    func friendly(_ error: Error) -> String {
        if let error = error as? URLError {
            switch error.code {
            case .notConnectedToInternet, .cannotConnectToHost, .cannotFindHost, .timedOut:
                return "暂时连不上服务器。草稿已保留，请检查 Wi-Fi 和设置中的地址，再点重试。"
            default: break
            }
        }
        return error.localizedDescription
    }
    func quest(_ id: String) -> Quest? { quests.first { $0.id == id } }
    func isUnlocked(_ quest: Quest) -> Bool { quest.unlockAfter.allSatisfy { state.completedQuests.contains($0) } }
    func envelope(_ id: String) -> SessionEnvelope? { state.sessions.first { $0.id == id } }
    func video(_ sessionId: String) -> LocalVideo? { state.videos.first { $0.sessionId == sessionId } }
    func card(_ id: String?) -> WorldCard? { state.cards.first { $0.id == id } }
    var availableCards: [WorldCard] { state.cards.filter { !state.grid.contains($0.id) } }
    var wishes: [ResidentWish] { GameRules.wishes(in: state) }
    var progress: Int {
        if state.chapterCelebrated { return 7 }
        if state.completedQuests.contains("reading_nook") { return 6 }
        if state.branch != nil { return 5 }
        if state.pureBuildCompleted { return 4 }
        if state.completedQuests.contains("rest_stop") { return 3 }
        if state.completedQuests.contains("first_light") { return 1 }
        return 0
    }
    func placeSelected(at index: Int) {
        guard let selected = selectedCardID, state.cards.contains(where: { $0.id == selected }), state.grid.indices.contains(index) else { return }
        let before = Set(wishes.filter(\.satisfied).map(\.id))
        let old = state.grid.firstIndex(where: { $0 == selected })
        let replaced = state.grid[index]
        if let old, old != index { state.grid[old] = replaced }
        state.grid[index] = selected
        log("card_placed", properties: ["cardId": selected, "cell": String(index)])
        let after = Set(wishes.filter(\.satisfied).map(\.id))
        for resident in after.subtracting(before) { log("resident_goal_satisfied", properties: ["resident": resident]) }
        selectedCardID = nil; persist()
    }
    func rotate(_ id: String) {
        guard let index = state.cards.firstIndex(where: { $0.id == id }) else { return }
        state.cards[index].rotation = (state.cards[index].rotation + 1) % 4
        log("card_rotated", properties: ["cardId": id]); persist()
    }
    func changeRoad(_ id: String, shape: RoadShape) {
        guard let index = state.cards.firstIndex(where: { $0.id == id }), state.cards[index].kind == .road else { return }
        state.cards[index].roadShape = shape; persist()
    }
    func removeFromGrid(_ id: String) {
        if let index = state.grid.firstIndex(where: { $0 == id }) { state.grid[index] = nil }
        selectedCardID = nil; persist()
    }
    func completePureBuild() {
        guard state.completedQuests.contains("first_light"), !state.pureBuildCompleted else { return }
        state.pureBuildCompleted = true
        state.cards.append(WorldCard(id: "story-green", kind: .green))
        log("chapter_completed", properties: ["chapter": "a_quiet_afternoon", "captureRequired": "false"])
        statusMessage = "小禾送来一片虚拟绿地。今天不探索，也能让小站更温柔。"; persist()
    }
    func chooseBranch(_ branch: String) { state.branch = branch; log("development_branch_selected", properties: ["branch": branch]); persist() }
    func celebrate() {
        guard GameRules.canCelebrate(state), !state.chapterCelebrated else { return }
        state.chapterCelebrated = true
        log("chapter_completed", properties: ["chapter": "opening_celebration"]); persist()
    }
    func chooseNextChapter(_ chapter: String) { state.nextChapter = chapter; log("next_chapter_selected", properties: ["chapter": chapter]); persist() }

    func startSession(questId: String, environment: String, mode: String, parent: String? = nil) async -> String? {
        guard !isBusy else { return nil }
        isBusy = true; defer { isBusy = false }
        do {
            guard api.auth != nil else { throw APIError.configuration("请先在「设置」连接本机测试服务器。社区可以继续离线布置。") }
            let request: SessionRequest
            if let pending = state.pendingRequest {
                guard pending.questId == questId, pending.environment == environment, pending.captureMode == mode, pending.parentSessionId == parent else {
                    throw APIError.configuration("还有一次未确认的任务创建。请在探索记录中先重试它，避免创建重复任务。")
                }
                request = pending
            } else {
                request = SessionRequest(id: UUID().uuidString.lowercased(), questId: questId, environment: environment, captureMode: mode, consentVersion: "2026-10-22-v1", parentSessionId: parent, sceneId: parent.flatMap { envelope($0)?.session.sceneId })
                state.pendingRequest = request
            }
            guard persist() else { return nil }
            let result: SessionEnvelope = try await api.json("/v1/sessions", body: request)
            upsert(result); state.pendingRequest = nil
            log("quest_accepted", questId: questId, sessionId: result.id, properties: ["environment": environment, "captureMode": mode])
            if parent != nil { log("repair_capture_started", questId: questId, sessionId: result.id) }
            persist()
            return result.id
        } catch { errorMessage = friendly(error); return nil }
    }
    func retryPendingSession() async -> String? {
        guard let request = state.pendingRequest else { return nil }
        return await startSession(questId: request.questId, environment: request.environment, mode: request.captureMode, parent: request.parentSessionId)
    }
    @discardableResult func willCapture(_ id: String) -> Bool {
        state.activeCaptureSessionId = id; log("capture_started", sessionId: id); return persist()
    }
    @discardableResult func saveVideo(_ captured: CapturedVideo, sessionId: String) -> Bool {
        do {
            guard captured.sessionID == sessionId else { throw APIError.configuration("录像关联的任务不一致，已保留原始文件，请重试。") }
            let before = state
            let previous = video(sessionId)
            guard previous?.uploadStartedAt == nil else { throw APIError.configuration("这次探索已经开始寄出，不能替换原视频。请保留重试，或从任务页创建新探索。") }
            let fileName = "\(sessionId)-\(UUID().uuidString.lowercased()).mov"
            let destination = AppFiles.drafts.appendingPathComponent(fileName)
            try FileManager.default.copyItem(at: captured.url, to: destination)
            var previewName: String?
            if let thumbnail = captured.previewURL, FileManager.default.fileExists(atPath: thumbnail.path) {
                let name = "\(sessionId)-\(UUID().uuidString.lowercased())-preview.jpg"
                let output = AppFiles.drafts.appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: output.path) { try FileManager.default.removeItem(at: output) }
                try FileManager.default.copyItem(at: thumbnail, to: output); previewName = name
            }
            let video = LocalVideo(sessionId: sessionId, fileName: fileName, previewFileName: previewName, capturedAt: captured.capturedAt.ISO8601Format(), durationSeconds: captured.durationSeconds, width: captured.width, height: captured.height, fps: captured.fps)
            state.videos.removeAll { $0.sessionId == sessionId }; state.videos.append(video)
            state.activeCaptureSessionId = nil
            log("capture_saved", sessionId: sessionId, properties: ["durationSeconds": String(video.durationSeconds), "poseSource": "none"])
            guard persist() else {
                state = before
                try? FileManager.default.removeItem(at: destination)
                if let preview = video.previewURL { try? FileManager.default.removeItem(at: preview) }
                return false
            }
            if let previous {
                try? FileManager.default.removeItem(at: previous.url)
                if let preview = previous.previewURL { try? FileManager.default.removeItem(at: preview) }
            }
            // Do not remove the recoverable original until its replacement and association are durable.
            try? captured.deleteLocalFiles()
            statusMessage = "探索已保存在本机。预览后，再把它寄出。"
            return true
        } catch { errorMessage = "保存探索草稿失败：\(error.localizedDescription)"; return false }
    }
    func cancelCapture() { state.activeCaptureSessionId = nil; persist() }
    func recoverCaptureIfNeeded() {
        guard let id = state.activeCaptureSessionId else { return }
        guard let recovered = CapturedVideo.savedCaptures().filter({ $0.sessionID == id }).sorted(by: { $0.capturedAt > $1.capturedAt }).first else { return }
        if let previous = video(id), FileManager.default.fileExists(atPath: previous.url.path) {
            // A completed older draft must not hide a newer, interrupted retake of this exact session.
            guard recovered.capturedAt.ISO8601Format() != previous.capturedAt,
                  let previousDate = ISO8601DateFormatter().date(from: previous.capturedAt),
                  recovered.capturedAt > previousDate else { return }
        }
        saveVideo(recovered, sessionId: id)
    }
    func submitVideo(_ id: String) async {
        guard !isBusy else { return }
        guard let local = video(id) else { errorMessage = "找不到本机视频，请重新探索。"; return }
        isBusy = true; defer { isBusy = false }
        do {
            if let index = state.videos.firstIndex(where: { $0.sessionId == id }) {
                if state.videos[index].uploadStartedAt == nil { state.videos[index].uploadStartedAt = Date().ISO8601Format() }
                // The server may commit bytes even when its response is lost. Never retake in-place after this point.
                guard persist() else { return }
            }
            let current: SessionEnvelope = try await api.get("/v1/sessions/\(id)")
            upsert(current)
            if !current.readyForReward {
                let uploaded: SessionEnvelope = try await api.upload("/v1/sessions/\(id)/video", file: local.url, mime: "video/quicktime")
                upsert(uploaded); persist()
                if let preview = local.previewURL {
                    let _: APIAcknowledgement? = try? await api.upload("/v1/sessions/\(id)/preview", file: preview, mime: "image/jpeg")
                }
                struct Submit: Encodable { let capturedAt: String; let durationSeconds: Double; let width: Int; let height: Int; let fps: Double }
                let submitted: SessionEnvelope = try await api.json("/v1/sessions/\(id)/submit", body: Submit(capturedAt: local.capturedAt, durationSeconds: local.durationSeconds, width: local.width, height: local.height, fps: local.fps))
                upsert(submitted); log("upload_completed", sessionId: id); persist()
            }
            try await claimReward(id)
            statusMessage = "风景已寄出，基础场景卡已放进背包。制作结果稍后回来。"
            await flushEvents()
        } catch { errorMessage = friendly(error); persist() }
    }
    func importAsset(_ source: URL, sessionId: String, tool: String = "Scaniverse") async {
        guard !isBusy else { return }
        isBusy = true; defer { isBusy = false }
        let accessed = source.startAccessingSecurityScopedResource()
        defer { if accessed { source.stopAccessingSecurityScopedResource() } }
        do {
            let ext = source.pathExtension.lowercased()
            let toolName = String(tool.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
            guard !toolName.isEmpty else { throw APIError.configuration("请填写实际使用的扫描工具。") }
            guard ["ply", "splat"].contains(ext) else { throw APIError.configuration("首版支持 Gaussian PLY 或 .splat。请在扫描工具中导出对应格式；普通点云不能作为风景模型。") }
            let values = try source.resourceValues(forKeys: [.fileSizeKey])
            guard (values.fileSize ?? 0) > 0, (values.fileSize ?? 0) <= 150 * 1024 * 1024 else { throw APIError.configuration("请导入小于 150 MB 的风景模型，较大的结果请先在工具中裁剪。") }
            let target = AppFiles.drafts.appendingPathComponent("\(sessionId)-external.\(ext)")
            if source != target {
                if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
                try FileManager.default.copyItem(at: source, to: target)
            }
            log("external_capture_returned", sessionId: sessionId)
            var route = URLComponents()
            route.path = "/v1/sessions/\(sessionId)/asset"
            route.queryItems = [URLQueryItem(name: "format", value: ext), URLQueryItem(name: "tool", value: toolName)]
            guard let path = route.string else { throw APIError.invalidResponse }
            let result: SessionEnvelope = try await api.upload(path, file: target, mime: "application/octet-stream")
            upsert(result); log("asset_imported", sessionId: sessionId, assetId: result.asset?.id); persist()
            try await claimReward(sessionId)
            statusMessage = "这次扫描的风景已收好，可以打开回看并布置场景卡。"
            await flushEvents()
        } catch { errorMessage = friendly(error); persist() }
    }
    func claim(_ id: String) async {
        guard !isBusy else { return }
        isBusy = true; defer { isBusy = false }
        do { try await claimReward(id) } catch { errorMessage = friendly(error) }
    }
    private func claimReward(_ id: String) async throws {
        let reply: RewardResponse = try await api.json("/v1/sessions/\(id)/reward", body: [String: String]())
        apply(reply.reward)
        if let index = state.sessions.firstIndex(where: { $0.id == id }) { state.sessions[index].reward = reply.reward }
        persist()
    }
    private func apply(_ reward: Reward) {
        guard !state.grantedRewardIds.contains(reward.id) else { return }
        state.grantedRewardIds.append(reward.id)
        if !state.cards.contains(where: { $0.id == "reward-\(reward.id)" }) {
            state.cards.append(WorldCard(id: "reward-\(reward.id)", kind: reward.cardKind, sessionId: reward.sessionId))
        }
        if !state.completedQuests.contains(reward.questId) { state.completedQuests.append(reward.questId) }
        log("card_granted", questId: reward.questId, sessionId: reward.sessionId, properties: ["cardKind": reward.cardKind.rawValue])
    }
    private func upsert(_ value: SessionEnvelope) {
        if let index = state.sessions.firstIndex(where: { $0.id == value.id }) { state.sessions[index] = value }
        else { state.sessions.insert(value, at: 0) }
        if let reward = value.reward { apply(reward) }
    }
    func refresh() async {
        guard let userId = api.auth?.userId, !syncing, !isBusy else { return }
        syncing = true; isBusy = true
        defer { syncing = false; isBusy = false }
        let base = serverURL
        do {
            if needsBackupDecision {
                // A surviving Keychain account may own a remote save after reinstall.
                // Do not overwrite that save before we have successfully checked it.
                let backup: GameBackup = try await api.get("/v1/game")
                guard base == serverURL, userId == api.auth?.userId else { return }
                if var restored = backup.state {
                    guard restored.schemaVersion == 1, GameRules.validGrid(restored) else { throw APIError.configuration("服务器存档版本暂不兼容，未覆盖远端存档。") }
                    restored.videos = restored.videos.filter {
                        $0.fileName == URL(fileURLWithPath: $0.fileName).lastPathComponent &&
                        ($0.previewFileName == nil || $0.previewFileName == URL(fileURLWithPath: $0.previewFileName!).lastPathComponent) &&
                        FileManager.default.fileExists(atPath: $0.url.path)
                    }
                    restored.events = []
                    state = restored
                    log("game_backup_restored")
                }
                guard persist() else { return }
                needsBackupDecision = false
                UserDefaults.standard.set(false, forKey: Self.backupDecisionKey(base))
            }
            let reply: SessionList = try await api.get("/v1/sessions")
            guard base == serverURL, userId == api.auth?.userId else { return }
            let existingIDs = Set(reply.sessions.map(\.id))
            let removedIDs = Set(state.sessions.map(\.id)).subtracting(existingIDs)
            // Deletions from another device must not keep stale models visible here.
            for id in removedIDs { removeLocalSession(id) }
            for item in reply.sessions {
                let previous = envelope(item.id)
                if item.job?.status == "ready", previous?.job?.status != "ready" { log("result_ready", sessionId: item.id, assetId: item.asset?.id) }
                if item.job?.status == "failed", previous?.job?.status != "failed" { log("processing_failed", sessionId: item.id) }
                upsert(item)
            }
            connectionLabel = "已连接测试服务器"; persist()
            await flushEvents()
            guard base == serverURL, userId == api.auth?.userId else { return }
            let _: APIAcknowledgement = try await api.json("/v1/game", method: "PUT", body: GameBackup(state: state))
        } catch { connectionLabel = "离线 · 草稿与社区已保留" }
    }
    func downloadAsset(_ asset: SceneAsset) async -> URL? {
        guard !isBusy else { return nil }
        isBusy = true; defer { isBusy = false }
        do {
            let destination = AppFiles.assets.appendingPathComponent("\(asset.id).\(asset.format)")
            if !FileManager.default.fileExists(atPath: destination.path) { try await api.download("/v1/assets/\(asset.id)/file", to: destination) }
            let handle = try FileHandle(forReadingFrom: destination)
            defer { try? handle.close() }
            var hash = SHA256()
            while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty { hash.update(data: chunk) }
            let actual = hash.finalize().map { String(format: "%02x", $0) }.joined()
            guard actual == asset.sha256 else { try? FileManager.default.removeItem(at: destination); throw APIError.configuration("风景文件校验失败，请重新下载。") }
            log("result_open_requested", sessionId: asset.sourceSessionIds.first, assetId: asset.id); persist()
            return destination
        } catch { errorMessage = friendly(error); return nil }
    }
    func deleteSession(_ id: String) async -> Bool {
        guard !isBusy else { return false }
        isBusy = true; defer { isBusy = false }
        do {
            try await api.delete("/v1/sessions/\(id)")
            removeLocalSession(id)
            guard persist() else { return false }
            statusMessage = "探索影像与结果已删除，建设卡保留为虚拟卡。"; return true
        } catch { errorMessage = friendly(error); return false }
    }
    private func removeLocalSession(_ id: String) {
        let asset = envelope(id)?.asset
        if let local = video(id) {
            try? FileManager.default.removeItem(at: local.url)
            if let preview = local.previewURL { try? FileManager.default.removeItem(at: preview) }
        }
        for capture in CapturedVideo.savedCaptures() where capture.sessionID == id { try? capture.deleteLocalFiles() }
        if let asset { try? FileManager.default.removeItem(at: AppFiles.assets.appendingPathComponent("\(asset.id).\(asset.format)")) }
        for ext in ["ply", "splat"] { try? FileManager.default.removeItem(at: AppFiles.drafts.appendingPathComponent("\(id)-external.\(ext)")) }
        state.sessions.removeAll { $0.id == id }; state.videos.removeAll { $0.sessionId == id }
        state.events.removeAll { $0.sessionId == id || ($0.assetId != nil && $0.assetId == asset?.id) }
        for index in state.cards.indices where state.cards[index].sessionId == id { state.cards[index].sessionId = nil }
        if state.activeCaptureSessionId == id { state.activeCaptureSessionId = nil }
    }
    func log(_ name: String, questId: String? = nil, sessionId: String? = nil, assetId: String? = nil, properties: [String: String]? = nil) {
        var context = properties ?? [:]
        if let id = sessionId, let session = envelope(id)?.session {
            context["environment"] = session.environment; context["captureMode"] = session.captureMode; context["provenance"] = session.provenance
        }
        state.events.append(AnalyticsEvent(id: UUID().uuidString.lowercased(), name: name, occurredAt: Date().ISO8601Format(), questId: questId, sessionId: sessionId, assetId: assetId, properties: context))
    }
    func flushEvents() async {
        guard api.auth != nil, !state.events.isEmpty else { return }
        let batch = Array(state.events.prefix(100))
        do {
            let _: EventReply = try await api.json("/v1/events", body: EventBatch(events: batch))
            let sent = Set(batch.map(\.id)); state.events.removeAll { sent.contains($0.id) }; persist()
        } catch { /* Retry the same event IDs on the next foreground sync. */ }
    }
}
