import ImageIO
import XCTest
import simd
@testable import PocketWorld

/// The capture plan (M1): keyframe gates, sharpness, the person-stillness check, space
/// loop closure, the nerfstudio package files and the extra analysis advice.
/// Synthetic poses, images and points only.
@MainActor
final class CapturePlanTests: XCTestCase {
    private func look(from position: SIMD3<Float>, at target: SIMD3<Float>) -> simd_float4x4 {
        let back = -simd_normalize(target - position)
        let right = simd_normalize(simd_cross(SIMD3<Float>(0, 1, 0), back))
        let up = simd_cross(back, right)
        return simd_float4x4(columns: (SIMD4(right, 0), SIMD4(up, 0), SIMD4(back, 0), SIMD4(position, 1)))
    }

    private func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("CapturePlanTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    // MARK: Keyframes
    func testBlankFramesNeverIncreaseSavedCandidateCount() {
        var selector = KeyframeSelector(policy: .forMode(.object))
        for t in 0..<20 {
            XCTAssertEqual(selector.sharpnessGate(sharpness: 0, transform: matrix_identity_float4x4, timestamp: Double(t)), .blurry)
        }
        XCTAssertEqual(selector.keptCount, 0)
    }

    /// A slow 60 s orbit at 1 m around an object lands inside the plan's 150–300 range;
    /// the same orbit walked too fast keeps nothing.
    func testObjectOrbitKeyframesLandInThePlanRange() {
        func run(seconds: Double, laps: Double) -> KeyframeSelector {
            var selector = KeyframeSelector(policy: .forMode(.object))
            let fps = 60.0
            for i in 0..<Int(seconds * fps) {
                let t = Double(i) / fps
                let a = Float(t / seconds * laps * 2 * .pi)
                let pose = look(from: SIMD3(sin(a), 0.6, cos(a)), at: .zero)
                if selector.poseGate(transform: pose, timestamp: t) == nil {
                    _ = selector.sharpnessGate(sharpness: 100, transform: pose, timestamp: t)
                }
            }
            return selector
        }
        let slow = run(seconds: 60, laps: 1.5)
        XCTAssertTrue(KeyframeSelector.Policy.forMode(.object).count.contains(slow.keptCount), "\(slow.keptCount)")
        let fast = run(seconds: 4, laps: 1.5) // ~2.4 m/s
        XCTAssertLessThanOrEqual(fast.keptCount, 1)
        XCTAssertGreaterThan(fast.rejectedFast, 100)
    }

    func testKeyframesStopAtTheCapAndSkipBlurryFrames() {
        var policy = KeyframeSelector.Policy.forMode(.portrait)
        policy.count = 3...8
        var selector = KeyframeSelector(policy: policy)
        var t = 0.0
        for i in 0..<40 {
            t += 0.3
            let pose = look(from: SIMD3(Float(i) * 0.1, 1.3, 1.5), at: SIMD3(Float(i) * 0.1, 1.3, 0))
            guard selector.poseGate(transform: pose, timestamp: t) == nil else { continue }
            // Every third frame is far blurrier than the rest.
            _ = selector.sharpnessGate(sharpness: i % 3 == 2 ? 10 : 100, transform: pose, timestamp: t)
        }
        XCTAssertEqual(selector.keptCount, 8)
        XCTAssertEqual(selector.poseGate(transform: look(from: .zero, at: SIMD3(0, 0, -1)), timestamp: t + 1), .full)
        XCTAssertGreaterThan(selector.rejectedBlurry, 0)
    }

    /// A crisp checkerboard measures sharper than the same board box-blurred.
    func testSharpnessPrefersCrispImages() {
        let width = 200, height = 150
        var crisp = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height { for x in 0..<width { crisp[y * width + x] = ((x / 4 + y / 4) % 2 == 0) ? 230 : 20 } }
        var blurred = crisp
        for y in 2..<(height - 2) {
            for x in 2..<(width - 2) {
                var sum = 0
                for dy in -2...2 { for dx in -2...2 { sum += Int(crisp[(y + dy) * width + x + dx]) } }
                blurred[y * width + x] = UInt8(sum / 25)
            }
        }
        var f: [Float] = [], l: [Float] = []
        let sharp = crisp.withUnsafeMutableBytes {
            SharpnessMeter.measure(luma: $0.baseAddress!, width: width, height: height, rowBytes: width,
                                   floatBuffer: &f, laplacian: &l)
        }
        let soft = blurred.withUnsafeMutableBytes {
            SharpnessMeter.measure(luma: $0.baseAddress!, width: width, height: height, rowBytes: width,
                                   floatBuffer: &f, laplacian: &l)
        }
        XCTAssertGreaterThan(try XCTUnwrap(sharp), try XCTUnwrap(soft) * 3)
    }

    // MARK: Person stillness

    func testCameraRaysAndVisionMapping() {
        let k = simd_float3x3(columns: (SIMD3(1000, 0, 0), SIMD3(0, 1000, 0), SIMD3(960, 720, 1)))
        let pose = look(from: SIMD3(0, 1.4, 2), at: SIMD3(0, 1.4, 0))
        let center = SubjectStillnessTracker.ray(pixel: SIMD2(960, 720), intrinsics: k, cameraToWorld: pose)
        XCTAssertEqual(center.direction.z, -1, accuracy: 1e-5)
        // Upright image center ↔ sensor center; upright top (Vision y = 1) ↔ sensor left edge.
        XCTAssertEqual(SubjectStillnessTracker.sensorPixel(visionPoint: CGPoint(x: 0.5, y: 0.5), sensorWidth: 1920, sensorHeight: 1440),
                       SIMD2(960, 720))
        XCTAssertEqual(SubjectStillnessTracker.sensorPixel(visionPoint: CGPoint(x: 0.5, y: 1), sensorWidth: 1920, sensorHeight: 1440).x, 0)
        XCTAssertEqual(SubjectStillnessTracker.horizontalMiss(origin: SIMD3(0, 1, 2), direction: SIMD3(0, 0, -1),
                                                               axis: SIMD2(0.3, 0)), 0.3, accuracy: 1e-5)
    }

    /// Rays toward a still neck agree from every angle; once the person steps 15 cm
    /// aside, two samples in a row flag movement.
    func testStillnessFlagsAPersonWhoMoves() {
        var tracker = SubjectStillnessTracker()
        func sample(angle degrees: Float, neck: SIMD3<Float>) {
            let a = degrees * .pi / 180
            let camera = SIMD3<Float>(1.4 * sin(a), 1.4, 1.4 * cos(a))
            tracker.add(rays: ["neck": (camera, simd_normalize(neck - camera))])
        }
        let neck = SIMD3<Float>(0, 1.45, 0)
        for angle in stride(from: Float(0), through: 60, by: 5) { sample(angle: angle, neck: neck) }
        XCTAssertNotNil(tracker.jointPoints["neck"])
        XCTAssertFalse(tracker.isMoving)
        XCTAssertLessThan(tracker.lastResidual, 0.01)
        // 15 cm sideways, across the line of sight.
        let a: Float = 67.5 * .pi / 180
        let stepped = neck + SIMD3(cos(a), 0, -sin(a)) * 0.15
        sample(angle: 65, neck: stepped)
        XCTAssertFalse(tracker.isMoving, "one off sample is not enough")
        sample(angle: 70, neck: stepped)
        XCTAssertTrue(tracker.isMoving)
        sample(angle: 75, neck: neck)
        XCTAssertFalse(tracker.isMoving, "back in place")
    }

    // MARK: Space loop

    func testSpaceWalkClosesTheLoopOnlyFacingTheStart() {
        func walk(returnFacing: SIMD3<Float>) -> ScanCoverage {
            var tracker = ScanCoverageTracker()
            var t = 0.0
            let ahead = SIMD3<Float>(0, 0, -3)
            for x in stride(from: Float(0), through: 1.6, by: 0.02) {
                tracker.add(transform: look(from: SIMD3(x, 1.4, 0), at: SIMD3(x, 1.4, 0) + ahead), timestamp: t); t += 0.05
            }
            XCTAssertEqual(tracker.snapshot.suggestedDirection(for: .space), .returnToStart)
            XCTAssertLessThan(tracker.snapshot.startSide, 0, "facing ahead, the start is to the left")
            for x in stride(from: Float(1.6), through: 0, by: -0.02) {
                tracker.add(transform: look(from: SIMD3(x, 1.4, 0), at: SIMD3(x, 1.4, 0) + returnFacing), timestamp: t); t += 0.05
            }
            return tracker.snapshot
        }
        let closed = walk(returnFacing: SIMD3(0, 0, -3))
        XCTAssertTrue(closed.loopClosed)
        XCTAssertEqual(closed.suggestedDirection(for: .space), .none)
        XCTAssertGreaterThan(closed.completeness(for: .space), walk(returnFacing: SIMD3(0, 0, 3)).completeness(for: .space))
        XCTAssertFalse(walk(returnFacing: SIMD3(0, 0, 3)).loopClosed, "back at the start but facing away")
    }

    // MARK: Package files

    func testDepthPNGIs16BitMillimeters() throws {
        let url = try scratch().appendingPathComponent("depth.png")
        let values: [UInt16] = [0, 1, 1234, 65535, 4000, 250]
        XCTAssertTrue(TrainingPackageWriter.writePNG16(values, width: 3, height: 2, to: url))
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.bitsPerComponent, 16)
        XCTAssertEqual(image.width, 3)
        XCTAssertEqual(image.bitsPerPixel, 16, "one gray channel")
        // Decoded samples, in the byte order the decoder reports.
        let data = try XCTUnwrap(image.dataProvider?.data as Data?)
        let little = image.bitmapInfo.intersection(.byteOrderMask) == .byteOrder16Little
        var out: [UInt16] = []
        for y in 0..<2 {
            for x in 0..<3 {
                let i = y * image.bytesPerRow + x * 2
                let a = UInt16(data[i]), b = UInt16(data[i + 1])
                out.append(little ? a | b << 8 : a << 8 | b)
            }
        }
        XCTAssertEqual(out, values)
    }

