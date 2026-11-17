import Foundation

/// Immutable lineage from the native /captures verification receipt. External
/// studies never construct this binding and never contribute growth receipts.
struct NativeReconstructionSource: Codable, Equatable, Sendable {
    let captureID: String
    let receiptID: String
    let videoSHA256: String
    let videoByteSize: Int
    let metadataSHA256: String
    let metadataByteSize: Int

    init(status: CaptureV2Status) throws {
        guard UUID(uuidString: status.id) != nil, let receipt = status.verifiedReceipt,
              let rgb = status.rgb, let metadata = status.metadata,
              ReconstructionStudy.isSHA256(rgb.sha256), rgb.byteSize > 0,
              ReconstructionStudy.isSHA256(metadata.sha256), metadata.byteSize > 0 else {
            throw ReconstructionStudyError.invalidManifest
        }
        captureID = status.id; receiptID = receipt.captureReceiptId
        videoSHA256 = rgb.sha256; videoByteSize = rgb.byteSize
        metadataSHA256 = metadata.sha256; metadataByteSize = metadata.byteSize
    }
}

struct NativeReconstructionTask: Codable, Identifiable, Equatable, Sendable {
    struct Failure: Codable, Equatable, Sendable { let code: String; let message: String }
    let id: String
    let algorithm: String
    let role: String
    let status: String
    let phase: String
    let error: Failure?
    let result: ReconstructionVariant?
    let replacementId: String?
    let archivedAt: String?
    /// Inputs beyond the verified video, e.g. the keyframe pack the 位姿版 trained from.
    var input: Input? = nil

    struct Input: Codable, Equatable, Sendable {
        struct Keyframes: Codable, Equatable, Sendable {
            let sha256: String
            let frameCount: Int
            let masks: Bool
        }
        let keyframes: Keyframes?
    }

    var trainedFromKeyframes: Bool { input?.keyframes != nil }

    var title: String {
        switch role {
        case "refined": return "精细重建"
        case "arkit": return "位姿版"
        default: return "快速预览"
        }
    }
    var isPending: Bool { ["queued", "processing"].contains(status) }
    var canRetry: Bool { status == "failed" }
    var statusLabel: String {
        switch status {
        case "queued": return "排队中"
        case "processing":
            if phase.contains("artifact") || phase.contains("publish") { return "重建完成 · 正在校验结果" }
            if phase.contains("upload") || phase.contains("extract") { return "正在准备素材" }
            return phase == "waiting_gpu" ? "等待计算资源" : "重建中"
        case "ready": return "可以查看"
        case "failed":
            switch error?.code {
            case "gpu_memory_unavailable": return "服务器显存暂不足，请稍后重试"
            case "sfm_quality_insufficient": return "相机匹配不可靠，可选择位姿版或补拍重叠视角"
            case "insufficient_frames", "arkit_tracking_insufficient": return "有效素材不足，请放慢移动并补拍重叠视角"
            case "provider_cancelled": return "服务器任务已取消，可单独重试"
            case "artifact_read_failed": return "结果读取失败，需要服务端检查"
            default: return "本次重建失败，可单独重试"
            }
        case "blocked": return "需要服务端核对，暂不能重复提交"
        default: return "等待状态确认"
        }
    }

    func validate(reconstructionID: String) throws {
        guard UUID(uuidString: id) != nil,
              (role == "preview" && algorithm == "gs_worldmirror2")
                || (role == "refined" && algorithm == "gs_mcmc")
                || (role == "arkit" && algorithm == "gs_mcmc_arkit_prior"),
              ["queued", "processing", "ready", "failed", "blocked"].contains(status),
              !phase.isEmpty, phase.count <= 120,
              (status == "ready") == (result != nil) else { throw ReconstructionStudyError.invalidManifest }
        if let result {
            try result.validate(reconstructionID: reconstructionID)
            guard result.id == id, result.role == role, result.algorithm == algorithm else {
                throw ReconstructionStudyError.invalidManifest
            }
        }
        if let pack = input?.keyframes {
            guard ["refined", "arkit"].contains(role), ReconstructionStudy.isSHA256(pack.sha256),
                  (8...64).contains(pack.frameCount), role != "refined" || pack.masks else { throw ReconstructionStudyError.invalidManifest }
        }
        if let replacementId, UUID(uuidString: replacementId) == nil { throw ReconstructionStudyError.invalidManifest }
    }
}

