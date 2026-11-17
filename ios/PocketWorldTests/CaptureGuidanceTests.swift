import SceneKit
import XCTest
import simd
@testable import PocketWorld

/// Tap-to-anchor, the guide ring and the 3D review's back-projection. Synthetic inputs only.
final class CaptureGuidanceTests: XCTestCase {
    func testReviewCountsOnlySavedStillViewsAndKeepsLegacyFallback() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("capture"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        XCTAssertNil(CaptureReviewBuilder.savedViewTimes(folder: folder))
        let file = folder.appendingPathComponent("capture/transforms.json")
        try Data(#"{"frames":[{"timestamp":12.345678},{"timestamp":13,"subject_moving":true}]}"#.utf8).write(to: file)
        XCTAssertEqual(CaptureReviewBuilder.savedViewTimes(folder: folder), [12_345_678])
        try Data("broken".utf8).write(to: file)
        XCTAssertEqual(CaptureReviewBuilder.savedViewTimes(folder: folder), [])
    }
    func testSegmentStartsAtTheTappedObjectNotTheCenterOne() {
        let width = 64, height = 48
        var depth = [Float](repeating: 2.0, count: width * height)            // far wall
        for y in 18..<30 { for x in 26..<38 { depth[y * width + x] = 0.8 } } // object at the center
        for y in 4..<12 { for x in 4..<12 { depth[y * width + x] = 0.6 } }   // object top-left
        let tapped = ObjectBoxEstimator.segment(depth: depth, width: width, height: height, seed: (x: 7, y: 7))
        XCTAssertEqual(tapped.count, 8 * 8)
        XCTAssertTrue(tapped.allSatisfy { depth[$0] == 0.6 })
        let center = ObjectBoxEstimator.segment(depth: depth, width: width, height: height)
        XCTAssertTrue(center.allSatisfy { depth[$0] == 0.8 })
        // A tap on the very edge must not read outside the image.
        _ = ObjectBoxEstimator.segment(depth: depth, width: width, height: height, seed: (x: 0, y: height - 1))
    }

    /// Ring segment i must sit at the angles that orbit bin i counts, or the ring would
    /// light up the wrong side of the object.
    func testRingSegmentsLineUpWithCoverageBins() {
        for bin in 0..<ScanCoverage.binCount {
            let theta = CoverageRingNode.angle(bin)
            XCTAssertEqual(ScanCoverageTracker.bin(x: sin(theta), z: cos(theta)), bin)
        }
    }

    func testRingRadiusFollowsTheFootprint() {
        func box(_ side: Float) -> ScanTargetBox {
            ScanTargetBox(center: SIMD3(0, 0.1, 0), size: SIMD3(side, 0.2, side), yawRadians: 0, source: "lidar")
        }
        XCTAssertEqual(box(0.12).ringRadius, 0.125, accuracy: 1e-5)
        XCTAssertEqual(box(0.02).ringRadius, 0.12, accuracy: 1e-5)   // never smaller than 12 cm
        XCTAssertEqual(box(2.4).ringRadius, 1.2, accuracy: 1e-5)     // capped
        XCTAssertEqual(box(0.12).baseCenter, SIMD3<Float>(0, 0, 0))
    }

    func testReviewBackProjectsDepthWithTheRecordedPose() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("review-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("depth"), withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        var depth = [Float](repeating: 1.0, count: 16)
        depth[0] = 9 // beyond the 4 m limit: dropped
        try depth.withUnsafeBufferPointer { Data(buffer: $0) }.write(to: folder.appendingPathComponent("depth/f.f32"))
        try Data([2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 0, 2, 2, 2, 2, 2]).write(to: folder.appendingPathComponent("depth/c.u8"))
        // Camera translated to (1, 2, 3), no rotation; 4×4 image with f = 2, principal point (2, 2).
        let frame = CaptureReviewBuilder.Frame(
            index: 0, videoPTSSeconds: 0, cameraImageWidth: 4, cameraImageHeight: 4,
            cameraToWorldARKit: [[1, 0, 0, 1], [0, 1, 0, 2], [0, 0, 1, 3], [0, 0, 0, 1]],
            intrinsicsPixels: [[2, 0, 2], [0, 2, 2], [0, 0, 1]], trackingState: "normal",
            depth: .init(file: "depth/f.f32", width: 4, height: 4),
            confidence: .init(file: "depth/c.u8", width: 4, height: 4))
        let points = try XCTUnwrap(CaptureReviewBuilder.unproject(frame: frame, aux: frame.depth!, folder: folder, colors: nil))
        // Stride 2 samples pixels (0,0) (2,0) (0,2) (2,2); (0,0) is too far and (2,2) has low confidence.
        XCTAssertEqual(points.count, 2)
        // Pixel (2, 0): x = (2.5 - 2) / 2, y = -(0.5 - 2) / 2, one meter in front (-z).
        let expected = SIMD3<Float>(1 + 0.25, 2 + 0.75, 3 - 1)
        XCTAssertTrue(points.contains { simd_distance($0.0, expected) < 1e-5 })
    }

    /// A surface seen from three views spread over ~40° is green; one seen many times
    /// from (nearly) the same spot is red, however many frames there are.
    func testQualityNeedsSeveralViewsFromDifferentAngles() {
        var volume = QualityVolume(target: nil, cropToTarget: false)
        let point = SIMD3<Float>(0, 0, -1)
        for degrees in [-20, 0, 20] as [Float] {
            let a = degrees * .pi / 180
            volume.add(points: [point], camera: point + SIMD3(sin(a), 0, cos(a)) * 0.5)
        }
        XCTAssertEqual(volume.isGood(at: point), true)

        var still = QualityVolume(target: nil, cropToTarget: false)
        for _ in 0..<10 { still.add(points: [point], camera: SIMD3(0, 0, -0.5)) }
        XCTAssertEqual(still.isGood(at: point), false, "no parallax: stays red")

        var twice = QualityVolume(target: nil, cropToTarget: false)
        twice.add(points: [point], camera: SIMD3(-0.3, 0, -0.6))
        twice.add(points: [point], camera: SIMD3(0.3, 0, -0.6))
        XCTAssertEqual(twice.isGood(at: point), false, "two views are not enough")
        XCTAssertNil(twice.isGood(at: SIMD3(5, 5, 5)), "never seen")
        XCTAssertEqual(volume.goodFraction, 1)
    }

    func testLiveVolumeKeepsOnlyTheAnchoredRegion() {
        let target = ScanTargetBox(center: SIMD3(0, 0.1, -1), size: SIMD3(0.12, 0.2, 0.12), yawRadians: 0, source: "lidar")
        var volume = QualityVolume(target: target, cropToTarget: true)
        volume.add(points: [SIMD3(0, 0.1, -1), SIMD3(2, 0.1, -1), SIMD3(0, 3, -1)], camera: .zero)
        XCTAssertEqual(volume.cells.count, 1)
        XCTAssertEqual(volume.cellSize, target.ringRadius / 6, accuracy: 1e-6)
    }

    func testRowMajorPoseMatchesTheRecordedTranslation() throws {
        let m = try XCTUnwrap(QualityVolume.matrix(rowMajor: [[1, 0, 0, 1], [0, 1, 0, 2], [0, 0, 1, 3], [0, 0, 0, 1]]))
        XCTAssertEqual(m * SIMD4<Float>(0, 0, -1, 1), SIMD4<Float>(1, 2, 2, 1))
    }

    /// Builds the review from a real saved scan folder and renders it offscreen, only
    /// when `POCKETWORLD_REVIEW_SCAN` points at one (raw captures never live in the repo).
    @MainActor func testReviewOfARealScanRenders() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["POCKETWORLD_REVIEW_SCAN"] else {
            throw XCTSkip("Set POCKETWORLD_REVIEW_SCAN to a saved .scan folder to run this test.")
        }
        // "app:<captureID>" reads a scan saved by the app itself (tests on a device).
        let folder = path.hasPrefix("app:")
            ? try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
                .appendingPathComponent("ScanPackages/\(path.dropFirst(4)).scan", isDirectory: true)
            : URL(fileURLWithPath: path)
        let analysis = ScanAnalysis.load(from: folder)
        let started = Date()
        let model = try await CaptureReviewBuilder.build(folder: folder, analysis: analysis)
        print("REVIEW keyframes=\(model.keyframeCount) depthFrames=\(model.depthFrameCount) all=\(model.all.count) near=\(model.near.count) path=\(model.path.count) seconds=\(String(format: "%.2f", Date().timeIntervalSince(started)))")
        XCTAssertGreaterThan(model.keyframeCount, 0)
        XCTAssertGreaterThan(model.all.count, 1000)
        let colored = model.all.colors.filter { $0 != SIMD3<Float>(0.8, 0.8, 0.85) }.count
        XCTAssertGreaterThan(Double(colored) / Double(model.all.count), 0.9, "video colors were matched to the depth frames")
        guard var output = environment["POCKETWORLD_REVIEW_SNAPSHOT"] else { return }
        // "app-tmp:<name>" writes into the test host's temporary folder (tests on a device).
        if output.hasPrefix("app-tmp:") {
            output = FileManager.default.temporaryDirectory.appendingPathComponent(String(output.dropFirst(8))).path
        }
        print("REVIEW goodFraction=\(model.goodFraction.map { String(format: "%.2f", $0) } ?? "nil") nearGood=\(model.near.quality.filter { $0 == 2 }.count) nearWeak=\(model.near.quality.filter { $0 == 1 }.count)")
        let built = ReviewSceneView.build(model)
        let renderer = SCNRenderer(device: MTLCreateSystemDefaultDevice(), options: nil)
        renderer.scene = built.scene
        renderer.pointOfView = built.camera
        for (name, set, original) in [("quality", model.near, false), ("original", model.near, true), ("all", model.all, false)] {
            let cloud = ReviewSceneView.cloud(set, originalColors: original)
            built.scene.rootNode.addChildNode(cloud)
            let image = renderer.snapshot(atTime: 0, with: CGSize(width: 900, height: 1200), antialiasingMode: .multisampling4X)
            try XCTUnwrap(image.pngData()).write(to: URL(fileURLWithPath: output + "-\(name).png"))
            cloud.removeFromParentNode()
        }
    }
}