    func testPLYHeaderAndSize() throws {
        let url = try scratch().appendingPathComponent("points3d.ply")
        let points: [(position: SIMD3<Float>, color: SIMD3<UInt8>)] = [(SIMD3(1, 2, 3), SIMD3(255, 0, 10)),
                                                                        (SIMD3(-1, 0, 0.5), SIMD3(1, 2, 3))]
        XCTAssertTrue(TrainingPackageWriter.writePLY(points, to: url))
        let data = try Data(contentsOf: url)
        let end = try XCTUnwrap(data.range(of: Data("end_header\n".utf8)))
        let header = String(decoding: data[..<end.lowerBound], as: UTF8.self)
        XCTAssertTrue(header.contains("element vertex 2"))
        XCTAssertTrue(header.contains("format binary_little_endian 1.0"))
        XCTAssertEqual(data.count, end.upperBound + 2 * 15)
        let x: Float = data[end.upperBound..<end.upperBound + 4].withUnsafeBytes { $0.loadUnaligned(as: Float.self) }
        XCTAssertEqual(x, 1)
    }

    func testPointCloudAveragesPerVoxel() {
        var cloud = PointCloudAccumulator(voxel: 0.1)
        cloud.add(SIMD3(0.01, 0.01, 0.01), color: SIMD3(100, 100, 100))
        cloud.add(SIMD3(0.03, 0.03, 0.03), color: SIMD3(200, 200, 200))
        cloud.add(SIMD3(0.51, 0, 0), color: SIMD3(0, 0, 0))
        XCTAssertEqual(cloud.count, 2)
        let merged = cloud.points().first { $0.position.x < 0.1 }
        XCTAssertEqual(merged?.color, SIMD3(150, 150, 150))
    }

