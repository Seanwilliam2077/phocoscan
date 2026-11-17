import XCTest
import UIKit
import Security
@testable import PocketWorld

@MainActor final class LibraryDeletionTests: XCTestCase {
    func testCleanupOnlyIncludesDisplayedCoverageBelow80AndRechecksActivity() {
        func assessment(_ coverage: Double) -> ScanCaptureAssessment {
            var report = ScanAnalyzer().finalize(coverage: ScanCoverage(), mode: .object)
            report.completeness = coverage
            return ScanCaptureAssessment(isComplete: true, analysis: report)
        }
        for value in [0.0, 0.72, 0.79, 0.7949] {
            XCTAssertTrue(ScanLibraryCleanup.includes(assessment: assessment(value), active: false))
            XCTAssertFalse(ScanLibraryCleanup.includes(assessment: assessment(value), active: true), "New processing must invalidate a prepared cleanup")
        }
        for value in [0.795, 0.7999, 0.80, 0.81, 1, -0.1, 1.1, .nan, .infinity] {
            XCTAssertFalse(ScanLibraryCleanup.includes(assessment: assessment(value), active: false), "Keep 80%, invalid and unknown coverage: \(value)")
        }
        XCTAssertEqual(assessment(0.795).coverageText, "覆盖参考 80%")
        XCTAssertFalse(ScanLibraryCleanup.includes(assessment: nil, active: false), "Single-image works are not measured scans")
        XCTAssertFalse(ScanLibraryCleanup.includes(assessment: ScanCaptureAssessment(isComplete: false, analysis: nil), active: false))
    }

    func testScanAndImageSectionsNeverMix() {
        XCTAssertEqual(ScanLibrarySection.allCases.count, 2)
        for section in ScanLibrarySection.allCases {
            XCTAssertNotEqual(section.includes(isScan: true), section.includes(isScan: false))
        }
        XCTAssertTrue(ScanLibrarySection.scans.includes(isScan: true))
        XCTAssertTrue(ScanLibrarySection.images.includes(isScan: false))
    }

