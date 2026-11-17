import XCTest
import Foundation
import SwiftUI
@testable import PocketWorld

/// Synthetic contract fixtures only: no camera capture, GPU job or Metal frame
/// is represented by these tests. Execute XCTest on the Mac before device use.
final class NativeReconstructionTests: XCTestCase {
    private let captureID = "11111111-1111-4111-8111-111111111111"
    private let receiptID = "22222222-2222-4222-8222-222222222222"
    private let reconstructionID = "33333333-3333-4333-8333-333333333333"
    private let ffID = "44444444-4444-4444-8444-444444444444"
    private let sfmID = "55555555-5555-4555-8555-555555555555"
    private let videoHash = String(repeating: "a", count: 64)
    private let metadataHash = String(repeating: "b", count: 64)

    private func capture(complete: Bool = true) -> CaptureV2Status {
        CaptureV2Status(id: captureID, environment: "unknown", consentVersion: "capture-evaluation-2026-11-02-v1",
            status: complete ? "rgb_metadata_verified" : "draft",
            rgb: .init(sha256: videoHash, byteSize: 100, mime: "video/quicktime"),
            metadata: .init(sha256: metadataHash, byteSize: 200, mime: "application/json"),
            receipt: complete ? .init(captureReceiptId: receiptID, verifiedAt: "2026-11-03T00:00:00Z",
                scope: "rgb_metadata_verified", frameCount: 16, depthFrameCount: 0,
                depthStatus: "not_available", decodeVerified: true) : nil)
    }
    private func variant() -> ReconstructionVariant {
        let prefix = "/v2/video-reconstructions/\(reconstructionID)/results/\(ffID)"
        return ReconstructionVariant(id: ffID, role: "preview", algorithm: "gs_worldmirror2", status: "ready",
            format: "splat", shDegree: 0, pointCount: 1, byteSize: 32, sha256: String(repeating: "c", count: 64),
            filePath: prefix + "/file", cameraPath: prefix + "/cameras",
            cameraSha256: String(repeating: "d", count: 64), cameraByteSize: 100)
    }
    private func reconstruction(sfmStatus: String = "failed", ffReady: Bool = true) -> NativeReconstruction {
        NativeReconstruction(id: reconstructionID, title: "SYNTHETIC TEST ONLY", sourceKind: "native_arkit_capture",
            captureId: captureID, captureReceiptId: receiptID, sourceVideoSha256: videoHash, sourceByteSize: 100,
            sourceMetadataSha256: metadataHash, sourceMetadataByteSize: 200, status: "partial", createdAt: "2026-11-03T00:00:00Z",
            tasks: [
                NativeReconstructionTask(id: ffID, algorithm: "gs_worldmirror2", role: "preview", status: ffReady ? "ready" : "processing",
                    phase: "fixture", error: nil, result: ffReady ? variant() : nil, replacementId: nil, archivedAt: nil),
                NativeReconstructionTask(id: sfmID, algorithm: "gs_mcmc", role: "refined", status: sfmStatus,
                    phase: "fixture", error: sfmStatus == "failed" ? .init(code: "fixture_failed", message: "Synthetic failure") : nil,
                    result: nil, replacementId: nil, archivedAt: nil)
            ], previousAttempts: [])
    }
    private func changed(_ value: NativeReconstruction, _ changes: [String: Any]) throws -> NativeReconstruction {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
        changes.forEach { object[$0.key] = $0.value }
        return try JSONDecoder().decode(NativeReconstruction.self, from: JSONSerialization.data(withJSONObject: object))
    }
    private var identity: APIConnectionIdentity {
        APIConnectionIdentity(base: "https://fixture.invalid", userID: "66666666-6666-4666-8666-666666666666")
    }

