import XCTest
import SwiftUI
@testable import PocketWorld

@MainActor
final class ScanProjectTests: XCTestCase {
    private func report() -> ScanAnalysis {
        var report = ScanAnalyzer().finalize(coverage: ScanCoverage(), mode: .object)
        report.verdict = "good"; report.completeness = 0.92
        report.trackingNormalRatio = 0.98; report.frameCount = 900; report.keyframeCount = 80
        report.suggestions = []; report.issues = []
        return report
    }
    func testIncompleteAndLegacyCapturesAreNotMislabelledAsComplete() {
        let missing = ScanCaptureAssessment(isComplete: false, analysis: report())
        XCTAssertEqual(missing.state, .incomplete)
        XCTAssertTrue(missing.needsAttention)
        let old = ScanCaptureAssessment(isComplete: true, analysis: nil)
        XCTAssertEqual(old.state, .unknown); XCTAssertNil(old.coverage); XCTAssertNil(old.keyframes)
        XCTAssertFalse(old.needsAttention)
    }
    func testCaptureProblemsRemainVisibleEvenWithAReadyReconstruction() {
        var report = report(); report.verdict = "poor"; report.completeness = 0.22
        let value = ScanCaptureAssessment(isComplete: true, analysis: report)
        XCTAssertEqual(value.state, .retake)
        XCTAssertEqual(value.coverageText, "覆盖参考 22%")
        XCTAssertTrue(ScanLibraryFilter.attention.includes(assessment: value, active: false, ready: true))
        XCTAssertTrue(ScanLibraryFilter.ready.includes(assessment: value, active: false, ready: true))
    }
    func testZeroKeyframesAndUnstableTrackingOverrideGoodVerdict() {
        var report = report(); report.keyframeCount = 0
        XCTAssertEqual(ScanCaptureAssessment(isComplete: true, analysis: report).reason, "没有清晰关键帧")
        report.keyframeCount = 50; report.trackingNormalRatio = 0.4
        XCTAssertEqual(ScanCaptureAssessment(isComplete: true, analysis: report).reason, "相机跟踪不稳定")
    }
    func testLimitedAndUnknownCoverageRemainDistinct() {
        var report = report(); report.verdict = "fair"; report.suggestions = ["补拍顶部"]
        let limited = ScanCaptureAssessment(isComplete: true, analysis: report)
        XCTAssertEqual(limited.state, .limited); XCTAssertEqual(limited.reason, "补拍顶部")
        report.completeness = .nan; report.keyframeCount = nil
        let unknown = ScanCaptureAssessment(isComplete: true, analysis: report)
        XCTAssertNil(unknown.coverage); XCTAssertEqual(unknown.keyframeText, "关键帧未记录")
        report.completeness = 2
        XCTAssertEqual(ScanCaptureAssessment(isComplete: true, analysis: report).coverage, 1)
    }
    func testFiltersKeepProcessingIndependentOfReadyAndDoNotTreatAIAsMeasuredCapture() {
        XCTAssertFalse(ScanLibraryFilter.attention.includes(assessment: nil, active: false, ready: true))
        XCTAssertTrue(ScanLibraryFilter.processing.includes(assessment: nil, active: true, ready: true))
        XCTAssertTrue(ScanLibraryFilter.ready.includes(assessment: nil, active: true, ready: true))
        XCTAssertFalse(ScanLibraryFilter.processing.includes(assessment: nil, active: false, ready: true))
    }
    func testReadyVersionDoesNotHideFailedOrRunningSiblings() {
        let work = ScanWorkState(readyCount: 2, activeCount: 1, failedCount: 1)
        XCTAssertEqual(work.label, "2 个结果 · 处理中 · 1 项未完成")
        XCTAssertTrue(work.active); XCTAssertTrue(work.ready); XCTAssertTrue(work.needsRecovery)
        let goodCapture = ScanCaptureAssessment(isComplete: true, analysis: report())
        XCTAssertFalse(goodCapture.needsAttention)
        XCTAssertTrue(ScanLibraryFilter.attention.includes(assessment: goodCapture, active: work.active,
                                                         ready: work.ready, needsRecovery: work.needsRecovery))
        // A single-image failure is actionable despite having no measured capture assessment.
        XCTAssertTrue(ScanLibraryFilter.attention.includes(assessment: nil, active: false, ready: false, needsRecovery: true))
    }
    func testDownloadFailureKeepsGeneratedResultAndDoesNotBecomeTrainingFailure() {
        let work = ScanWorkState(readyCount: 1, downloadFailureCount: 1)
        XCTAssertEqual(work.label, "1 个结果 · 待下载")
        XCTAssertTrue(work.ready); XCTAssertFalse(work.active)
        XCTAssertEqual(work.failedCount, 0)
        XCTAssertTrue(work.needsRecovery)
        XCTAssertNil(ScanWorkState().label)
    }
    func testPausedTrainingIsRecoverableWhileOldResultRemainsReady() {
        let work = ScanWorkState(readyCount: 1, pausedCount: 1)
        XCTAssertTrue(work.ready)
        XCTAssertTrue(work.needsRecovery)
        XCTAssertFalse(work.active)
        XCTAssertEqual(work.label, "1 个结果 · 已暂停")
    }

