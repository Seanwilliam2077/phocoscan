import simd
import XCTest
@testable import PocketWorld

final class GameRulesTests: XCTestCase {
    private func example() -> GameSnapshot {
        var state = GameSnapshot()
        state.cards = [
            WorldCard(id: "entry", kind: .entrance), WorldCard(id: "tee", kind: .road, roadShape: .tee), WorldCard(id: "stall", kind: .stall),
            WorldCard(id: "post", kind: .post), WorldCard(id: "cross", kind: .road, roadShape: .cross), WorldCard(id: "reading", kind: .reading),
            WorldCard(id: "rest", kind: .rest), WorldCard(id: "green", kind: .green)
        ]
        state.grid = ["entry", "tee", "stall", "post", "cross", "reading", nil, "rest", "green"]
        return state
    }
    func testProposedLayoutMeetsAllResidentWishes() {
        let state = example()
        XCTAssertTrue(GameRules.validGrid(state))
        XCTAssertEqual(GameRules.wishes(in: state).filter(\.satisfied).count, 3)
    }
    func testRotatingTeeCanBreakRoute() {
        var state = example()
        XCTAssertTrue(GameRules.connectedFromEntrance(to: .rest, in: state))
        state.cards[1].rotation = 2 // S is now closed, so the cross below is unreachable.
        XCTAssertFalse(GameRules.connectedFromEntrance(to: .rest, in: state))
    }
    func testRowBoundaryDoesNotWrapAsNeighbor() {
        XCTAssertNil(GameRules.neighbor(of: 2, direction: 1))
        XCTAssertNil(GameRules.neighbor(of: 3, direction: 3))
        var state = GameSnapshot()
        state.cards = [WorldCard(id: "rest", kind: .rest), WorldCard(id: "green", kind: .green)]
        state.grid[2] = "rest"; state.grid[3] = "green"
        XCTAssertFalse(GameRules.adjacent(.rest, .green, in: state))
    }
    func testBuildingsCannotBeUsedAsInvisibleRoads() {
        var state = GameSnapshot()
        state.cards = [WorldCard(id: "entry", kind: .entrance), WorldCard(id: "lobby", kind: .lobby), WorldCard(id: "post", kind: .post)]
        state.grid[0] = "entry"; state.grid[1] = "lobby"; state.grid[2] = "post"
        XCTAssertFalse(GameRules.connectedFromEntrance(to: .post, in: state))
    }
    func testRoadRotationRotatesAllConnectors() {
        let corner = WorldCard(id: "corner", kind: .road, roadShape: .corner, rotation: 3)
        XCTAssertEqual(corner.connectors, Set([3, 0]))
    }
    func testDuplicateAndUnknownPlacementsAreRejected() {
        var state = example()
        state.grid[6] = "entry"
        XCTAssertFalse(GameRules.validGrid(state))
        state.grid[6] = "missing-card"
        XCTAssertFalse(GameRules.validGrid(state))
    }
    func testCelebrationDependsOnProgressAndLayoutNotWallClock() {
        var state = example()
        XCTAssertFalse(GameRules.canCelebrate(state))
        state.completedQuests = ["first_light", "rest_stop"]
        XCTAssertFalse(GameRules.canCelebrate(state))
        state.pureBuildCompleted = true
        XCTAssertTrue(GameRules.canCelebrate(state))
        state.grid = Array(repeating: nil, count: 9)
        XCTAssertFalse(GameRules.canCelebrate(state))
    }
    func testOldDraftWithoutUploadLockStillDecodes() throws {
        let json = #"{"sessionId":"a","fileName":"a.mov","capturedAt":"2026-10-22T00:00:00Z","durationSeconds":60,"width":1920,"height":1080,"fps":30}"#
        let draft = try JSONDecoder().decode(LocalVideo.self, from: Data(json.utf8))
        XCTAssertNil(draft.uploadStartedAt)
    }
}

final class ScanCoverageTrackerTests: XCTestCase {
    private func pose(_ position: SIMD3<Float>) -> simd_float4x4 {
        var transform = matrix_identity_float4x4 // camera looks down -Z
        transform.columns.3 = SIMD4(position.x, position.y, position.z, 1)
        return transform
    }

