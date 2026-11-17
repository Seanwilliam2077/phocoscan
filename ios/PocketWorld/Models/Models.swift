import Foundation
import SwiftUI

enum CardKind: String, Codable, CaseIterable, Identifiable {
    case entrance, post, road, lobby, rest, green, reading, stall
    var id: String { rawValue }
    var title: String {
        switch self {
        case .entrance: return "小站入口"
        case .post: return "邮局"
        case .road: return "相遇小路"
        case .lobby: return "暖灯门厅"
        case .rest: return "树荫休息区"
        case .green: return "口袋花园"
        case .reading: return "阅读角"
        case .stall: return "周末小摊"
        }
    }
    var symbol: String {
        switch self {
        case .entrance: return "door.left.hand.open"
        case .post: return "envelope.fill"
        case .road: return "point.topleft.down.to.point.bottomright.curvepath"
        case .lobby: return "lamp.desk.fill"
        case .rest: return "chair.lounge.fill"
        case .green: return "leaf.fill"
        case .reading: return "books.vertical.fill"
        case .stall: return "storefront.fill"
        }
    }
    var color: Color {
        switch self {
        case .entrance, .road: return Color(red: 0.67, green: 0.52, blue: 0.36)
        case .post, .lobby: return Color(red: 0.83, green: 0.48, blue: 0.31)
        case .rest, .green: return Color(red: 0.30, green: 0.53, blue: 0.42)
        case .reading: return Color(red: 0.40, green: 0.50, blue: 0.63)
        case .stall: return Color(red: 0.69, green: 0.48, blue: 0.59)
        }
    }
}

enum RoadShape: String, Codable, CaseIterable, Identifiable {
    case straight, corner, tee, cross
    var id: String { rawValue }
    var title: String {
        switch self { case .straight: return "直路"; case .corner: return "转角"; case .tee: return "三岔"; case .cross: return "十字" }
    }
    // North=0, East=1, South=2, West=3; clockwise quarter turns.
    var connectors: Set<Int> {
        switch self { case .straight: return [0, 2]; case .corner: return [0, 1]; case .tee: return [1, 2, 3]; case .cross: return [0, 1, 2, 3] }
    }
}

struct WorldCard: Identifiable, Codable, Equatable {
    let id: String
    var kind: CardKind
    var sessionId: String?
    var roadShape: RoadShape = .cross
    var rotation: Int = 0
    var createdAt: String = Date().ISO8601Format()
    var sourceLabel: String { sessionId == nil ? "虚拟建设卡" : "我的风景卡" }
    var connectors: Set<Int> {
        guard kind == .road else { return [0, 1, 2, 3] }
        return Set(roadShape.connectors.map { ($0 + rotation) % 4 })
    }
}

struct Quest: Codable, Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let npc: String
    let cardKind: CardKind
    let indoorTip: String
    let outdoorTip: String
    let unlockAfter: [String]
    static func load() -> [Quest] {
        guard let url = Bundle.main.url(forResource: "quests", withExtension: "json"),
              let data = try? Data(contentsOf: url), let quests = try? JSONDecoder().decode([Quest].self, from: data) else { return [] }
        return quests
    }
}