    func testLinkedImageActivityDoesNotBecomeAScanResultButStillProtectsItsSource() {
        let work = ScanWorkState(linkedImageActive: true)
        XCTAssertFalse(work.active)
        XCTAssertFalse(work.ready)
        XCTAssertFalse(work.needsRecovery)
        XCTAssertNil(work.label)
        XCTAssertTrue(work.deletionBlocked)
        var analysis = report(); analysis.completeness = 0.72
        let assessment = ScanCaptureAssessment(isComplete: true, analysis: analysis)
        XCTAssertFalse(ScanLibraryCleanup.includes(assessment: assessment, active: work.deletionBlocked))
        XCTAssertTrue(ScanWorkState(activeCount: 1).deletionBlocked)
        XCTAssertFalse(ScanWorkState(readyCount: 1).deletionBlocked)
    }

    func testLibrarySearchMatchesNamesNumbersAndModesWithoutChangingFilters() {
        let fields = ["扫描 16", "企鹅", "物体"]
        XCTAssertTrue(ScanLibrarySearch.matches("16 企鹅", fields: fields))
        XCTAssertTrue(ScanLibrarySearch.matches("物体", fields: fields))
        XCTAssertFalse(ScanLibrarySearch.matches("16 人像", fields: fields))
        XCTAssertTrue(ScanLibrarySearch.matches("  \n", fields: fields))
        XCTAssertTrue(ScanLibrarySearch.matches("AI", fields: ["ai 单图作品"]))
    }
    func testCaptureCardsRenderReadableQualityAndSeparateResultState() throws {
        for width in [320.0, 430.0] {
            let view = VStack(alignment: .leading, spacing: 16) {
                Text("我的扫描").font(.title2.bold()).foregroundStyle(Theme.text)
                HStack(alignment: .top, spacing: 12) {
                    card(verdict: "good", coverage: 0.92, keyframes: 180, number: 8)
                    card(verdict: "poor", coverage: 0.22, keyframes: 12, number: 7)
                }
                Text("覆盖参考来自采集记录，不代表重建质量。")
                    .font(.caption2).foregroundStyle(Theme.tertiary)
            }.padding(20).frame(width: width).background(Theme.background)
                .environment(\.colorScheme, .dark)
            let renderer = ImageRenderer(content: view); renderer.scale = 2
            let image = try XCTUnwrap(renderer.uiImage)
            XCTAssertEqual(image.size.width, width)
            XCTAssertLessThan(image.size.height, 700)
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ProjectHubQA")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try XCTUnwrap(image.pngData()).write(to: folder.appendingPathComponent("library-\(Int(width)).png"))
        }
    }
    private func card(verdict: String, coverage: Double, keyframes: Int, number: Int) -> some View {
        var report = report(); report.verdict = verdict; report.completeness = coverage; report.keyframeCount = keyframes
        let package = ScanPackage(folderURL: URL(fileURLWithPath: "/fixture/\(number).scan"), videoURL: nil,
                                  frameCount: 900, depthFrameCount: 900, skippedFrameCount: 0, createdAt: nil,
                                  modifiedAt: .distantPast, isComplete: true, analysis: report)
        return ScanCard(package: package, title: "扫描 0\(number)",
                        stage: ScanStage(label: ScanWorkState(readyCount: 1, failedCount: number == 7 ? 1 : 0).label!,
                                         color: number == 7 ? Theme.warning : Theme.success, isActive: false))
    }

}