    private func look(from position: SIMD3<Float>, at target: SIMD3<Float>) -> simd_float4x4 {
        let back = -simd_normalize(target - position)
        let right = simd_normalize(simd_cross(SIMD3<Float>(0, 1, 0), back))
        let up = simd_cross(back, right)
        return simd_float4x4(columns: (SIMD4(right, 0), SIMD4(up, 0), SIMD4(back, 0), SIMD4(position, 1)))
    }

    /// Circles `target` at `radius`, `height` above it, always looking at it.
    private func orbit(_ tracker: inout ScanCoverageTracker, around target: SIMD3<Float>,
                       radius: Float, height: Float, degrees: ClosedRange<Int> = 0...359) {
        for step in degrees {
            let angle = Float(step) * .pi / 180
            let position = target + SIMD3(radius * sin(angle), height, radius * cos(angle))
            tracker.add(transform: look(from: position, at: target))
            if step % 15 == 0 { tracker.refine() }
        }
        tracker.refine()
    }

    func testPivotIsPlacedInFrontOfFirstPose() {
        var tracker = ScanCoverageTracker()
        XCTAssertTrue(tracker.needsPivot)
        tracker.setPivot(transform: pose(.zero), distance: 1)
        XCTAssertFalse(tracker.needsPivot)
        XCTAssertEqual(tracker.pivot!, SIMD3<Float>(0, 0, -1))
    }

    func testStartingPoseLandsInBottomBin() {
        var tracker = ScanCoverageTracker()
        tracker.setPivot(transform: pose(.zero), distance: 1)
        tracker.add(transform: pose(.zero))
        XCTAssertEqual(tracker.snapshot.currentBin, ScanCoverage.binCount / 2)
        XCTAssertTrue(tracker.snapshot.orbitBins[ScanCoverage.binCount / 2])
        XCTAssertTrue(tracker.snapshot.lookBins[ScanCoverage.binCount - 1])
    }

    /// Regression: standing over a tabletop object (~37° above it) must fill the orbit.
    func testOrbitFromAboveFillsTheRing() {
        var tracker = ScanCoverageTracker()
        let target = SIMD3<Float>(0, 0, 0)
        tracker.setPivot(transform: look(from: SIMD3(0, 0.6, 0.8), at: target), distance: 1.0)
        orbit(&tracker, around: target, radius: 0.8, height: 0.6)
        XCTAssertEqual(tracker.snapshot.orbitFraction, 1, accuracy: 1e-9)
        XCTAssertGreaterThanOrEqual(tracker.snapshot.completeness(for: .object), 0.85)
    }

    /// Regression: a wrong first guess (e.g. LiDAR hit the far wall) is corrected.
    func testWrongInitialPivotIsRefinedFromViewRays() {
        var tracker = ScanCoverageTracker()
        let target = SIMD3<Float>(0, 0, 0)
        tracker.setPivot(transform: look(from: SIMD3(0, 0.3, 0.8), at: target), distance: 3.5)
        orbit(&tracker, around: target, radius: 0.8, height: 0.3)
        XCTAssertTrue(tracker.snapshot.pivotIsRefined)
        XCTAssertLessThan(simd_length(tracker.pivot! - target), 0.05)
        XCTAssertEqual(tracker.snapshot.orbitFraction, 1, accuracy: 1e-9)
    }

    func testSecondHeightFillsInnerRing() {
        var tracker = ScanCoverageTracker()
        let target = SIMD3<Float>(0, 0, 0)
        tracker.setPivot(transform: look(from: SIMD3(0, 0.5, 0.8), at: target), distance: 0.95)
        orbit(&tracker, around: target, radius: 0.8, height: 0.5)            // ~32°: mid band
        orbit(&tracker, around: target, radius: 0.4, height: 1.0, degrees: 0...180) // ~68°: high band
        XCTAssertGreaterThanOrEqual(tracker.snapshot.multiHeightFraction, 0.45)
        XCTAssertGreaterThan(tracker.snapshot.completeness(for: .object), 0.95)
    }

