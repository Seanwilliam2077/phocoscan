import Foundation

/// Capture evidence only. A successful reconstruction never upgrades this assessment.
/// Older captures without a report remain unknown, rather than being assigned zero coverage.
struct ScanCaptureAssessment: Equatable {
    enum State: String { case incomplete, retake, limited, usable, unknown }
    let state: State
    let coverage: Double?
    private let validCoverageForCleanup: Bool
    let keyframes: Int?
    let reason: String

    init(isComplete: Bool, analysis: ScanAnalysis?) {
        coverage = analysis.flatMap { $0.completeness.isFinite ? min(1, max(0, $0.completeness)) : nil }
        validCoverageForCleanup = analysis.map { $0.completeness.isFinite && (0...1).contains($0.completeness) } ?? false
        keyframes = analysis?.keyframeCount.map { max(0, $0) }
        if !isComplete {
            state = .incomplete; reason = "原片或轨迹缺失"
        } else if let analysis {
            if analysis.keyframeCount == 0 {
                state = .retake; reason = "没有清晰关键帧"
            } else if analysis.trackingNormalRatio.isFinite && analysis.trackingNormalRatio < 0.6 {
                state = .retake; reason = "相机跟踪不稳定"
            } else if analysis.verdict == "poor" {
                state = .retake
                reason = (coverage ?? 1) < 0.5 ? "拍摄角度不足" : "有效画面偏少"
            } else if analysis.verdict == "fair" {
                state = .limited; reason = analysis.suggestions.first ?? "有角度需要补拍"
            } else if analysis.verdict == "good" {
                state = .usable; reason = "采集记录较充足"
            } else {
                state = .unknown; reason = "暂无采集评估"
            }
        } else {
            state = .unknown; reason = "旧扫描暂无采集评估"
        }
    }

    var needsAttention: Bool { [.incomplete, .retake, .limited].contains(state) }
    var title: String {
        switch state {
        case .incomplete: "保存不完整"
        case .retake: "建议重拍"
        case .limited: "建议补拍"
        case .usable: "素材较完整"
        case .unknown: "未评估"
        }
    }
    var coveragePercent: Int? { coverage.map { Int(($0 * 100).rounded()) } }
    var coverageText: String { coveragePercent.map { "覆盖参考 \($0)%" } ?? "覆盖待评估" }
    /// Match the percentage the user actually sees. Never clean a card labelled 80%.
    var isBelowCleanupThreshold: Bool {
        validCoverageForCleanup && coveragePercent.map { $0 < 80 } == true
    }
    var keyframeText: String { keyframes.map { "\($0) 张关键帧" } ?? "关键帧未记录" }
}

enum ScanLibrarySection: String, CaseIterable {
    case scans = "扫描", images = "单图"
    func includes(isScan: Bool) -> Bool { (self == .scans) == isScan }
}

/// The cleanup plan is a frozen set of IDs, rechecked immediately before deletion.
/// It is independent of search/status filters and never includes image-only works.
enum ScanLibraryCleanup {
    static func includes(assessment: ScanCaptureAssessment?, active: Bool) -> Bool {
        !active && assessment?.isBelowCleanupThreshold == true
    }
}

enum ScanLibraryFilter: String, CaseIterable {
    case all = "全部状态", attention = "需处理", processing = "处理中", ready = "有结果"
    func includes(assessment: ScanCaptureAssessment?, active: Bool, ready: Bool, needsRecovery: Bool = false) -> Bool {
        switch self {
        case .all: true
        case .attention: assessment?.needsAttention == true || needsRecovery
        case .processing: active
        case .ready: ready
        }
    }
}

/// Result availability, running work and recovery are independent. A successful
/// version must not hide a failed sibling or change the capture assessment.
struct ScanWorkState: Equatable {
    var readyCount = 0
    var activeCount = 0
    var failedCount = 0
    var downloadFailureCount = 0
    var pausedCount = 0
    // Historical scan-linked AI works have their own library section. Their
    // activity only blocks source deletion, never counts as scan reconstruction.
    var linkedImageActive = false

    var active: Bool { activeCount > 0 }
    var deletionBlocked: Bool { active || linkedImageActive }
    var ready: Bool { readyCount > 0 }
    var needsRecovery: Bool { failedCount > 0 || downloadFailureCount > 0 || pausedCount > 0 }
    var label: String? {
        var parts: [String] = []
        if ready { parts.append("\(readyCount) 个结果") }
        if active { parts.append("处理中") }
        if pausedCount > 0 { parts.append("已暂停") }
        if failedCount > 0 { parts.append("\(failedCount) 项未完成") }
        if downloadFailureCount > 0 { parts.append("待下载") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

enum ScanLibrarySearch {
    /// Every word must match, including custom names and mode names. Empty input
    /// restores the current filters; it never mutates or renames the source.
    static func matches(_ query: String, fields: [String]) -> Bool {
        let text = fields.joined(separator: " ")
        return query.split(whereSeparator: \.isWhitespace).allSatisfy {
            text.localizedStandardContains(String($0))
        }
    }
}
