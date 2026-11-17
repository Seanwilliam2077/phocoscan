import Foundation
import simd

struct ImageGeneration: Codable, Identifiable, Equatable, Sendable {
    struct File: Codable, Equatable, Sendable { let path: String; let sha256: String; let byteSize: Int }
    struct Hint: Codable, Equatable, Sendable {
        let center: [Double]
        let first_camera_to_world: [[Double]]
        /// A predicted presentation hint, never recorded calibration or a metric camera path.
        var presentation: (target: SIMD3<Float>, distance: Float, yaw: Float, pitch: Float)? {
            guard center.count == 3, center.allSatisfy(\.isFinite), first_camera_to_world.count == 4,
                  first_camera_to_world.allSatisfy({ $0.count == 4 && $0.allSatisfy(\.isFinite) }) else { return nil }
            let target = SIMD3<Float>(center.map(Float.init))
            let p = SIMD3<Float>(Float(first_camera_to_world[0][3]), Float(first_camera_to_world[1][3]), Float(first_camera_to_world[2][3])) - target
            let distance = simd_length(p)
            guard distance.isFinite, distance > 0.001, distance < 1000 else { return nil }
            return (target, distance, -atan2(p.x, p.z), atan2(p.y, simd_length(SIMD2(p.x, p.z))))
        }
    }
    struct Result: Codable, Equatable, Sendable {
        let ply: File
        let spz: File
        let pointCount: Int
        let sourceImageSha256: String
        let algorithm: String
        let provenance: String
        let metricScaleVerified: Bool
        let viewHint: Hint?
    }
    let id: String
    let sha256: String
    let byteSize: Int
    var status: String
    let sourceKind: String
    let createdAt: String
    var attemptId: String?
    var phase: String?
    var progress: Int?
    var errorCode: String?
    var connectionInterrupted: Bool?
    var result: Result?
    var needsDeliveryRecovery: Bool { status == "failed" && errorCode == "invalid_result" }
    var pending: Bool { ["queued", "processing", "cancelling"].contains(status) }
    func validate() throws {
        guard UUID(uuidString: id) != nil, ReconstructionStudy.isSHA256(sha256),
              byteSize > 0, byteSize <= 20 * 1024 * 1024, sourceKind == "ai_single_image",
              ["draft", "uploaded", "queued", "processing", "cancelling", "cancelled", "failed", "ready"].contains(status),
              attemptId == nil || UUID(uuidString: attemptId!) != nil else { throw ReconstructionStudyError.invalidManifest }
        if let result {
            guard status == "ready", result.algorithm == "triposplat", result.provenance == "ai_single_image",
                  !result.metricScaleVerified, result.sourceImageSha256 == sha256,
                  (1...262144).contains(result.pointCount) else { throw ReconstructionStudyError.invalidManifest }
            for (kind, file) in [("ply", result.ply), ("spz", result.spz)] {
                guard file.path == "/v2/image-generations/\(id)/result/\(kind)",
                      ReconstructionStudy.isSHA256(file.sha256), (1...150*1024*1024).contains(file.byteSize) else { throw ReconstructionStudyError.invalidManifest }
            }
        } else if status == "ready" { throw ReconstructionStudyError.invalidManifest }
    }
    var statusLabel: String {
        switch status {
        case "draft": return "仅本机 · 等待上传"
        case "uploaded": return "已上传 · 选择生成"
        case "queued": return "等待生成"
        case "processing":
            if connectionInterrupted == true { return "连接中断 · 正在核对状态" }
            switch phase {
            case "loading", "loading_model": return "正在加载生成器"
            case "preprocessing": return "正在准备图片"
            case "exporting", "uploading": return "生成完成 · 正在准备结果"
            default: return "正在生成 \(progress ?? 0)%"
            }
        case "cancelling": return "正在取消"
        case "cancelled": return "已取消"
        case "failed":
            if needsDeliveryRecovery { return "结果交付失败 · 可恢复结果" }
            return errorCode == "server_busy" ? "服务器繁忙中，请稍后重试" : "生成未完成，可重新生成"
        case "ready": return "可进入 3D 空间"
        default: return "等待确认"
        }
    }
}