    func testLookingAwayDoesNotCountTheAngle() {
        var tracker = ScanCoverageTracker()
        tracker.setPivot(transform: pose(.zero), distance: 1) // pivot at (0,0,-1)
        tracker.add(transform: look(from: .zero, at: SIMD3(1, 0, 0))) // facing +X, target out of frame
        XCTAssertNotNil(tracker.snapshot.currentBin)
        XCTAssertFalse(tracker.snapshot.orbitBins.contains(true))
    }

    func testTrackingJumpsAreNotCountedAsTravel() {
        var tracker = ScanCoverageTracker()
        tracker.setPivot(transform: pose(.zero), distance: 1)
        tracker.add(transform: pose(.zero))
        tracker.add(transform: pose(SIMD3(3, 0, 0)))
        XCTAssertEqual(tracker.snapshot.travelMeters, 0, accuracy: 1e-6)
    }

    func testBinRejectsDegenerateVectors() {
        XCTAssertNil(ScanCoverageTracker.bin(x: 0, z: 0))
        XCTAssertNil(ScanCoverageTracker.bin(x: .nan, z: 1))
    }
}

final class ScanGuidanceTests: XCTestCase {
    private func coverage(orbit: ClosedRange<Int>, current: Int) -> ScanCoverage {
        var value = ScanCoverage()
        for index in orbit { value.orbitBins[index % ScanCoverage.binCount] = true }
        value.currentBin = current
        return value
    }

    func testStartSuggestsContinuingRight() {
        XCTAssertEqual(coverage(orbit: 18...18, current: 18).suggestedDirection(for: .object), .right(degrees: 10))
    }

    func testNearestGapOnTheLeftWins() {
        XCTAssertEqual(coverage(orbit: 10...30, current: 12).suggestedDirection(for: .object), .left(degrees: 30))
    }

    func testFullOrbitIs85PercentAndAsksForAnotherHeight() {
        let value = coverage(orbit: 0...35, current: 5)
        XCTAssertEqual(value.suggestedDirection(for: .object), .up)
        XCTAssertEqual(value.completeness(for: .object), 0.85, accuracy: 1e-9)
        XCTAssertEqual(value.completedSectorCount, ScanCoverage.sectorCount)
    }

    func testCompleteObjectScanHasNoDirection() {
        var value = coverage(orbit: 0...35, current: 5)
        for index in 0..<18 { value.heightBands[index] = 0b011 }
        XCTAssertEqual(value.suggestedDirection(for: .object), .none)
        XCTAssertEqual(value.completeness(for: .object), 1, accuracy: 1e-9)
    }

    func testSectorsAndGaps() {
        let value = coverage(orbit: 0...17, current: 17)
        XCTAssertEqual(value.completedSectorCount, 6)
        XCTAssertTrue(value.isSectorComplete(0))
        XCTAssertFalse(value.isSectorComplete(6))
        XCTAssertEqual(value.gapsDegrees, [[180, 360]])
    }

    func testSpaceModeGuidanceAndScore() {
        var value = ScanCoverage()
        XCTAssertEqual(value.suggestedDirection(for: .space), .sideways)
        value.travelMeters = 2
        XCTAssertEqual(value.suggestedDirection(for: .space), .returnToStart, "walk back to close the loop")
        for index in 0..<12 { value.lookBins[index] = true } // 120°
        XCTAssertEqual(value.completeness(for: .space), 0.8, accuracy: 1e-9)
        value.loopClosed = true
        XCTAssertEqual(value.suggestedDirection(for: .space), .none)
        XCTAssertEqual(value.completeness(for: .space), 1, accuracy: 1e-9)
    }
}

final class ScanAnalyzerTests: XCTestCase {
    private func look(from position: SIMD3<Float>, at target: SIMD3<Float>) -> simd_float4x4 {
        let back = -simd_normalize(target - position)
        let right = simd_normalize(simd_cross(SIMD3<Float>(0, 1, 0), back))
        let up = simd_cross(back, right)
        return simd_float4x4(columns: (SIMD4(right, 0), SIMD4(up, 0), SIMD4(back, 0), SIMD4(position, 1)))
    }

    private func fullCoverage() -> ScanCoverage {
        var value = ScanCoverage()
        value.orbitBins = [Bool](repeating: true, count: ScanCoverage.binCount)
        value.heightBands = [UInt8](repeating: 0b011, count: ScanCoverage.binCount)
        return value
    }