struct NativeReconstruction: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let sourceKind: String
    let captureId: String
    let captureReceiptId: String
    let sourceVideoSha256: String
    let sourceByteSize: Int
    let sourceMetadataSha256: String
    let sourceMetadataByteSize: Int
    let status: String
    let createdAt: String
    let tasks: [NativeReconstructionTask]
    let previousAttempts: [NativeReconstructionTask]

    var isPending: Bool { tasks.contains(where: \.isPending) }
    var readyResults: [ReconstructionVariant] { tasks.compactMap(\.result) }
    func task(role: String) -> NativeReconstructionTask? { tasks.first { $0.role == role } }

    func validated(source: NativeReconstructionSource, previous: NativeReconstruction? = nil) throws -> Self {
        guard UUID(uuidString: id) != nil, sourceKind == "native_arkit_capture",
              captureId == source.captureID, captureReceiptId == source.receiptID,
              sourceVideoSha256 == source.videoSHA256, sourceByteSize == source.videoByteSize,
              sourceMetadataSha256 == source.metadataSHA256, sourceMetadataByteSize == source.metadataByteSize,
              !title.isEmpty, title.count <= 200,
              ["idle", "queued", "processing", "partial", "ready", "failed", "blocked"].contains(status),
              // The owner picks the versions: any of 快速预览 / 精细重建 / 位姿版, each at most once
              // (the task check below limits the roles). No version yet is "idle".
              Set(tasks.map(\.role)).count == tasks.count,
              tasks.isEmpty == (status == "idle"),
              Set(tasks.map(\.id)).count == tasks.count, previousAttempts.count <= 1000 else {
            throw ReconstructionStudyError.invalidManifest
        }
        for task in tasks + previousAttempts { try task.validate(reconstructionID: id) }
        guard Set((tasks + previousAttempts).map(\.id)).count == tasks.count + previousAttempts.count else {
            throw ReconstructionStudyError.invalidManifest
        }
        if let previous {
            guard previous.id == id else { throw ReconstructionStudyError.invalidManifest }
            for old in previous.tasks {
                if let same = (tasks + previousAttempts).first(where: { $0.id == old.id }), same.input != old.input {
                    throw ReconstructionStudyError.invalidManifest
                }
            }
            // A retry of the other branch must never erase or replace a ready
            // immutable result, including after a reconnect or lost response.
            for ready in previous.readyResults {
                guard readyResults.contains(ready) else { throw ReconstructionStudyError.invalidManifest }
            }
        }
        return self
    }
}

/// The versions the user asked to generate from the verified video. Saved before the POST, so a
/// lost response repeats exactly this choice and starts nothing else.
struct NativeVersionRequest: Codable, Equatable, Sendable {
    /// 快速预览 and 精细重建, in display order. The 位姿版 has its own request.
    static let videoRoles = ["preview", "refined"]
    let source: NativeReconstructionSource
    /// A subset of `videoRoles` in that order. Empty only opens the reconstruction, which lets
    /// the 位姿版 run without the other two.
    let roles: [String]
    var keyframesSha256: String? = nil

    init(source: NativeReconstructionSource, roles: [String]) {
        self.source = source
        self.roles = Self.videoRoles.filter(roles.contains)
    }
}

/// A user-approved request to add the cloud ARKit pose-prior task. Persisted before the POST so a
/// lost response is replayed with the same ID instead of creating a second task.
struct NativeArkitTrainingIntent: Codable, Equatable, Sendable {
    static let consentVersion = "2026-11-05-native-arkit-prior-v1"
    let id: String
    let reconstructionID: String
    let source: NativeReconstructionSource
    /// The uploaded keyframe pack this task trains from; nil trains from video frames.
    /// Optional, so intents saved before keyframes still decode.
    var keyframesSha256: String? = nil

    static func create(reconstruction: NativeReconstruction, source: NativeReconstructionSource,
                       existing: Self?, keyframesSha256: String? = nil) throws -> Self {
        _ = try reconstruction.validated(source: source)
        if let existing {
            guard UUID(uuidString: existing.id) != nil, existing.reconstructionID == reconstruction.id,
                  existing.source == source else { throw ReconstructionStudyError.invalidManifest }
            return existing
        }
        guard reconstruction.task(role: "arkit") == nil else { throw ReconstructionStudyError.unavailable }
        if let keyframesSha256, !ReconstructionStudy.isSHA256(keyframesSha256) { throw ReconstructionStudyError.invalidManifest }
        return Self(id: UUID().uuidString.lowercased(), reconstructionID: reconstruction.id, source: source,
                    keyframesSha256: keyframesSha256)
    }
}

struct NativeReconstructionRetry: Codable, Equatable, Sendable {
    let id: String
    let failedTaskId: String
    let reconstructionID: String
    let source: NativeReconstructionSource

    var keyframesSha256: String? = nil

    static func create(reconstruction: NativeReconstruction, task: NativeReconstructionTask,
                       source: NativeReconstructionSource, existing: Self?) throws -> Self {
        _ = try reconstruction.validated(source: source)
        guard reconstruction.tasks.contains(task), task.canRetry else { throw ReconstructionStudyError.unavailable }
        if let existing {
            guard UUID(uuidString: existing.id) != nil, existing.failedTaskId == task.id,
                  existing.reconstructionID == reconstruction.id, existing.source == source else {
                throw ReconstructionStudyError.invalidManifest
            }
            return existing
        }
        return Self(id: UUID().uuidString.lowercased(), failedTaskId: task.id,
                    reconstructionID: reconstruction.id, source: source)
    }
}

/// A ready version must never hide the independent action for another version.
/// Selection is pure presentation; only the explicit button starts a request.
enum NativeViewerVersionAction: Equatable {
    static func initialRole(preferred: String?, tasks: [NativeReconstructionTask]) -> String {
        if let preferred, ["preview", "refined", "arkit"].contains(preferred) { return preferred }
        let ordered = tasks.sorted { NativeRoleName.order($0.role) < NativeRoleName.order($1.role) }
        return (ordered.first { $0.result != nil } ?? ordered.first)?.role ?? "preview"
    }

    case generate, resume, retry(taskID: String), waiting, ready, blocked
    static func roles(in result: NativeReconstruction?) -> [String] {
        ["preview", "refined"] + (result?.task(role: "arkit") == nil ? [] : ["arkit"])
    }
    static func selected(role: String, in result: NativeReconstruction?, requested: Bool) -> Self {
        guard let task = result?.task(role: role) else { return requested ? .resume : .generate }
        if task.result != nil { return .ready }
        if task.isPending { return .waiting }
        if task.canRetry { return .retry(taskID: task.id) }
        return .blocked
    }
}