    func testSubjectPackBindingIsValidatedAndPersistsAcrossRestart() throws {
        let source = try NativeReconstructionSource(status: capture())
        let sha = String(repeating: "e", count: 64)
        var task = try XCTUnwrap(reconstruction().task(role: "refined"))
        task.input = .init(keyframes: .init(sha256: sha, frameCount: 64, masks: true))
        XCTAssertNoThrow(try task.validate(reconstructionID: reconstructionID))
        task.input = .init(keyframes: .init(sha256: sha, frameCount: 64, masks: false))
        XCTAssertThrowsError(try task.validate(reconstructionID: reconstructionID))
        var quick = try XCTUnwrap(reconstruction().task(role: "preview"))
        quick.input = .init(keyframes: .init(sha256: sha, frameCount: 64, masks: true))
        XCTAssertThrowsError(try quick.validate(reconstructionID: reconstructionID))
        var request = NativeVersionRequest(source: source, roles: ["refined"])
        request.keyframesSha256 = sha
        XCTAssertEqual(try JSONDecoder().decode(NativeVersionRequest.self, from: JSONEncoder().encode(request)), request)
        var retry = try NativeReconstructionRetry.create(reconstruction: reconstruction(), task: try XCTUnwrap(reconstruction().task(role: "refined")), source: source, existing: nil)
        retry.keyframesSha256 = sha
        XCTAssertEqual(try JSONDecoder().decode(NativeReconstructionRetry.self, from: JSONEncoder().encode(retry)), retry)
    }

    private let arkitID = "77777777-7777-4777-8777-777777777777"
    private func arkitTask(ready: Bool) -> NativeReconstructionTask {
        let prefix = "/v2/video-reconstructions/\(reconstructionID)/results/\(arkitID)"
        let result = ReconstructionVariant(id: arkitID, role: "arkit", algorithm: "gs_mcmc_arkit_prior", status: "ready",
            format: "ply", shDegree: 3, pointCount: 1, byteSize: 300, sha256: String(repeating: "e", count: 64),
            filePath: prefix + "/file", cameraPath: prefix + "/cameras",
            cameraSha256: String(repeating: "f", count: 64), cameraByteSize: 100)
        return NativeReconstructionTask(id: arkitID, algorithm: "gs_mcmc_arkit_prior", role: "arkit",
            status: ready ? "ready" : "queued", phase: "fixture", error: nil, result: ready ? result : nil,
            replacementId: nil, archivedAt: nil)
    }
    private func withArkit(_ value: NativeReconstruction, ready: Bool) -> NativeReconstruction {
        NativeReconstruction(id: value.id, title: value.title, sourceKind: value.sourceKind, captureId: value.captureId,
            captureReceiptId: value.captureReceiptId, sourceVideoSha256: value.sourceVideoSha256,
            sourceByteSize: value.sourceByteSize, sourceMetadataSha256: value.sourceMetadataSha256,
            sourceMetadataByteSize: value.sourceMetadataByteSize, status: value.status, createdAt: value.createdAt,
            tasks: value.tasks + [arkitTask(ready: ready)], previousAttempts: value.previousAttempts)
    }

    func testOptionalCloudArkitTaskValidatesAlongsideFFAndSfM() throws {
        let source = try NativeReconstructionSource(status: capture())
        let value = withArkit(reconstruction(), ready: true)
        XCTAssertNoThrow(try value.validated(source: source))
        XCTAssertEqual(value.readyResults.map(\.role).sorted(), ["arkit", "preview"])
        XCTAssertEqual(value.task(role: "arkit")?.title, "位姿版")
        // Each version can be requested independently.
        var tasks = value.tasks
        tasks.removeAll { $0.role == "refined" }
        let missingSfM = try changed(value, ["tasks": try JSONSerialization.jsonObject(with: JSONEncoder().encode(tasks))])
        XCTAssertNoThrow(try missingSfM.validated(source: source))
        // External videos carry no ARKit poses, so an ARKit variant is never valid there.
        let arkitResult = try XCTUnwrap(value.task(role: "arkit")?.result)
        XCTAssertNoThrow(try arkitResult.validate(reconstructionID: reconstructionID))
        XCTAssertThrowsError(try arkitResult.validate(studyID: reconstructionID))
    }