struct CaptureSession: Codable, Identifiable {
    let id: String
    let userId: String
    let questId: String
    let sceneId: String
    let parentSessionId: String?
    let environment: String
    let captureMode: String
    let provenance: String
    let captureStatus: String
    let capturedAt: String?
    let submittedAt: String?
    let originalVideoId: String?
    let videoDurationSeconds: Double?
    let width: Int?
    let height: Int?
    let fps: Double?
    let poseSource: String
    let calibrationAvailable: Bool
    let rawDataAvailable: Bool
    let consentVersion: String
    let createdAt: String
}
struct ReconstructionJob: Codable, Identifiable {
    let id: String
    let sessionId: String
    let provider: String
    let status: String
    let resultAssetId: String?
    let errorMessage: String?
}
struct SceneAsset: Codable, Identifiable {
    let id: String
    let sourceSessionIds: [String]
    let kind: String
    let format: String
    let sha256: String
    let provenance: String
    let reconstructionTool: String
    let reconstructionVersion: String?
    let lineageStatus: String
    let qualityStatus: String
    let dualUseStatus: String
}
struct Reward: Codable, Identifiable {
    let id: String
    let sessionId: String
    let questId: String
    let cardKind: CardKind
    let grantedAt: String
}
struct SessionEnvelope: Codable, Identifiable {
    var id: String { session.id }
    var session: CaptureSession
    var job: ReconstructionJob?
    var asset: SceneAsset?
    var reward: Reward?
    var readyForReward: Bool { ["submitted", "asset_imported"].contains(session.captureStatus) }
    var displayStatus: String {
        if job?.status == "ready" { return "风景已寄回" }
        if job?.status == "failed" { return "处理需重试" }
        if job?.status == "cancelled" { return "处理已取消" }
        if job?.status == "processing" { return "正在制作风景" }
        if job?.status == "queued" { return "等待制作风景" }
        if session.captureMode == "external_app" { return "等待导入扫描结果" }
        if session.captureStatus == "saved" { return "视频已上传，待提交" }
        return "探索草稿"
    }
}
struct SessionList: Decodable { let sessions: [SessionEnvelope] }
struct RewardResponse: Decodable { let reward: Reward }
struct APIAcknowledgement: Decodable { let ok: Bool }
struct AuthResponse: Codable { let userId: String; let token: String }
struct GameBackup: Codable { let state: GameSnapshot? }

struct LocalVideo: Codable, Identifiable {
    var id: String { sessionId }
    let sessionId: String
    // Store relative file names, since iOS application container paths can change.
    let fileName: String
    let previewFileName: String?
    let capturedAt: String
    let durationSeconds: Double
    let width: Int
    let height: Int
    let fps: Double
    // Optional preserves decoding of drafts saved before this lock was introduced.
    var uploadStartedAt: String? = nil
    var url: URL { AppFiles.drafts.appendingPathComponent(fileName) }
    var previewURL: URL? { previewFileName.map { AppFiles.drafts.appendingPathComponent($0) } }
}

struct AnalyticsEvent: Codable, Identifiable {
    let id: String
    let name: String
    let occurredAt: String
    var questId: String?
    var sessionId: String?
    var assetId: String?
    var properties: [String: String]?
}
struct EventBatch: Encodable { let events: [AnalyticsEvent] }
struct EventReply: Decodable { let accepted: Int }

struct SessionRequest: Codable {
    let id: String
    let questId: String
    let environment: String
    let captureMode: String
    let consentVersion: String
    let parentSessionId: String?
    let sceneId: String?
}

struct GameSnapshot: Codable {
    var schemaVersion = 1
    var townName = "风慢慢小站"
    var theme = "花园小站"
    var onboarded = false
    var cards: [WorldCard] = []
    var grid: [String?] = Array(repeating: nil, count: 9)
    var completedQuests: [String] = []
    var pureBuildCompleted = false
    var chapterCelebrated = false
    var nextChapter: String?
    var branch: String?
    var sessions: [SessionEnvelope] = []
    var videos: [LocalVideo] = []
    var pendingRequest: SessionRequest?
    var activeCaptureSessionId: String?
    var events: [AnalyticsEvent] = []
    var grantedRewardIds: [String] = []
    var lastOpenedAt: String?
    var updatedAt = Date().ISO8601Format()
}

enum AppFiles {
    static var root: URL {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("PocketWorld", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    static var drafts: URL {
        var url = root.appendingPathComponent("Drafts", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
        return url
    }
    static var assets: URL {
        var url = root.appendingPathComponent("Assets", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
        return url
    }
    static var save: URL { root.appendingPathComponent("game.json") }
}
