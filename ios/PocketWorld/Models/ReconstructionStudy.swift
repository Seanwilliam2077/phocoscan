import Foundation

/// Operator-published results of a real external RGB video. This is not a native
/// ARKit capture receipt and must never advance the growth journal.
struct ReconstructionStudy: Codable, Identifiable, Sendable {
    let id: String
    let title: String
    let sourceKind: String
    let sourceVideoSha256: String
    let captureId: String?
    let createdAt: String
    let variants: [ReconstructionVariant]

    func validated() throws -> ReconstructionStudy {
        guard UUID(uuidString: id) != nil, !title.isEmpty, title.count <= 200,
              sourceKind == "external_rgb_video", captureId == nil,
              Self.isSHA256(sourceVideoSha256), !variants.isEmpty, variants.count <= 2,
              Set(variants.map(\.id)).count == variants.count,
              Set(variants.map(\.role)).count == variants.count else {
            throw ReconstructionStudyError.invalidManifest
        }
        for variant in variants { try variant.validate(studyID: id) }
        return self
    }

    static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.unicodeScalars.allSatisfy {
            CharacterSet(charactersIn: "0123456789abcdef").contains($0)
        }
    }
}

struct ReconstructionVariant: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let role: String
    let algorithm: String
    let status: String
    let format: String
    let shDegree: Int
    let pointCount: Int
    let byteSize: Int
    let sha256: String
    let filePath: String
    let cameraPath: String
    let cameraSha256: String
    let cameraByteSize: Int
    struct Mobile: Codable, Equatable, Sendable {
        let format: String
        let shDegree: Int
        let pointCount: Int
        let byteSize: Int
        let sha256: String
        let filePath: String
        let originalSha256: String
        let lossy: Bool
    }
    var mobile: Mobile? = nil
    var downloadFormat: String { mobile?.format ?? format }
    var downloadSHA256: String { mobile?.sha256 ?? sha256 }
    var downloadByteSize: Int { mobile?.byteSize ?? byteSize }
    var downloadPath: String { mobile?.filePath ?? filePath }

    var title: String {
        switch role {
        case "refined": return "精细重建"
        case "arkit": return "位姿版"
        default: return "快速预览"
        }
    }
    var sizeLabel: String {
        ByteCountFormatter.string(fromByteCount: Int64(byteSize), countStyle: .file)
    }

    func validate(studyID: String) throws {
        // External videos carry no ARKit poses, so they can never have an ARKit-pose result.
        guard role != "arkit" else { throw ReconstructionStudyError.invalidManifest }
        let root = "/v2/reconstruction-studies/\(studyID)/variants/\(id)"
        try validate(root: root)
    }

    func validate(reconstructionID: String) throws {
        guard UUID(uuidString: reconstructionID) != nil else { throw ReconstructionStudyError.invalidManifest }
        try validate(root: "/v2/video-reconstructions/\(reconstructionID)/results/\(id)")
    }

    private func validate(root: String) throws {
        if let mobile {
            guard mobile.format == "spz", mobile.shDegree == shDegree, mobile.pointCount == pointCount,
                  mobile.originalSha256 == sha256, mobile.lossy, ReconstructionStudy.isSHA256(mobile.sha256),
                  (1...150*1024*1024).contains(mobile.byteSize), mobile.filePath == root + "/mobile" else { throw ReconstructionStudyError.invalidManifest }
        }
        let supportedProfile = (role == "preview" && algorithm == "gs_worldmirror2"
            && format == "splat" && shDegree == 0)
            || (role == "refined" && algorithm == "gs_mcmc"
                && format == "ply" && shDegree == 3)
            || (role == "arkit" && algorithm == "gs_mcmc_arkit_prior"
                && format == "ply" && shDegree == 3)
        guard UUID(uuidString: id) != nil, status == "ready", supportedProfile,
              pointCount > 0, pointCount <= 1_000_000,
              byteSize > 0, byteSize <= 150 * 1024 * 1024,
              format != "splat" || byteSize == pointCount * 32,
              cameraByteSize > 0, cameraByteSize <= 4 * 1024 * 1024,
              ReconstructionStudy.isSHA256(sha256),
              ReconstructionStudy.isSHA256(cameraSha256),
              filePath == root + "/file", cameraPath == root + "/cameras" else {
            throw ReconstructionStudyError.invalidManifest
        }
    }
}

struct PreparedReconstructionVariant: Sendable {
    let variant: ReconstructionVariant
    let modelURL: URL
    let cameras: SceneCameraPath
}

enum ReconstructionStudyError: LocalizedError {
    case invalidManifest, hashMismatch, changedServer, unavailable, invalidModel

    var errorDescription: String? {
        switch self {
        case .invalidManifest: return "重建清单的来源、格式或下载路径不匹配。"
        case .hashMismatch: return "下载文件未通过大小与哈希校验，可重新下载。"
        case .changedServer: return "服务器或账号已改变，请重新打开重建对照。"
        case .unavailable: return "该版本尚不可用，请刷新结果。"
        case .invalidModel: return "模型格式与清单不一致，无法安全打开。"
        }
    }
}