    func testArkitTrainingIntentIsReusedAndBoundToItsSource() throws {
        let source = try NativeReconstructionSource(status: capture()), value = reconstruction()
        let intent = try NativeArkitTrainingIntent.create(reconstruction: value, source: source, existing: nil)
        XCTAssertNotNil(UUID(uuidString: intent.id))
        XCTAssertEqual(try NativeArkitTrainingIntent.create(reconstruction: value, source: source, existing: intent), intent)
        let foreign = NativeArkitTrainingIntent(id: intent.id, reconstructionID: UUID().uuidString.lowercased(), source: source)
        XCTAssertThrowsError(try NativeArkitTrainingIntent.create(reconstruction: value, source: source, existing: foreign))
        // Once the server shows the task, no new intent is created.
        XCTAssertThrowsError(try NativeArkitTrainingIntent.create(reconstruction: withArkit(value, ready: false),
                                                                  source: source, existing: nil))
    }

    func testCacheWrittenBeforeArkitTrainingStillLoads() throws {
        let legacy = Data(#"{"results":{},"acceptedStarts":{},"retries":{}}"#.utf8)
        let cache = try JSONDecoder().decode(NativeReconstructionCache.self, from: legacy)
        XCTAssertTrue(cache.arkitTrainings.isEmpty)
        XCTAssertTrue(try JSONDecoder().decode(NativeReconstructionCache.self, from: Data("{}".utf8)).results.isEmpty)
    }

    func testNativeSourceRejectsExternalKindChangedMetadataAndForeignResultPath() throws {
        let source = try NativeReconstructionSource(status: capture()), value = reconstruction()
        XCTAssertNoThrow(try value.validated(source: source))
        XCTAssertThrowsError(try changed(value, ["sourceKind": "external_rgb_video"]).validated(source: source))
        XCTAssertThrowsError(try changed(value, ["sourceMetadataSha256": String(repeating: "e", count: 64)]).validated(source: source))
        XCTAssertThrowsError(try changed(value, ["captureReceiptId": UUID().uuidString]).validated(source: source))
        let original = variant()
        let foreign = ReconstructionVariant(id: original.id, role: original.role, algorithm: original.algorithm,
            status: original.status, format: original.format, shDegree: original.shDegree,
            pointCount: original.pointCount, byteSize: original.byteSize, sha256: original.sha256,
            filePath: "https://other.invalid/model.splat", cameraPath: original.cameraPath,
            cameraSha256: original.cameraSha256, cameraByteSize: original.cameraByteSize)
        XCTAssertThrowsError(try foreign.validate(reconstructionID: reconstructionID))
        XCTAssertThrowsError(try original.validate(studyID: reconstructionID))
    }
    func testSuccessfulVariantCannotDisappearWhileOtherBranchChanges() throws {
        let source = try NativeReconstructionSource(status: capture()), ready = reconstruction()
        XCTAssertNoThrow(try reconstruction(sfmStatus: "processing").validated(source: source, previous: ready))
        XCTAssertThrowsError(try reconstruction(sfmStatus: "processing", ffReady: false).validated(source: source, previous: ready))
    }
    func testRetryIsOnlyForFailedBranchAndReusesItsDurableUUID() throws {
        let source = try NativeReconstructionSource(status: capture()), value = reconstruction()
        let failed = try XCTUnwrap(value.task(role: "refined"))
        let intent = try NativeReconstructionRetry.create(reconstruction: value, task: failed, source: source, existing: nil)
        XCTAssertEqual(try NativeReconstructionRetry.create(reconstruction: value, task: failed, source: source, existing: intent), intent)
        XCTAssertThrowsError(try NativeReconstructionRetry.create(reconstruction: value, task: value.tasks[0], source: source, existing: nil))
        let blocked = reconstruction(sfmStatus: "blocked")
        XCTAssertThrowsError(try NativeReconstructionRetry.create(reconstruction: blocked, task: blocked.tasks[1], source: source, existing: nil))
    }
    func testGrowthUsesOnlyUniqueNativeCaptureReceipts() {
        XCTAssertEqual(CaptureV2UploadStore.verifiedReceiptCount(captures: [capture(), capture(), capture(complete: false)]), 1)
        XCTAssertEqual(CaptureV2UploadStore.verifiedReceiptCount(captures: [capture(complete: false)]), 0)
        // Neither reconstruction count nor task/result status is an input here.
    }

    @MainActor func testLostRetryResponseSurvivesRestartAndReplaysTheSameUUIDWithoutLosingFF() async throws {
        let memory = MemoryPersistence(), transport = FakeTransport(identity: identity, remote: reconstruction())
        let first = NativeReconstructionStore(transport: transport, persistence: memory)
        first.configure(identity: identity, captures: [capture()], connected: true)
        await first.refresh(captureID: captureID)
        transport.loseNextRetry = true
        await first.retry(captureID: captureID, failedTaskID: sfmID)
        XCTAssertEqual(first.result(captureID: captureID)?.readyResults, [variant()])
        XCTAssertTrue(first.hasPendingRetry(captureID))
        let savedID = try XCTUnwrap(transport.retryIDs.first)
        let restarted = NativeReconstructionStore(transport: transport, persistence: memory)
        restarted.configure(identity: identity, captures: [capture()], connected: true)
        await restarted.refresh(captureID: captureID)
        XCTAssertEqual(transport.retryIDs, [savedID, savedID])
        XCTAssertEqual(restarted.result(captureID: captureID)?.task(role: "refined")?.id, savedID)
        XCTAssertEqual(restarted.result(captureID: captureID)?.readyResults, [variant()])
        XCTAssertFalse(restarted.hasPendingRetry(captureID))
    }

    @MainActor func testDiskFailurePreventsMutationAndNetworkFailureRetainsReadyResult() async throws {
        let memory = MemoryPersistence(), transport = FakeTransport(identity: identity, remote: reconstruction())
        let store = NativeReconstructionStore(transport: transport, persistence: memory)
        store.configure(identity: identity, captures: [capture()], connected: true)
        await store.refresh(captureID: captureID)
        memory.failSave = true
        await store.retry(captureID: captureID, failedTaskID: sfmID)
        XCTAssertTrue(transport.retryIDs.isEmpty)
        transport.failRead = true
        await store.refresh(captureID: captureID)
        XCTAssertEqual(store.result(captureID: captureID)?.readyResults, [variant()])
        XCTAssertNotNil(store.errors[captureID])
    }

    @MainActor func testConsentIsRequiredAndLostStartResumesAfterRestart() async throws {
        let memory = MemoryPersistence(), transport = FakeTransport(identity: identity, remote: nil)
        transport.startResult = reconstruction(sfmStatus: "queued", ffReady: false)
        let store = NativeReconstructionStore(transport: transport, persistence: memory)
        store.configure(identity: identity, captures: [capture()], connected: true)
        await store.refresh(captureID: captureID)
        XCTAssertEqual(transport.startCount, 0, "Upload/refresh must not start training")
        transport.loseNextStart = true
        await store.generate(captureID: captureID, roles: NativeVersionRequest.videoRoles)
        XCTAssertEqual(transport.startCount, 1)
        let resumed = NativeReconstructionStore(transport: transport, persistence: memory)
        resumed.configure(identity: identity, captures: [capture()], connected: true)
        await resumed.refresh(captureID: captureID)
        XCTAssertEqual(transport.startCount, 2)
        XCTAssertEqual(resumed.result(captureID: captureID)?.id, reconstructionID)
        XCTAssertFalse(resumed.hasPendingVersionRequest(captureID))
    }

    @MainActor func testLateResponseAfterAccountChangeCannotPublishPriorAccountResult() async throws {
        let memory = MemoryPersistence(), transport = FakeTransport(identity: identity, remote: reconstruction())
        let store = NativeReconstructionStore(transport: transport, persistence: memory)
        store.configure(identity: identity, captures: [capture()], connected: true)
        transport.pauseRead = true
        let pending = Task { await store.refresh(captureID: captureID) }
        for _ in 0..<30 where transport.continuation == nil { await Task.yield() }
        let continuation = try XCTUnwrap(transport.continuation)
        let other = APIConnectionIdentity(base: identity.base, userID: "77777777-7777-4777-8777-777777777777")
        transport.connectionIdentity = other
        store.configure(identity: other, captures: [], connected: true)
        continuation.resume(returning: reconstruction())
        await pending.value
        XCTAssertNil(store.result(captureID: captureID))
        XCTAssertEqual(store.scopeKey, other.cacheKey)
        XCTAssertNotEqual(identity.cacheKey, other.cacheKey)
    }

    @MainActor func testReturningToAccountBeforeListRefreshDoesNotEraseItsReadyCache() async throws {
        let memory = MemoryPersistence(), transport = FakeTransport(identity: identity, remote: reconstruction())
        let store = NativeReconstructionStore(transport: transport, persistence: memory)
        store.configure(identity: identity, captures: [capture()], connected: true)
        await store.refresh(captureID: captureID)
        await store.generate(captureID: captureID, roles: NativeVersionRequest.videoRoles)
        XCTAssertEqual(transport.startCount, 0, "A confirmed reconstruction is refreshed, not posted again")
        let other = APIConnectionIdentity(base: identity.base, userID: UUID().uuidString)
        transport.connectionIdentity = other
        store.configure(identity: other, captures: [], connected: false)
        XCTAssertNil(store.result(captureID: captureID))
        transport.connectionIdentity = identity
        store.configure(identity: identity, captures: [], connected: false)
        XCTAssertNil(store.result(captureID: captureID))
        // A failed network connection can still restore this account's private
        // saved capture receipt without dropping its immutable ready result.
        store.configure(identity: identity, captures: [capture()], connected: false)
        XCTAssertEqual(store.result(captureID: captureID)?.readyResults, [variant()])
    }

    @MainActor func testSelectedVersionSurvivesLostResponseWithoutStartingOtherVersions() async throws {
        let memory = MemoryPersistence(), transport = FakeTransport(identity: identity, remote: nil)
        let all = reconstruction(sfmStatus: "queued", ffReady: false)
        let single = try changed(all, ["tasks": try JSONSerialization.jsonObject(with: JSONEncoder().encode(all.tasks.filter { $0.role == "refined" }))])
        transport.startResult = single
        transport.loseNextStart = true
        let store = NativeReconstructionStore(transport: transport, persistence: memory)
        store.configure(identity: identity, captures: [capture()], connected: true)
        await store.generate(captureID: captureID, roles: ["refined"])
        XCTAssertTrue(store.hasPendingVersionRequest(captureID))
        let resumed = NativeReconstructionStore(transport: transport, persistence: memory)
        resumed.configure(identity: identity, captures: [capture()], connected: true)
        await resumed.refresh(captureID: captureID)
        XCTAssertEqual(transport.requestedRoles.compactMap { $0 }, [["refined"], ["refined"]])
        XCTAssertEqual(resumed.result(captureID: captureID)?.tasks.map(\.role), ["refined"])
        XCTAssertFalse(resumed.hasPendingVersionRequest(captureID))
    }

    @MainActor func testOldServerCannotSilentlyStartBothForSingleVersionChoice() async throws {
        let transport = FakeTransport(identity: identity, remote: nil)
        transport.supportsVersionSelection = false
        let store = NativeReconstructionStore(transport: transport, persistence: MemoryPersistence())
        store.configure(identity: identity, captures: [capture()], connected: true)
        await store.generate(captureID: captureID, roles: ["preview"])
        XCTAssertEqual(transport.startCount, 0)
        XCTAssertNotNil(store.errors[captureID])
        XCTAssertFalse(store.hasPendingVersionRequest(captureID))
    }

    @MainActor func testIncompleteServerResponseKeepsVersionChoiceUntilConfirmed() async throws {
        let transport = FakeTransport(identity: identity, remote: nil), memory = MemoryPersistence()
        let idle = try changed(reconstruction(), ["tasks": [], "status": "idle"])
        transport.startResult = idle
        let store = NativeReconstructionStore(transport: transport, persistence: memory)
        store.configure(identity: identity, captures: [capture()], connected: true)
        await store.generate(captureID: captureID, roles: ["refined"])
        XCTAssertTrue(store.hasPendingVersionRequest(captureID))
        XCTAssertNotNil(store.errors[captureID])
        let next = reconstruction(sfmStatus: "queued", ffReady: false)
        transport.startResult = try changed(next, ["tasks": try JSONSerialization.jsonObject(with: JSONEncoder().encode(next.tasks.filter { $0.role == "refined" }))])
        await store.refresh(captureID: captureID)
        XCTAssertFalse(store.hasPendingVersionRequest(captureID))
        XCTAssertEqual(transport.requestedRoles.compactMap { $0 }, [["refined"], ["refined"]])
    }

    func testViewerKeepsQualityGenerationAndRetryAfterQuickIsReady() throws {
        let both = reconstruction()
        let quick = try changed(both, ["tasks": try JSONSerialization.jsonObject(with: JSONEncoder().encode(both.tasks.filter { $0.role == "preview" })), "status": "ready"])
        XCTAssertEqual(NativeViewerVersionAction.roles(in: quick), ["preview", "refined"])
        XCTAssertEqual(NativeViewerVersionAction.selected(role: "preview", in: quick, requested: false), .ready)
        XCTAssertEqual(NativeViewerVersionAction.selected(role: "refined", in: quick, requested: false), .generate)
        XCTAssertEqual(NativeViewerVersionAction.selected(role: "refined", in: quick, requested: true), .resume)
        XCTAssertEqual(NativeViewerVersionAction.selected(role: "refined", in: both, requested: false), .retry(taskID: sfmID))
        XCTAssertEqual(NativeViewerVersionAction.selected(role: "refined", in: reconstruction(sfmStatus: "processing"), requested: false), .waiting)
        XCTAssertEqual(NativeViewerVersionAction.selected(role: "refined", in: reconstruction(sfmStatus: "blocked"), requested: false), .blocked)
        XCTAssertEqual(NativeViewerVersionAction.roles(in: withArkit(quick, ready: true)), ["preview", "refined", "arkit"])
    }

    @MainActor func testAddingQualityVersionPreservesDownloadedQuickResult() async throws {
        let all = reconstruction(sfmStatus: "queued")
        let quick = try changed(all, ["tasks": try JSONSerialization.jsonObject(with: JSONEncoder().encode(all.tasks.filter { $0.role == "preview" })), "status": "ready"])
        let transport = FakeTransport(identity: identity, remote: quick)
        let store = NativeReconstructionStore(transport: transport, persistence: MemoryPersistence())
        store.configure(identity: identity, captures: [capture()], connected: true)
        await store.refresh(captureID: captureID)
        transport.startResult = all
        await store.generate(captureID: captureID, roles: ["refined"])
        XCTAssertEqual(transport.requestedRoles.compactMap { $0 }, [["refined"]])
        XCTAssertEqual(store.result(captureID: captureID)?.readyResults, [variant()])
        XCTAssertEqual(store.result(captureID: captureID)?.tasks.count, 2)
    }

    @MainActor func testBusyResponseDoesNotRetryAutomatically() async throws {
        let transport = FakeTransport(identity: identity, remote: nil)
        transport.busy = true
        let store = NativeReconstructionStore(transport: transport, persistence: MemoryPersistence())
        store.configure(identity: identity, captures: [capture()], connected: true)
        await store.generate(captureID: captureID, roles: ["preview"])
        XCTAssertEqual(store.errors[captureID], "服务器繁忙中，请稍后重试。")
        XCTAssertFalse(store.hasPendingVersionRequest(captureID))
        await store.refresh(captureID: captureID)
        XCTAssertEqual(transport.startCount, 1)
    }

    @MainActor func testStatusPollDoesNotBlockNewVersionAndLateGetCannotEraseIt() async throws {
        let all = reconstruction(sfmStatus: "queued")
        let quick = try changed(all, ["tasks": try JSONSerialization.jsonObject(with: JSONEncoder().encode(all.tasks.filter { $0.role == "preview" })), "status": "ready"])
        let transport = FakeTransport(identity: identity, remote: quick)
        let store = NativeReconstructionStore(transport: transport, persistence: MemoryPersistence())
        store.configure(identity: identity, captures: [capture()], connected: true)
        await store.refresh(captureID: captureID)
        transport.pauseRead = true
        let poll = Task { await store.refresh(captureID: captureID) }
        for _ in 0..<100 where transport.continuation == nil { await Task.yield() }
        guard let continuation = transport.continuation else { poll.cancel(); XCTFail("GET did not start"); return }
        XCTAssertFalse(store.isBusy(captureID), "A GET must not disable generation buttons")
        transport.startResult = all
        await store.generate(captureID: captureID, roles: ["refined"])
        XCTAssertEqual(transport.requestedRoles.compactMap { $0 }, [["refined"]])
        continuation.resume(returning: quick)
        await poll.value
        XCTAssertEqual(store.result(captureID: captureID)?.tasks.map(\.role), ["preview", "refined"])
        XCTAssertEqual(store.result(captureID: captureID)?.readyResults, [variant()])
        XCTAssertNil(store.errors[captureID])
    }

    func testExactResultEntryDoesNotFallBackToFirstReadyVersion() {
        let tasks = withArkit(reconstruction(), ready: true).tasks
        XCTAssertEqual(NativeViewerVersionAction.initialRole(preferred: "arkit", tasks: tasks), "arkit")
        XCTAssertEqual(NativeViewerVersionAction.initialRole(preferred: "refined", tasks: tasks), "refined")
        XCTAssertEqual(NativeViewerVersionAction.initialRole(preferred: "refined", tasks: []), "refined")
        XCTAssertEqual(NativeViewerVersionAction.initialRole(preferred: nil, tasks: tasks), "preview")
    }

    @MainActor func testProjectVersionEntriesRenderAtCompactAndWideSizes() async throws {
        let all = reconstruction(sfmStatus: "queued")
        let quick = try changed(all, ["tasks": try JSONSerialization.jsonObject(with: JSONEncoder().encode(all.tasks.filter { $0.role == "preview" })), "status": "ready"])
        let transport = FakeTransport(identity: identity, remote: quick)
        let store = NativeReconstructionStore(transport: transport, persistence: MemoryPersistence())
        store.configure(identity: identity, captures: [capture()], connected: true)
        await store.refresh(captureID: captureID)
        for width in [320.0, 430.0] {
            let view = VStack(alignment: .leading, spacing: 16) {
                Text("扫描 08").font(.title2.bold()).foregroundStyle(Theme.text)
                Text("原始采集 · 重建版本").font(.caption).foregroundStyle(Theme.secondary)
                NativeReconstructionPanel(captureID: captureID, store: store)
            }.padding(20).frame(width: width).background(Theme.background)
                .environment(\.colorScheme, .dark)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            let image = try XCTUnwrap(renderer.uiImage)
            XCTAssertEqual(image.size.width, width)
            XCTAssertLessThan(image.size.height, 750)
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ProjectHubQA")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try XCTUnwrap(image.pngData()).write(to: folder.appendingPathComponent("versions-\(Int(width)).png"))
        }
        XCTAssertEqual(transport.startCount, 0, "Viewing the project never starts a reconstruction")
    }

    @MainActor private final class MemoryPersistence: NativeReconstructionPersistence {
        var values: [String: NativeReconstructionCache] = [:]
        var failSave = false
        func load(identity: APIConnectionIdentity) throws -> NativeReconstructionCache { values[identity.cacheKey] ?? NativeReconstructionCache() }
        func save(_ cache: NativeReconstructionCache, identity: APIConnectionIdentity) throws {
            if failSave { throw CocoaError(.fileWriteOutOfSpace) }
            values[identity.cacheKey] = cache
        }
    }
    @MainActor private final class FakeTransport: NativeReconstructionTransport {
        var connectionIdentity: APIConnectionIdentity?
        var remote: NativeReconstruction?
        var startResult: NativeReconstruction?
        var busy = false
        var startCount = 0
        var supportsVersionSelection = true
        var requestedRoles: [[String]?] = []
        var retryIDs: [String] = []
        var loseNextRetry = false, loseNextStart = false, failRead = false, pauseRead = false
        var continuation: CheckedContinuation<NativeReconstruction?, Error>?
        init(identity: APIConnectionIdentity, remote: NativeReconstruction?) { connectionIdentity = identity; self.remote = remote }
        func nativeReconstruction(captureID: String) async throws -> NativeReconstruction? {
            if pauseRead { return try await withCheckedThrowingContinuation { continuation = $0 } }
            if failRead { throw URLError(.notConnectedToInternet) }
            return remote
        }
        func startNativeReconstruction(captureID: String, roles: [String]?) async throws -> NativeReconstruction {
            startCount += 1
            if busy { throw APIError.serverBusy }
            requestedRoles.append(roles)
            if loseNextStart { loseNextStart = false; throw URLError(.networkConnectionLost) }
            let value = try XCTUnwrap(startResult); remote = value; return value
        }
        func retryNativeReconstruction(_ intent: NativeReconstructionRetry) async throws -> NativeReconstruction {
            retryIDs.append(intent.id)
            if loseNextRetry { loseNextRetry = false; throw URLError(.networkConnectionLost) }
            let value = try XCTUnwrap(remote), old = try XCTUnwrap(value.tasks.first { $0.id == intent.failedTaskId })
            let next = NativeReconstructionTask(id: intent.id, algorithm: old.algorithm, role: old.role,
                status: "queued", phase: "fixture_retry", error: nil, result: nil, replacementId: nil, archivedAt: nil)
            let archived = NativeReconstructionTask(id: old.id, algorithm: old.algorithm, role: old.role,
                status: old.status, phase: old.phase, error: old.error, result: old.result,
                replacementId: intent.id, archivedAt: "2026-11-03T01:00:00Z")
            let replacement = NativeReconstruction(id: value.id, title: value.title, sourceKind: value.sourceKind,
                captureId: value.captureId, captureReceiptId: value.captureReceiptId,
                sourceVideoSha256: value.sourceVideoSha256, sourceByteSize: value.sourceByteSize,
                sourceMetadataSha256: value.sourceMetadataSha256, sourceMetadataByteSize: value.sourceMetadataByteSize,
                status: "partial", createdAt: value.createdAt,
                tasks: value.tasks.map { $0.id == old.id ? next : $0 }, previousAttempts: value.previousAttempts + [archived])
            remote = replacement; return replacement
        }
        func prepareNativeReconstruction(_ reconstruction: NativeReconstruction, variant: ReconstructionVariant,
                                         source: NativeReconstructionSource) async throws -> PreparedReconstructionVariant {
            throw ReconstructionStudyError.unavailable
        }
    }
}