    /// A slow 45 s orbit in good light: no issues.
    func testSlowBrightOrbitIsGood() {
        var analyzer = ScanAnalyzer()
        for frame in 0..<1350 { // 30 fps × 45 s, one lap
            let angle = Float(frame) / 1350 * 2 * .pi
            analyzer.add(timestamp: Double(frame) / 30,
                         transform: look(from: SIMD3(0.8 * sin(angle), 0.4, 0.8 * cos(angle)), at: .zero),
                         tracking: .normal, ambientLux: 900, featurePoints: 250, hasDepth: true,
                         targetDistance: 0.9)
        }
        let report = analyzer.finalize(coverage: fullCoverage(), mode: .object)
        XCTAssertEqual(report.verdict, "good", report.issues.joined(separator: "; "))
        XCTAssertEqual(report.trackingNormalRatio, 1, accuracy: 1e-9)
        XCTAssertLessThan(report.meanSpeed, 0.5)
        XCTAssertEqual(report.depthFrameRatio, 1, accuracy: 1e-9)
    }

    /// Short, dark, half-orbit scan: flagged with concrete reasons.
    func testShortDarkPartialScanIsPoor() {
        var analyzer = ScanAnalyzer()
        for frame in 0..<60 {
            analyzer.add(timestamp: Double(frame) / 30, transform: look(from: SIMD3(0, 0.4, 0.8), at: .zero),
                         tracking: frame < 30 ? .limited("insufficientFeatures") : .normal,
                         ambientLux: 80, featurePoints: 12, hasDepth: false, targetDistance: 0.9)
        }
        var half = ScanCoverage()
        for index in 0..<12 { half.orbitBins[index] = true }
        let report = analyzer.finalize(coverage: half, mode: .object)
        XCTAssertEqual(report.verdict, "poor")
        XCTAssertTrue(report.issues.contains { $0.contains("光线") })
        XCTAssertTrue(report.issues.contains { $0.contains("纹理") })
        XCTAssertTrue(report.issues.contains { $0.contains("环绕只覆盖了 33%") })
        XCTAssertEqual(report.limitedReasons["insufficientFeatures"], 30)
    }

    func testReportRoundTripsAsJSON() throws {
        var analyzer = ScanAnalyzer()
        analyzer.add(timestamp: 0, transform: matrix_identity_float4x4, tracking: .normal,
                     ambientLux: nil, featurePoints: nil, hasDepth: false, targetDistance: nil)
        let report = analyzer.finalize(coverage: ScanCoverage(), mode: .space)
        let decoded = try JSONDecoder().decode(ScanAnalysis.self, from: JSONEncoder().encode(report))
        XCTAssertEqual(decoded, report)
    }
}

final class ObjectBoxEstimatorTests: XCTestCase {
    func testSegmentsTheNearObjectFromTheBackground() {
        let width = 64, height = 48
        var depth = [Float](repeating: 2.0, count: width * height)       // far wall
        for y in 16..<32 { for x in 22..<42 { depth[y * width + x] = 0.8 } } // object, 20×16 px
        let region = ObjectBoxEstimator.segment(depth: depth, width: width, height: height)
        XCTAssertEqual(region.count, 20 * 16)
        XCTAssertTrue(region.allSatisfy { depth[$0] == 0.8 })
    }

    func testIgnoresLowConfidenceDepth() {
        let width = 32, height = 24
        let depth = [Float](repeating: 1.0, count: width * height)
        let confidence = [UInt8](repeating: 0, count: width * height)
        XCTAssertTrue(ObjectBoxEstimator.segment(depth: depth, width: width, height: height, confidence: confidence).isEmpty)
    }

