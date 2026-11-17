import XCTest
import simd
@testable import PocketWorld

/// Automatic scan numbers, the user-facing result names and the live capture signals
/// (speed, aim, distance, sideways travel). Synthetic poses only.
@MainActor
final class ResultAndGuidanceTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let name = "ResultAndGuidanceTests-\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        return UserDefaults(suiteName: name)!
    }

    private func look(from position: SIMD3<Float>, at target: SIMD3<Float>) -> simd_float4x4 {
        let back = -simd_normalize(target - position)
        let right = simd_normalize(simd_cross(SIMD3<Float>(0, 1, 0), back))
        let up = simd_cross(back, right)
        return simd_float4x4(columns: (SIMD4(right, 0), SIMD4(up, 0), SIMD4(back, 0), SIMD4(position, 1)))
    }

    func testUnsavedFramesGuideWithoutIncreasingCoverage() {
        var tracker = ScanCoverageTracker()
        tracker.lockPivot(.zero)
        for step in 0..<72 {
            let angle = Float(step) * .pi / 36
            let pose = look(from: SIMD3(sin(angle), 0.5, cos(angle)), at: .zero)
            tracker.add(transform: pose, timestamp: Double(step) / 30, recordCoverage: false)
        }
        XCTAssertNotNil(tracker.snapshot.currentBin)
        XCTAssertEqual(tracker.snapshot.orbitFraction, 0)
        XCTAssertEqual(tracker.snapshot.completeness(for: .space), 0)
        XCTAssertFalse(tracker.snapshot.loopClosed)
        tracker.refine()
        XCTAssertEqual(tracker.snapshot.orbitFraction, 0)
        tracker.recordSaved(transform: look(from: SIMD3(0, 0.5, 1), at: .zero))
        XCTAssertEqual(tracker.snapshot.orbitFraction, 1.0 / 36, accuracy: 1e-6)
    }

    // MARK: Names

    func testScansAreNumberedOldestFirstAndNumbersNeverChange() {
        let store = ScanNameStore(defaults: defaults())
        store.assignNumbers(oldestFirst: ["a", "b", "c"])
        XCTAssertEqual(store.displayName(for: "a"), "扫描 01")
        XCTAssertEqual(store.displayName(for: "c"), "扫描 03")
        // "c" was deleted; a new scan continues after the highest number, never reusing 03.
        store.assignNumbers(oldestFirst: ["a", "b", "d"])
        XCTAssertEqual(store.displayName(for: "d"), "扫描 04")
        XCTAssertEqual(store.displayName(for: "b"), "扫描 02")

        store.setName("书桌一角", for: "b")
        XCTAssertEqual(store.displayName(for: "b"), "书桌一角")
        store.setName("  ", for: "b")
        XCTAssertEqual(store.displayName(for: "b"), "扫描 02", "an empty name brings the number back")
        XCTAssertNil(store.customName(for: "b"))
    }

    func testNumbersSurviveARestart() {
        let storage = defaults()
        ScanNameStore(defaults: storage).assignNumbers(oldestFirst: ["x", "y"])
        let reopened = ScanNameStore(defaults: storage)
        XCTAssertEqual(reopened.displayName(for: "y"), "扫描 02")
        XCTAssertEqual(ScanNameStore.autoName(123), "扫描 123")
    }

    func testResultsUseTheFriendlyNames() {
        XCTAssertEqual(NativeRoleName.long("preview"), "快速预览")
        XCTAssertEqual(NativeRoleName.long("refined"), "精细重建")
        XCTAssertEqual(NativeRoleName.long("arkit"), "位姿版")
        XCTAssertEqual(NativeRoleName.short("refined"), "精细")
        XCTAssertLessThan(NativeRoleName.order("preview"), NativeRoleName.order("refined"))
    }

    // MARK: Live guidance

    func testEveryModeHasThreeStepsAndPortraitAsksForConsent() {
        for mode in ScanMode.allCases { XCTAssertEqual(mode.steps.count, 3, mode.title) }
        XCTAssertTrue(ScanMode.portrait.steps[0].contains("同意"))
        XCTAssertTrue(ScanMode.space.steps.joined().contains("横着"))
    }

    /// 6 cm every 0.05 s is 1.2 m/s: well past the "slow down" threshold.
    func testWalkingSpeedIsSmoothedFromTimestamps() {
        var fast = ScanCoverageTracker()
        var slow = ScanCoverageTracker()
        for step in 0..<40 {
            let t = Double(step) * 0.05
            fast.add(transform: look(from: SIMD3(Float(step) * 0.06, 1.4, 0), at: SIMD3(Float(step) * 0.06, 1.4, -2)), timestamp: t)
            slow.add(transform: look(from: SIMD3(Float(step) * 0.01, 1.4, 0), at: SIMD3(Float(step) * 0.01, 1.4, -2)), timestamp: t)
        }
        XCTAssertEqual(fast.snapshot.speed, 1.2, accuracy: 0.05)
        XCTAssertGreaterThan(fast.snapshot.speed, ARScanCaptureView.fastSpeed)
        XCTAssertLessThan(slow.snapshot.speed, ARScanCaptureView.fastSpeed)
        XCTAssertLessThan(fast.snapshot.turnRate, 1)

        var untimed = ScanCoverageTracker()
        untimed.add(transform: look(from: .zero, at: SIMD3(0, 0, -1)))
        untimed.add(transform: look(from: SIMD3(0.2, 0, 0), at: SIMD3(0.2, 0, -1)))
        XCTAssertEqual(untimed.snapshot.speed, 0, "no timestamps, no speed")
    }

    /// Facing -Z, walking toward +X is the user's right.
    func testSidewaysTravelKeepsItsSide() {
        var right = ScanCoverageTracker()
        var left = ScanCoverageTracker()
        for step in 0...10 {
            let x = Float(step) * 0.08
            right.add(transform: look(from: SIMD3(x, 1.4, 0), at: SIMD3(x, 1.4, -2)))
            left.add(transform: look(from: SIMD3(-x, 1.4, 0), at: SIMD3(-x, 1.4, -2)))
        }
        XCTAssertEqual(right.snapshot.lateralMeters, 0.8, accuracy: 1e-4)
        XCTAssertEqual(left.snapshot.lateralMeters, -0.8, accuracy: 1e-4)
        XCTAssertEqual(right.snapshot.suggestedDirection(for: .space), .sideways)
    }

    func testAimPointsBackToTheAnchoredPerson() {
        let person = ScanTargetBox(center: SIMD3(0, 0.85, 0), size: SIMD3(0.6, 1.7, 0.45),
                                   yawRadians: 0, source: "lidar", subject: "person")
        func aim(lookingAt target: SIMD3<Float>) -> ScanCoverage {
            var tracker = ScanCoverageTracker(portrait: true)
            tracker.lockPivot(person.simdCenter, axis: person.bodyAxis)
            tracker.add(transform: look(from: SIMD3(0, 1.3, 1.5), at: target))
            return tracker.snapshot
        }
        let facing = aim(lookingAt: SIMD3(0, 1.3, 0))
        XCTAssertNil(facing.aim, "the person is in frame")
        XCTAssertEqual(facing.horizontalDistance ?? 0, 1.5, accuracy: 1e-4)
        // Standing at +Z facing the person (-Z): a view swung toward +X has the person on the left.
        XCTAssertEqual(aim(lookingAt: SIMD3(3, 1.3, 1.0)).aim, .left)
        XCTAssertEqual(aim(lookingAt: SIMD3(-3, 1.3, 1.0)).aim, .right)
        XCTAssertEqual(aim(lookingAt: SIMD3(0, 4.5, 0)).aim, .down, "looking at the ceiling")
        XCTAssertEqual(aim(lookingAt: SIMD3(0, 1.3, 1.45) + SIMD3(0, -1, 0)).aim, .up, "looking at the floor at one's feet")
    }

    /// A glance away shorter than the delay does not flash a warning.
    func testAimWaitsBeforeWarning() {
        var tracker = ScanCoverageTracker()
        tracker.lockPivot(SIMD3(0, 0.1, 0))
        let away = look(from: SIMD3(0, 1, 1.2), at: SIMD3(3, 1, 1.2))
        tracker.add(transform: away, timestamp: 10)
        tracker.add(transform: away, timestamp: 10.3)
        XCTAssertNil(tracker.snapshot.aim)
        tracker.add(transform: away, timestamp: 10.7)
        XCTAssertNotNil(tracker.snapshot.aim)
        tracker.add(transform: look(from: SIMD3(0, 1, 1.2), at: SIMD3(0, 0.1, 0)), timestamp: 10.8)
        XCTAssertNil(tracker.snapshot.aim, "back on target")
    }
}
