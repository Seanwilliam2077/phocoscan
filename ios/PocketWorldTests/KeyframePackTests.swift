import CryptoKit
import XCTest
@testable import PocketWorld

/// The keyframe pack for the cloud 位姿版: selection, the byte layout the server parses
/// (`server/src/keyframe-pack.mjs`) and backward-compatible task requests. Synthetic files only.
final class KeyframePackTests: XCTestCase {
    private func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("KeyframePackTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// A `<scan>/capture/` folder like TrainingPackageWriter writes, with tiny stand-in images.
    private func scan(frames count: Int, moving: Set<Int> = [], masks: Set<Int>? = nil) throws -> URL {
        let folder = try scratch().appendingPathComponent("\(UUID().uuidString.lowercased()).scan")
        let capture = folder.appendingPathComponent("capture")
        for sub in ["images", "masks", "depth"] {
            try FileManager.default.createDirectory(at: capture.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
        var frames: [[String: Any]] = []
        for i in 1...count {
            let name = String(format: "frame_%05d", i)
            try Data([0xff, 0xd8, UInt8(i % 255), 0xff, 0xd9]).write(to: capture.appendingPathComponent("images/\(name).jpg"))
            var frame: [String: Any] = ["file_path": "images/\(name).jpg", "depth_file_path": "depth/\(name).png",
                                        "transform_matrix": [[1, 0, 0, Double(i) * 0.05], [0, 1, 0, 1.4], [0, 0, 1, 0], [0, 0, 0, 1]],
                                        "fl_x": 1400.5, "fl_y": 1400.5, "cx": 960, "cy": 720, "w": 1920, "h": 1440,
                                        "timestamp": 1000.0 + Double(i) / 60]
            if moving.contains(i) { frame["subject_moving"] = true }
            if masks?.contains(i) ?? false {
                try Data([0x89, 0x50, 0x4e, 0x47, UInt8(i % 255)]).write(to: capture.appendingPathComponent("masks/\(name).png"))
                frame["mask_path"] = "masks/\(name).png"
            }
            frames.append(frame)
        }
        let transforms: [String: Any] = ["camera_model": "OPENCV", "fl_x": 1400.5, "frames": frames, "ply_file_path": "points3d.ply"]
        try JSONSerialization.data(withJSONObject: transforms).write(to: capture.appendingPathComponent("transforms.json"))
        try Data(#"{"mode":"person"}"#.utf8).write(to: capture.appendingPathComponent("meta.json"))
        return folder
    }

    /// Splits a pack into its index and files, checking every size and SHA-256.
    private func unpack(_ url: URL) throws -> (index: [String: Any], files: [String: Data]) {
        let bytes = try Data(contentsOf: url)
        XCTAssertEqual(String(decoding: bytes.prefix(8), as: UTF8.self), "PWPACK01")
        let length = Int(bytes[8]) | Int(bytes[9]) << 8 | Int(bytes[10]) << 16 | Int(bytes[11]) << 24
        let index = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes.subdata(in: 12..<(12 + length))) as? [String: Any])
        var offset = 12 + length
        var files: [String: Data] = [:]
        for entry in try XCTUnwrap(index["files"] as? [[String: Any]]) {
            let size = try XCTUnwrap(entry["byteSize"] as? Int), path = try XCTUnwrap(entry["path"] as? String)
            let data = bytes.subdata(in: offset..<(offset + size))
            XCTAssertEqual(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), entry["sha256"] as? String, path)
            files[path] = data
            offset += size
        }
        XCTAssertEqual(offset, bytes.count, "no bytes beyond the index")
        return (index, files)
    }

    func testIndividualFilesReassembleExactly() throws {
        let scan = try scan(frames: 10), id = scan.deletingPathExtension().lastPathComponent
        let built = try XCTUnwrap(KeyframePack.build(scanFolder: scan, captureID: id, into: scratch()))
        let split = try KeyframePack.split(built.url, into: scratch())
        let raw = try XCTUnwrap(Data(base64Encoded: split.indexBase64))
        var result = Data("PWPACK01".utf8), length = UInt32(raw.count).littleEndian
        result.append(Data(bytes: &length, count: 4)); result.append(raw)
        for entry in split.index.files { result.append(try Data(contentsOf: split.folder.appendingPathComponent(entry.sha256))) }
        XCTAssertEqual(result, try Data(contentsOf: built.url))
        XCTAssertEqual(split.index.captureId, id)
    }

    func testSelectionSpreadsOverTheScanAndSkipsMovingFrames() {
        let picked = KeyframePack.select(count: 300, moving: [])
        XCTAssertEqual(picked.count, 64)
        XCTAssertEqual(picked, picked.sorted())
        XCTAssertLessThan(picked.first!, 5)
        XCTAssertGreaterThan(picked.last!, 295)
        var moving = [Bool](repeating: false, count: 40)
        for i in 10..<15 { moving[i] = true }
        XCTAssertEqual(KeyframePack.select(count: 40, moving: moving).count, 35)
        XCTAssertFalse(KeyframePack.select(count: 40, moving: moving).contains(12))
        // Too few still frames: keep everything rather than starve the reconstruction.
        XCTAssertEqual(KeyframePack.select(count: 10, moving: [Bool](repeating: true, count: 10)).count, 10)
    }

    func testPackHasRenumberedKeyframesTheirMasksAndNoDepth() throws {
        let folder = try scan(frames: 20, moving: [4, 9], masks: Set(1...20))
        let captureID = folder.deletingPathExtension().lastPathComponent
        let built = try XCTUnwrap(KeyframePack.build(scanFolder: folder, captureID: captureID, into: try scratch()))
        XCTAssertEqual(built.frameCount, 18)
        XCTAssertTrue(built.masks)
        let bytes = try Data(contentsOf: built.url)
        XCTAssertEqual(built.byteSize, Int64(bytes.count))
        XCTAssertEqual(built.sha256, SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())

        let (index, files) = try unpack(built.url)
        XCTAssertEqual(index["captureId"] as? String, captureID)
        XCTAssertEqual(index["version"] as? Int, 1)
        XCTAssertEqual(files.keys.filter { $0.hasPrefix("images/") }.count, 18)
        XCTAssertEqual(files.keys.filter { $0.hasPrefix("masks/") }.count, 18)
        XCTAssertNotNil(files["meta.json"])
        let transforms = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(files["transforms.json"])) as? [String: Any])
        XCTAssertNil(transforms["ply_file_path"], "the point cloud is not uploaded")
        let frames = try XCTUnwrap(transforms["frames"] as? [[String: Any]])
        XCTAssertEqual(frames.map { $0["file_path"] as? String }, (1...18).map { String(format: "images/image_%06d.jpg", $0) })
        XCTAssertEqual(frames[3]["mask_path"] as? String, "masks/image_000004.png")
        XCTAssertTrue(frames.allSatisfy { $0["depth_file_path"] == nil && $0["subject_moving"] == nil })
        // Frame 5 of the scan became keyframe 4 (frame 4 moved): same pixels, same timestamp.
        XCTAssertEqual(files["images/image_000004.jpg"], Data([0xff, 0xd8, 5, 0xff, 0xd9]))
        XCTAssertEqual(try XCTUnwrap(frames[3]["timestamp"] as? Double), 1000 + 5.0 / 60, accuracy: 1e-9)
    }

    func testMasksAreAllOrNoneAndShortScansFallBackToVideo() throws {
        let partial = try scan(frames: 12, masks: Set(1...11))
        let built = try XCTUnwrap(KeyframePack.build(scanFolder: partial, captureID: "x", into: try scratch()))
        XCTAssertFalse(built.masks)
        let (_, files) = try unpack(built.url)
        XCTAssertTrue(files.keys.allSatisfy { !$0.hasPrefix("masks/") })
        XCTAssertNil(try KeyframePack.build(scanFolder: try scan(frames: KeyframePack.minFrames - 1), captureID: "x", into: try scratch()))
        XCTAssertThrowsError(try KeyframePack.build(scanFolder: try scratch(), captureID: "x", into: try scratch()))
    }

    /// Intents saved before this update still load; the request names the pack only when there is one.
    func testTrainingRequestsStayBackwardCompatible() throws {
        let old = #"{"id":"11111111-1111-4111-8111-111111111111","reconstructionID":"22222222-2222-4222-8222-222222222222","source":{"captureID":"33333333-3333-4333-8333-333333333333","receiptID":"r","videoSHA256":"v","videoByteSize":1,"metadataSHA256":"m","metadataByteSize":1}}"#
        let intent = try JSONDecoder().decode(NativeArkitTrainingIntent.self, from: Data(old.utf8))
        XCTAssertNil(intent.keyframesSha256)
        let plain = try JSONSerialization.jsonObject(with: JSONEncoder().encode(NativeArkitTrainingRequest(id: "a", keyframesSha256: nil))) as? [String: Any]
        XCTAssertNil(plain?["keyframesSha256"])
        let bound = try JSONSerialization.jsonObject(with: JSONEncoder().encode(
            NativeArkitTrainingRequest(id: "a", keyframesSha256: String(repeating: "b", count: 64)))) as? [String: Any]
        XCTAssertEqual(bound?["keyframesSha256"] as? String, String(repeating: "b", count: 64))
        let task = try JSONDecoder().decode(NativeReconstructionTask.self, from: Data(#"{"id":"x","algorithm":"gs_mcmc_arkit_prior","role":"arkit","status":"queued","phase":"p","input":{"keyframes":{"sha256":"s","byteSize":9,"frameCount":40,"masks":true,"mode":"person"}}}"#.utf8))
        XCTAssertTrue(task.trainedFromKeyframes)
        XCTAssertEqual(task.input?.keyframes?.frameCount, 40)
    }
}