    /// A 30 cm cube on a table (y = 0) seen from the front and above; table points are dropped.
    func testFitsUprightBoxOnSupportSurface() throws {
        var points: [SIMD3<Float>] = []
        for i in 0..<20 { for j in 0..<20 {
            let a = Float(i) / 19 * 0.3 - 0.15, b = Float(j) / 19 * 0.3
            points.append(SIMD3(a, b, -0.85))                 // front face
            points.append(SIMD3(a, 0.3, -0.85 - b))           // top face
            points.append(SIMD3(a * 3, 0, -0.6 - b))          // table in front
        } }
        let forward = simd_normalize(SIMD3<Float>(0, -0.5, -1))
        let box = try XCTUnwrap(ObjectBoxEstimator.fit(points: points, forward: forward, supportY: 0))
        XCTAssertEqual(box.simdSize.x, 0.3 * 1.08 + 0.02, accuracy: 0.03)
        XCTAssertEqual(box.simdSize.y, 0.3 * 1.08 + 0.01, accuracy: 0.03)
        XCTAssertEqual(box.simdCenter.y - box.simdSize.y / 2, 0, accuracy: 0.001) // stands on the table
        XCTAssertEqual(box.simdCenter.x, 0, accuracy: 0.02)
        XCTAssertEqual(box.yawRadians, 0, accuracy: 1e-4)                      // faces the user
    }

    func testScalingKeepsTheBoxOnItsSurface() {
        let box = ScanTargetBox(center: SIMD3(0, 0.2, -1), size: SIMD3(0.4, 0.4, 0.4), yawRadians: 0, source: "lidar")
        let bigger = box.scaled(by: 1.5)
        XCTAssertEqual(bigger.simdSize.y, 0.6, accuracy: 1e-5)
        XCTAssertEqual(bigger.simdCenter.y - bigger.simdSize.y / 2, 0, accuracy: 1e-5)
        XCTAssertEqual(bigger.source, "adjusted")
        XCTAssertEqual(box.sizeLabel, "40 × 40 × 40 cm")
    }

    func testLockedPivotIsNotMovedByRefinement() {
        var tracker = ScanCoverageTracker()
        tracker.lockPivot(SIMD3(0, 0, -1))
        for step in 0..<90 { // rays converge on a different point; must be ignored
            let angle = Float(step) * .pi / 45
            var t = matrix_identity_float4x4
            let p = SIMD3<Float>(0.8 * sin(angle), 0.3, 0.8 * cos(angle))
            let back = simd_normalize(p)
            let right = simd_normalize(simd_cross(SIMD3<Float>(0, 1, 0), back))
            t.columns = (SIMD4(right, 0), SIMD4(simd_cross(back, right), 0), SIMD4(back, 0), SIMD4(p, 1))
            tracker.add(transform: t)
            tracker.refine()
        }
        XCTAssertEqual(tracker.pivot!, SIMD3<Float>(0, 0, -1))
    }

    func testAnalysisCarriesTheTargetBox() throws {
        var analyzer = ScanAnalyzer()
        analyzer.add(timestamp: 0, transform: matrix_identity_float4x4, tracking: .normal,
                     ambientLux: nil, featurePoints: nil, hasDepth: true, targetDistance: 1)
        var report = analyzer.finalize(coverage: ScanCoverage(), mode: .object)
        report.targetBox = ScanTargetBox(center: SIMD3(0, 0.1, -1), size: SIMD3(0.2, 0.2, 0.2), yawRadians: 0.5, source: "lidar")
        let decoded = try JSONDecoder().decode(ScanAnalysis.self, from: JSONEncoder().encode(report))
        XCTAssertEqual(decoded.targetBox, report.targetBox)
    }
}

final class RenderBudgetTests: XCTestCase {
    private let gb: UInt64 = 1_073_741_824

    func testTiersByMemory() {
        let flagship = RenderBudget.forDevice(physicalMemory: 8 * gb, thermal: .nominal, screenScale: 3)
        XCTAssertEqual(flagship.tier, .flagship)
        XCTAssertEqual(flagship.maxPoints, 1_500_000)
        XCTAssertEqual(flagship.maxSHDegree, 3)
        XCTAssertEqual(flagship.maxScale, 2.0)
        XCTAssertEqual(flagship.preferredFPS, 60)
        XCTAssertEqual(RenderBudget.forDevice(physicalMemory: 6 * gb, thermal: .nominal, screenScale: 3).tier, .mainstream)
        let entry = RenderBudget.forDevice(physicalMemory: 4 * gb, thermal: .nominal, screenScale: 2)
        XCTAssertEqual(entry.tier, .entry)
        XCTAssertEqual(entry.maxSHDegree, 0)
    }