    /// Without keyframes the package still writes a valid transforms.json and meta.json,
    /// and the export zips the folder.
    func testEmptyPackageFinishesAndExports() throws {
        let scan = try scratch().appendingPathComponent("\(UUID().uuidString.lowercased()).scan")
        let writer = try TrainingPackageWriter(root: scan, mode: .portrait)
        let done = expectation(description: "finished")
        writer.finish(meta: ["capture_id": "test"]) { done.fulfill() }
        wait(for: [done], timeout: 5)
        let folder = scan.appendingPathComponent(TrainingPackageWriter.folderName)
        let transforms = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(contentsOf: folder.appendingPathComponent("transforms.json"))) as? [String: Any])
        XCTAssertEqual((transforms["frames"] as? [Any])?.count, 0)
        XCTAssertEqual(transforms["camera_model"] as? String, "OPENCV")
        let meta = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(contentsOf: folder.appendingPathComponent("meta.json"))) as? [String: Any])
        XCTAssertEqual(meta["mode"] as? String, "person")
        XCTAssertEqual(meta["capture_id"] as? String, "test")
        XCTAssertNotNil(meta["coordinate_convention"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("masks").path))
        let zip = try TrainingPackageWriter.exportZip(scanFolder: scan, name: "phocoscan-test")
        XCTAssertEqual(zip.pathExtension, "zip")
        let bytes = try Data(contentsOf: zip)
        XCTAssertEqual(Array(bytes.prefix(2)), [0x50, 0x4b], "a zip file")
        XCTAssertEqual(TrainingPackageWriter.planMode(.space), "room")
    }

    func testRowsAreRowMajor() {
        var m = matrix_identity_float4x4
        m.columns.3 = SIMD4(1, 2, 3, 1)
        XCTAssertEqual(TrainingPackageWriter.rows(m)[0], [1, 0, 0, 1])
        XCTAssertEqual(TrainingPackageWriter.rows(m)[2], [0, 0, 1, 3])
    }

    // MARK: Advice

    func testPortraitAndSpaceAdviceFromThePlan() {
        var portrait = ScanCoverage()
        portrait.orbitBins = [Bool](repeating: true, count: ScanCoverage.binCount)
        let face = ScanAnalyzer().finalize(coverage: portrait, mode: .portrait,
                                           extras: .init(keyframes: 100, keyframeRange: 120...250, movingKeyframes: 30))
        XCTAssertTrue(face.issues.contains("没有拍到清楚的正脸"))
        XCTAssertTrue(face.issues.contains { $0.contains("对方动了") })
        XCTAssertTrue(face.suggestions.contains { $0.contains("头部高度") })
        XCTAssertEqual(face.frontFaceSeen, false)
        XCTAssertEqual(face.keyframeCount, 100)

        var space = ScanCoverage()
        space.travelMeters = 2.5
        let room = ScanAnalyzer().finalize(coverage: space, mode: .space)
        XCTAssertTrue(room.suggestions.contains("最后走回起点，对准开始的画面再结束"))
        XCTAssertEqual(room.loopClosed, false)
        XCTAssertNil(room.frontFaceSeen)
    }

    /// Reports written before this update have none of the new fields and still load.
    func testOlderAnalysisStillDecodes() throws {
        var old = ScanAnalyzer().finalize(coverage: ScanCoverage(), mode: .object)
        old.keyframeCount = nil
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as? [String: Any])
        for key in ["keyframeCount", "movingKeyframeCount", "frontFaceSeen", "loopClosed", "exposureLocked"] {
            json[key] = nil
        }
        let decoded = try JSONDecoder().decode(ScanAnalysis.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(decoded.keyframeCount)
        XCTAssertEqual(decoded.mode, "object")
    }
}