    func testCoverageCleanupRemovesOnlySyntheticScanAndPreservesIndependentImageBytes() async throws {
        let base = "https://cleanup-\(UUID().uuidString.lowercased()).invalid"
        DeleteProtocol.handler = { request in
            if request.request.url?.path == "/health" { request.respond(200, ["ok": true]) }
            else if request.request.url?.path == "/v1/auth/anonymous" { request.respond(200, ["userId": "11111111-1111-4111-8111-111111111111", "token": "synthetic-test-only"]) }
            else { request.respond(500, ["error": ["code": "unexpected", "message": "No image delete or upload is allowed"]]) }
        }
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [DeleteProtocol.self]
        let cloud = CaptureV2UploadStore(configuration: config)
        let api = cloud.imageAPI
        _ = try await api.connect(to: base)
        let imageFolder = try ImageGenerationStore.directory(identity: XCTUnwrap(api.connectionIdentity))
        let id = UUID().uuidString.lowercased()
        let scan = try ARScanRecorder.packagesDirectory().appendingPathComponent(id + ".scan")
        let untouched = try ARScanRecorder.packagesDirectory().appendingPathComponent(UUID().uuidString.lowercased() + ".scan")
        defer {
            try? FileManager.default.removeItem(at: scan); try? FileManager.default.removeItem(at: untouched)
            cleanup(imageFolder, base: base); DeleteProtocol.handler = nil
        }
        for folder in [scan, untouched] {
            try FileManager.default.createDirectory(at: folder.appendingPathComponent("ondevice.previous.synthetic"), withIntermediateDirectories: true)
            try Data("synthetic source".utf8).write(to: folder.appendingPathComponent("source.txt"))
            try Data("synthetic model".utf8).write(to: folder.appendingPathComponent("ondevice.previous.synthetic/scene.ply"))
        }
        let images = ImageGenerationStore(api: api)
        let picture = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { context in
            UIColor.orange.setFill(); context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
        let imageID = try images.add(image: picture, scanSource: ScanSubjectPhoto.Source(
            captureID: id, file: "images/image_000001.jpg", timestamp: 1, selection: "synthetic"))
        let sourceURL = try XCTUnwrap(images.sourceURL(imageID))
        let before = try Data(contentsOf: sourceURL)
        let indexBefore = try Data(contentsOf: imageFolder.appendingPathComponent("library.json"))
        let kept = ImageGenerationStore(api: api)
        XCTAssertEqual(kept.entries.first?.scanSource?.captureID, id)
        let deleted = await cloud.deleteScan(folderURL: scan, preserveLinkedImages: true)
        XCTAssertTrue(deleted, cloud.errorMessage ?? "")
        XCTAssertFalse(FileManager.default.fileExists(atPath: scan.path))
        XCTAssertEqual(try Data(contentsOf: untouched.appendingPathComponent("source.txt")), Data("synthetic source".utf8))
        XCTAssertEqual(try Data(contentsOf: untouched.appendingPathComponent("ondevice.previous.synthetic/scene.ply")), Data("synthetic model".utf8))
        XCTAssertEqual(try Data(contentsOf: sourceURL), before)
        XCTAssertEqual(try Data(contentsOf: imageFolder.appendingPathComponent("library.json")), indexBefore)
        XCTAssertEqual(ImageGenerationStore(api: api).entries.map(\.id), [imageID])
    }

    func testRemoteFailureKeepsLocalMaterialAnd404RetryRemovesOnlySelectedEntry() async throws {
        let (api, store, entry, folder, base) = try await fixture()
        defer { cleanup(folder,base:base); DeleteProtocol.handler = nil }
        let source = try XCTUnwrap(store.sourceURL(entry.id))
        DeleteProtocol.handler = { request in request.respond(503, ["error":["code":"offline","message":"test unavailable"]]) }
        let failed = await store.delete(entry.id)
        XCTAssertFalse(failed)
        XCTAssertTrue(FileManager.default.fileExists(atPath:source.path))
        XCTAssertEqual(store.entries.map(\.id),[entry.id])
        DeleteProtocol.handler = { request in request.respond(404,["error":["code":"not_found","message":"already removed"]]) }
        let deleted = await store.delete(entry.id)
        XCTAssertTrue(deleted)
        XCTAssertFalse(FileManager.default.fileExists(atPath:source.path))
        XCTAssertTrue(ImageGenerationStore(api:api).entries.isEmpty)
    }
    func testLateListCannotReviveDeletedEntry() async throws {
        let (api,store,entry,folder,base) = try await fixture()
        defer { cleanup(folder,base:base); DeleteProtocol.handler = nil }
        let arrived = expectation(description:"GET in flight")
        let holder = HeldRequest()
        DeleteProtocol.handler = { request in
            if request.request.httpMethod == "GET" { holder.set(request); arrived.fulfill() }
            else { request.respond(200,["ok":true]) }
        }
        let otherScreen = ImageGenerationStore(api:api)
        let refresh = Task { await otherScreen.refresh() }
        await fulfillment(of:[arrived],timeout:3)
        let deleted = await store.delete(entry.id)
        XCTAssertTrue(deleted)
        let image = try JSONSerialization.jsonObject(with:JSONEncoder().encode(entry.image))
        holder.get()?.respond(200,["images":[image]])
        await refresh.value
        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertTrue(ImageGenerationStore(api:api).entries.isEmpty, "Another screen cannot persist a stale deleted entry")
    }
    private func fixture() async throws -> (APIClient,ImageGenerationStore,ImageGenerationStore.Entry,URL,String) {
        let base="https://delete-\(UUID().uuidString.lowercased()).invalid"
        DeleteProtocol.handler = { request in
            if request.request.url?.path == "/health" { request.respond(200,["ok":true]) }
            else { request.respond(200,["userId":"11111111-1111-4111-8111-111111111111","token":"synthetic-test-only"]) }
        }
        let config=URLSessionConfiguration.ephemeral;config.protocolClasses=[DeleteProtocol.self]
        let api=APIClient(configuration:config);_ = try await api.connect(to:base)
        let store=ImageGenerationStore(api:api)
        let image=UIGraphicsImageRenderer(size:CGSize(width:8,height:8)).image { context in UIColor.red.setFill();context.fill(CGRect(x:0,y:0,width:8,height:8)) }
        let id=try store.add(image:image)
        var entry=try XCTUnwrap(store.entries.first);entry.submitted=true;entry.image.status="failed"
        let folder=try ImageGenerationStore.directory(identity:XCTUnwrap(api.connectionIdentity))
        try JSONEncoder().encode([entry]).write(to:folder.appendingPathComponent("library.json"))
        XCTAssertEqual(id,entry.id)
        return (api,ImageGenerationStore(api:api),entry,folder,base)
    }
    private func cleanup(_ folder:URL,base:String) {
        try? FileManager.default.removeItem(at:folder)
        SecItemDelete([kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:"com.pocketworld.player",kSecAttrAccount as String:CredentialStore.account(base)] as CFDictionary)
    }
}
private final class HeldRequest: @unchecked Sendable {
    private let lock=NSLock();private var value:DeleteProtocol?
    func set(_ value:DeleteProtocol) { lock.lock();defer {lock.unlock()};self.value=value }
    func get()->DeleteProtocol? { lock.lock();defer {lock.unlock()};return value }
}
private final class DeleteProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((DeleteProtocol)->Void)?
    override class func canInit(with request:URLRequest)->Bool { true }
    override class func canonicalRequest(for request:URLRequest)->URLRequest { request }
    override func startLoading() { Self.handler?(self) }
    override func stopLoading() {}
    func respond(_ status:Int,_ json:[String:Any]) {
        let response=HTTPURLResponse(url:request.url!,statusCode:status,httpVersion:nil,headerFields:["Content-Type":"application/json"])!
        client?.urlProtocol(self,didReceive:response,cacheStoragePolicy:.notAllowed)
        client?.urlProtocol(self,didLoad:try! JSONSerialization.data(withJSONObject:json))
        client?.urlProtocolDidFinishLoading(self)
    }
}