    func testScaleNeverExceedsScreen() {
        let budget = RenderBudget.forDevice(physicalMemory: 8 * gb, thermal: .nominal, screenScale: 1)
        XCTAssertEqual(budget.maxScale, 1)
        XCTAssertEqual(budget.minScale, 1)
    }

    func testHotDeviceLowersBudget() {
        let hot = RenderBudget.forDevice(physicalMemory: 8 * gb, thermal: .serious, screenScale: 3)
        XCTAssertTrue(hot.thermalReduced)
        XCTAssertEqual(hot.maxPoints, 900_000)
        XCTAssertEqual(hot.maxSHDegree, 1)
        XCTAssertEqual(hot.maxScale, hot.minScale)
        XCTAssertEqual(hot.preferredFPS, 30)
    }

    func testImportancePrefersOpaqueLargeSplats() {
        let big = SplatPruning.importance(opacity: 0.9, scale: SIMD3(0.1, 0.1, 0.1))
        let faint = SplatPruning.importance(opacity: 0.05, scale: SIMD3(0.1, 0.1, 0.1))
        let tiny = SplatPruning.importance(opacity: 0.9, scale: SIMD3(0.001, 0.001, 0.001))
        XCTAssertGreaterThan(big, faint)
        XCTAssertGreaterThan(big, tiny)
        XCTAssertEqual(SplatPruning.importance(opacity: .nan, scale: SIMD3(1, 1, 1)), 0)
        XCTAssertEqual(SplatPruning.importance(opacity: 1, scale: SIMD3(0, 1, 1)), 0)
    }

    func testTopIndicesKeepsMostImportantInFileOrder() {
        let scores: [Float] = [0.1, 0.9, 0.3, 0.8, 0.05]
        XCTAssertEqual(SplatPruning.topIndices(scores, count: 2), [1, 3])
        XCTAssertEqual(SplatPruning.topIndices(scores, count: 10), [0, 1, 2, 3, 4])
        XCTAssertEqual(SplatPruning.topIndices(scores, count: 0), [])
    }

    func testSHTruncationKeepsLowBands() {
        let sh3 = (0..<16).map { SIMD3<Float>(repeating: Float($0)) }
        XCTAssertEqual(SplatPruning.truncatedSH(sh3, degree: 0).count, 1)
        XCTAssertEqual(SplatPruning.truncatedSH(sh3, degree: 1).count, 4)
        XCTAssertEqual(SplatPruning.truncatedSH(sh3, degree: 2).count, 9)
        XCTAssertEqual(SplatPruning.truncatedSH(sh3, degree: 3), sh3)
        XCTAssertEqual(SplatPruning.truncatedSH(sh3, degree: 1).last, SIMD3<Float>(repeating: 3))
    }

    func testGovernorDropsFastAndRecoversSlowly() {
        var governor = ResolutionGovernor(scale: 2.0, minScale: 1.0, maxScale: 2.0)
        let budget = 1.0 / 30
        var changed: CGFloat?
        for _ in 0..<ResolutionGovernor.window { changed = governor.record(gpuSeconds: budget, frameBudget: budget) ?? changed }
        XCTAssertEqual(changed ?? 0, 1.85, accuracy: 1e-9)          // slow frames: drop one step
        changed = nil
        for _ in 0..<(ResolutionGovernor.window * 2) { changed = governor.record(gpuSeconds: budget * 0.2, frameBudget: budget) ?? changed }
        XCTAssertNil(changed)                                        // two cheap windows: not yet
        for _ in 0..<ResolutionGovernor.window { changed = governor.record(gpuSeconds: budget * 0.2, frameBudget: budget) ?? changed }
        XCTAssertEqual(changed ?? 0, 1.95, accuracy: 1e-9)           // third cheap window: climb back
    }

    func testGovernorRespectsRange() {
        var governor = ResolutionGovernor(scale: 3, minScale: 1, maxScale: 1.5)
        XCTAssertEqual(governor.scale, 1.5)
        governor.setRange(minScale: 1, maxScale: 1)
        XCTAssertEqual(governor.scale, 1)
        for _ in 0..<(ResolutionGovernor.window * 3) { XCTAssertNil(governor.record(gpuSeconds: 1, frameBudget: 1.0 / 30)) }
    }
}
