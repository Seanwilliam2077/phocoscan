import XCTest
import CryptoKit
import MetalKit
import SwiftUI
@testable import PocketWorld

/// Opt-in, real on-phone evidence. Never logs credentials or copies source media.
@MainActor final class ExistingScanAcceptanceTests: XCTestCase {
    func testInventoryAndCaptureEvidence() async throws {
        guard ProcessInfo.processInfo.environment["PHOCOSCAN_EXISTING_CHECK"] == "1" else { throw XCTSkip("Requires explicit on-phone acceptance") }
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = false }
        let cloud = ReconstructionSync.shared.cloud
        if !cloud.isConnected { await cloud.connect() }
        print("PHONE_AUDIT connected=\(cloud.isConnected)")
        let packages = try ScanPackage.loadAll()
        for package in packages {
            let id = package.captureID
            if cloud.status(for: id)?.verifiedReceipt != nil { await cloud.reconstructions.refresh(captureID: id) }
            let assessment = ScanCaptureAssessment(isComplete: package.isComplete, analysis: package.analysis)
            let frames = package.folderURL.appendingPathComponent("capture/transforms.json")
            var actualCount: Int? = nil
            var missingImages = 0
            if let data = try? Data(contentsOf: frames), let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], let rows = object["frames"] as? [[String: Any]] {
                actualCount = rows.count
                for row in rows {
                    if let name = row["file_path"] as? String,
                       !FileManager.default.fileExists(atPath: package.folderURL.appendingPathComponent("capture").appendingPathComponent(name).path) { missingImages += 1 }
                }
            }
            if let actualCount, let expected = package.analysis?.keyframeCount {
                XCTAssertEqual(actualCount, expected, "Stored keyframe count differs from scan report: \(id)")
            }
            XCTAssertEqual(missingImages, 0, "Missing images in \(id)")
            print("PHONE_SCAN id=\(id) name=\(ScanNameStore.shared.displayName(for:id)) complete=\(package.isComplete) coverage=\(assessment.coverageText) assessment=\(assessment.title) report_keys=\(assessment.keyframes ?? -1) actual_keys=\(actualCount ?? -1) missing=\(missingImages) local=\(OnDeviceTrainingStore.shared.result(captureID:id) != nil) can_train=\(OnDeviceTrainingStore.canTrain(captureID:id)) verified=\(cloud.status(for:id)?.verifiedReceipt != nil)")
            for task in cloud.reconstructions.result(captureID:id)?.tasks ?? [] {
                print("PHONE_TASK scan=\(id) role=\(task.role) status=\(task.status) task=\(task.id) result=\(task.result?.id ?? "none") code=\(task.error?.code ?? "none")")
            }
        }
        let images = ImageGenerationStore(api:cloud.imageAPI)
        await images.refresh()
        for entry in images.entries {
            print("PHONE_IMAGE id=\(entry.id) scan=\(entry.scanSource?.captureID ?? "standalone") status=\(entry.image.status)")
        }
        XCTAssertFalse(packages.isEmpty)
    }
    func testGenerateLocalAndSingleImageAndRenderAllFour() async throws {
        guard let id = ProcessInfo.processInfo.environment["PHOCOSCAN_GENERATE_SCAN"], UUID(uuidString:id) != nil else { throw XCTSkip("Explicit opt-in scan UUID required") }
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = false }
        let cloud = ReconstructionSync.shared.cloud
        try await readyForForegroundWork(cloud)
        await cloud.reconstructions.refresh(captureID:id)
        let existing = try XCTUnwrap(cloud.reconstructions.result(captureID:id))
        let cloudIDs = Dictionary(uniqueKeysWithValues: existing.tasks.map { ($0.role,$0.id) })
        for role in ["preview", "refined"] {
            let variant = try XCTUnwrap(existing.task(role:role)?.result)
            let prepared = try await cloud.reconstructions.prepare(captureID:id,variant:variant)
            XCTAssertEqual(prepared.variant.role,role)
            let visible = try await render(prepared.modelURL,cameras:prepared.cameras)
            XCTAssertGreaterThan(visible,100)
            print("PHONE_RENDER role=\(role) result=\(variant.id) pixels=\(visible)")
        }
        let folder = try ARScanRecorder.packagesDirectory().appendingPathComponent(id+".scan")
        let images = ImageGenerationStore(api:cloud.imageAPI)
        await images.refresh()
        let imageID: String
        if let entry = images.entries.first(where: { $0.scanSource?.captureID == id }) { imageID = entry.id }
        else {
            let target = ScanAnalysis.load(from:folder)?.targetBox
            let prepared = try await Task.detached { try await ScanSubjectPhoto.prepare(folder:folder,target:target) }.value
            imageID = try images.add(image:UIImage(cgImage:prepared.image),scanSource:prepared.source)
        }
        if images.entries.first(where: { $0.id == imageID })?.image.status != "ready" {
            images.generate(imageID)
            print("PHONE_GENERATE role=image id=\(imageID)")
        }
        try await readyForForegroundWork(cloud)
        let local = OnDeviceTrainingStore.shared
        if local.result(captureID:id) == nil { local.start(captureID:id);print("PHONE_GENERATE role=local scan=\(id)") }
        let deadline = Date().addingTimeInterval(1200)
        var tick=0
        while local.isTraining || images.busyID != nil || images.entries.first(where: { $0.id == imageID })?.image.pending == true {
            guard Date()<deadline else { XCTFail("Generation timeout; jobs preserved"); return }
            try await Task.sleep(for:.seconds(5)); tick += 1
            if images.busyID == nil { await images.refresh() }
            if tick % 4 == 0 { print("PHONE_PROGRESS app=\(UIApplication.shared.applicationState.rawValue) local=\(String(describing:local.phases[id])) image=\(images.entries.first(where: { $0.id == imageID })?.image.status ?? "none")") }
        }
        let output = try XCTUnwrap(local.result(captureID:id),String(describing:local.phases[id]))
        let cameras = try JSONDecoder().decode(SceneCameraPath.self,from:Data(contentsOf:output.cameras))
        let localPixels = try await render(output.model,cameras:cameras)
        XCTAssertGreaterThan(localPixels,100)
        print("PHONE_RENDER role=local steps=\(output.iterations) points=\(output.gaussians) seconds=\(output.seconds) pixels=\(localPixels)")
        let image = try XCTUnwrap(images.entries.first { $0.id == imageID }?.image)
        XCTAssertEqual(image.status,"ready",images.error ?? "Image job did not finish")
        let url = try await images.api.prepareImageResult(image)
        let imagePixels = try await render(url,hint:image.result?.viewHint)
        XCTAssertGreaterThan(imagePixels,100)
        print("PHONE_RENDER role=image id=\(imageID) pixels=\(imagePixels)")
        await cloud.reconstructions.refresh(captureID:id)
        XCTAssertEqual(Dictionary(uniqueKeysWithValues:(cloud.reconstructions.result(captureID:id)?.tasks ?? []).map { ($0.role,$0.id) }),cloudIDs,"Local/AI generation must not replace or start cloud scan versions")
        print("PHONE_FOUR independent=true cloud_task_ids_unchanged=true")
    }

    /// Numeric diagnostics only: no media exported, GPU jobs started, or scan/result files written.
    /// The anchor crop is a geometric proxy (including a margin), not a segmentation ground truth.
    func testLocalTrainingQualityInventoryReadOnly() throws {
        guard ProcessInfo.processInfo.environment["PHOCOSCAN_LOCAL_QUALITY_AUDIT"] == "1" else {
            throw XCTSkip("Opt-in read-only local quality audit")
        }
        let idle = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = idle }
        var checked = 0
        for scan in try ScanPackage.loadAll() {
            guard let output = OnDeviceTrainingStore.shared.result(captureID: scan.captureID) else { continue }
            try autoreleasepool {
                let capture = scan.folderURL.appendingPathComponent("capture")
                let paths = [output.model, output.cameras, output.model.deletingLastPathComponent().appendingPathComponent("meta.json"),
                             capture.appendingPathComponent("points3d.ply"), capture.appendingPathComponent("transforms.json")]
                let before = try paths.map(Self.fileSHA)
                let meta = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: paths[2])) as? [String: Any])
                let captureMeta = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: capture.appendingPathComponent("meta.json"))) as? [String: Any])
                let transforms = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: paths[4])) as? [String: Any])
                let frames = try XCTUnwrap(transforms["frames"] as? [[String: Any]])
                let voxel = Float((captureMeta["points3d"] as? [String: Any])?["voxel_m"] as? Double ?? 0.01)
                let seeds = try TrainingDataset.readPoints(paths[3], size: voxel * 0.8, limit: 400_000)
                let crop = scan.analysis?.targetBox.map {
                    SplatCrop(region: SplatCrop.region(for: $0), rotation: matrix_identity_float3x3,
                              scale: 1, translation: .zero, fitError: 0, matchedCameras: 0)
                }
                let seedInside = crop.map { region in seeds.filter { region.contains(arkit: $0.position) }.count } ?? -1
                let data = try Data(contentsOf: output.model)
                let end = try XCTUnwrap(data.range(of: Data("end_header\n".utf8)))
                let header = String(decoding: data[..<end.lowerBound], as: UTF8.self)
                XCTAssertTrue(header.contains("format binary_little_endian"))
                let names = header.split(separator: "\n").filter { $0.hasPrefix("property ") }.map { String($0) }
                let expected = ["x", "y", "z", "nx", "ny", "nz", "f_dc_0", "f_dc_1", "f_dc_2", "opacity",
                                "scale_0", "scale_1", "scale_2", "rot_0", "rot_1", "rot_2", "rot_3"]
                guard names == expected.map({ "property float " + $0 }) else { throw GaussianTrainerError.invalidInput }
                let countLine = try XCTUnwrap(header.split(separator: "\n").first { $0.hasPrefix("element vertex ") })
                let count = try XCTUnwrap(Int(countLine.split(separator: " ").last!))
                XCTAssertEqual(data.count - end.upperBound, count * 68)
                XCTAssertEqual(count, output.gaussians)
                var inside = 0, keptInside = 0, faint = 0
                var subjectSigmas: [Float] = [], subjectRatios: [Float] = []
                data.withUnsafeBytes { raw in
                    let base = raw.baseAddress!.advanced(by: end.upperBound)
                    for i in 0..<count {
                        let p = base.advanced(by: i * 68)
                        func value(_ j: Int) -> Float { p.loadUnaligned(fromByteOffset: j * 4, as: Float.self) }
                        let position = SIMD3(value(0), value(1), value(2))
                        let opacity = 1 / (1 + exp(-value(9)))
                        if opacity < 0.02 { faint += 1 }
                        if crop?.contains(arkit: position) == true {
                            inside += 1
                            if opacity >= 0.02 { keptInside += 1 }
                            let scales = (10...12).map { exp(value($0)) }
                            subjectSigmas.append(scales.max()!)
                            subjectRatios.append(scales.max()! / max(1e-12, scales.min()!))
                        }
                    }
                }
                func quantile(_ values: [Float], _ q: Double) -> Float {
                    guard !values.isEmpty else { return -1 }
                    let sorted = values.sorted()
                    return sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * q))]
                }
                var report: [String: Any] = [
                    "scan": scan.captureID, "name": ScanNameStore.shared.displayName(for: scan.captureID),
                    "inputFrames": frames.count, "depthFrames": frames.filter { $0["depth_file_path"] != nil }.count,
                    "maskFrames": frames.filter { $0["mask_path"] != nil }.count,
                    "voxelMeters": voxel, "sourceSeeds": seeds.count, "seedsInAnchorMargin": seedInside,
                    "resultPoints": count, "resultInAnchorMargin": inside, "viewerKeptInAnchorMargin": keptInside,
                    "resultOpacityBelow002": faint,
                    "anchorSigmaMaxMedianMeters": quantile(subjectSigmas, 0.5),
                    "anchorSigmaMaxP90Meters": quantile(subjectSigmas, 0.9),
                    "anchorAxisRatioP90": quantile(subjectRatios, 0.9), "unchanged": true
                ]
                for key in ["trainerVersion", "iterations", "seconds", "keyframes", "seedGaussians", "resolution", "peakObservedMetalBytes"] {
                    report[key] = meta[key]
                }
                if let evaluation = meta["evaluation"] as? [String: Any] {
                    report["evaluation"] = evaluation.filter { $0.key != "sourceFrames" }
                }
                if let target = scan.analysis?.targetBox { report["anchorSizeMeters"] = target.size }
                XCTAssertEqual(try paths.map(Self.fileSHA), before)
                let encoded = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
                print("LOCAL_QUALITY_AUDIT " + String(decoding: encoded, as: UTF8.self))
                checked += 1
            }
        }
        XCTAssertGreaterThan(checked, 0)
    }

    func testExistingLocalResultsReadOnly() async throws {
        guard ProcessInfo.processInfo.environment["PHOCOSCAN_LOCAL_VIEW_CHECK"] == "1" else { throw XCTSkip("Read-only existing local results opt-in") }
        let idle=UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled=true
        defer { UIApplication.shared.isIdleTimerDisabled=idle }
        let store=OnDeviceTrainingStore.shared
        var checked=0
        for scan in try ScanPackage.loadAll() {
            let outputs=[store.result(captureID:scan.captureID),store.previousResult(captureID:scan.captureID)].compactMap { $0 }
            for output in outputs {
                let hashes=try [output.model,output.cameras].map(Self.fileSHA)
                let path=try JSONDecoder().decode(SceneCameraPath.self,from:Data(contentsOf:output.cameras))
                let pixels=try await render(output.model,cameras:path)
                XCTAssertGreaterThan(pixels,100)
                XCTAssertEqual(try [output.model,output.cameras].map(Self.fileSHA),hashes)
                checked += 1
                print("LOCAL_EXISTING scan=\(scan.captureID) result=\(output.model.deletingLastPathComponent().lastPathComponent) gaussians=\(output.gaussians) nonblack=\(pixels) unchanged=true")
            }
        }
        XCTAssertGreaterThan(checked,0)
    }

    func testRealViewerSwitchesBetweenExistingResults() async throws {
        guard ProcessInfo.processInfo.environment["PHOCOSCAN_VIEWER_SCAN"] != nil else { throw XCTSkip("Requires existing real result opt-in") }
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = false }
        let id = try XCTUnwrap(ProcessInfo.processInfo.environment["PHOCOSCAN_VIEWER_SCAN"])
        let cloud = ReconstructionSync.shared.cloud
        try await readyForForegroundWork(cloud)
        await cloud.reconstructions.refresh(captureID:id)
        let result = try XCTUnwrap(cloud.reconstructions.result(captureID:id))
        let quick = try XCTUnwrap(result.task(role:"preview")?.result)
        let high = try XCTUnwrap(result.task(role:"refined")?.result)
        XCTAssertNotEqual(quick.id,high.id);XCTAssertNotEqual(quick.sha256,high.sha256)
        let selection = NativeViewerSelection(role:"preview")
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive })
        let window = try XCTUnwrap(scene.windows.first { $0.isKeyWindow })
        var presenter = try XCTUnwrap(window.rootViewController)
        while let next = presenter.presentedViewController { presenter = next }
        let host = UIHostingController(rootView:NativeReconstructionViewer(captureID:id,store:cloud.reconstructions,title:"实机检查",subtitle:"",selection:selection,onClose:{}).environment(\.scenePhase,.active))
        host.modalPresentationStyle = .fullScreen
        await withCheckedContinuation { continuation in presenter.present(host,animated:false) { continuation.resume() } }
        var failure: Error?
        do {
            for role in ["preview","refined","preview","refined"] {
                selection.role = role
                let expected = role == "preview" ? quick.id : high.id
                let deadline=Date().addingTimeInterval(90)
                while selection.displayedResultID != expected {
                    guard Date()<deadline else { throw AcceptanceError.timeout }
                    try await Task.sleep(for:.milliseconds(150))
                }
                print("PHONE_UI role=\(role) displayed=\(expected) metal_first_frame=true")
                try await Task.sleep(for:.milliseconds(500))
            }
            if ProcessInfo.processInfo.environment["PHOCOSCAN_VIEWER_HOLD"] == "1" {
                print("PHONE_UI final_high_ready_for_visual_check=true")
                try await Task.sleep(for: .seconds(20))
            }
        } catch { failure=error }
        await withCheckedContinuation { continuation in host.dismiss(animated:false) { continuation.resume() } }
        if let failure { throw failure }
    }
    func testCloudVersionsStartIndependentlyFromExistingCapture() async throws {
        guard let id = ProcessInfo.processInfo.environment["PHOCOSCAN_CLOUD_SCAN"], UUID(uuidString:id) != nil else { throw XCTSkip("Explicit fresh cloud acceptance opt-in required") }
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = false }
        let cloud=ReconstructionSync.shared.cloud
        try await readyForForegroundWork(cloud)
        let package=try XCTUnwrap(ScanPackage.loadAll().first { $0.captureID == id })
        if cloud.status(for:id)?.verifiedReceipt == nil {
            await cloud.upload(packageURL:package.folderURL,selectedEnvironment:cloud.firstEnvironment(for:id) ?? CaptureEnvironmentMemory.load(captureID:id) ?? "unknown")
            guard cloud.status(for:id)?.verifiedReceipt != nil else { throw AcceptanceError.offline }
        }
        await cloud.reconstructions.refresh(captureID:id)
        guard cloud.reconstructions.result(captureID:id)?.tasks.isEmpty != false else { throw AcceptanceError.alreadyGenerated }
        await cloud.reconstructions.generate(captureID:id,roles:["preview"])
        let first=try XCTUnwrap(cloud.reconstructions.result(captureID:id))
        XCTAssertEqual(first.tasks.map(\.role),["preview"],"Choosing quick must not start high quality or ARKit")
        print("PHONE_CLOUD preview_only=true task=\(first.tasks[0].id)")
        let quick=try await waitForCloud("preview",captureID:id,store:cloud.reconstructions)
        let quickPrepared=try await cloud.reconstructions.prepare(captureID:id,variant:quick)
        let quickPixels=try await render(quickPrepared.modelURL,cameras:quickPrepared.cameras)
        XCTAssertGreaterThan(quickPixels,100)
        await cloud.reconstructions.generate(captureID:id,roles:["refined"])
        XCTAssertEqual(cloud.reconstructions.result(captureID:id)?.task(role:"preview")?.result?.id,quick.id)
        XCTAssertNil(cloud.reconstructions.result(captureID:id)?.task(role:"arkit"))
        let high=try await waitForCloud("refined",captureID:id,store:cloud.reconstructions)
        let highPrepared=try await cloud.reconstructions.prepare(captureID:id,variant:high)
        let highPixels=try await render(highPrepared.modelURL,cameras:highPrepared.cameras)
        XCTAssertGreaterThan(highPixels,100)
        XCTAssertNotEqual(quick.id,high.id)
        print("PHONE_CLOUD both_ready=true quick_preserved=true quick=\(quick.id) high=\(high.id)")
    }
    /// User-authorized repair of one known failed attempt. Never re-retries a new failure.
    func testPrepareScan16SubjectKeyframes() async throws {
        guard ProcessInfo.processInfo.environment["PHOCOSCAN_MASK_SCAN16"] == "1" else { throw XCTSkip("Explicit subject-mask preparation opt-in required") }
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = false }
        let cloud = ReconstructionSync.shared.cloud
        try await readyForForegroundWork(cloud)
        let id = "cb1630fe-59f5-41d4-96b9-4d03a9ac1118"
        let folder = try ARScanRecorder.packagesDirectory().appendingPathComponent(id + ".scan")
        let built = try await Task.detached(priority: .userInitiated) {
            try KeyframePack.cachedSubjectPack(scanFolder: folder, captureID: id)
        }.value
        let pack = try XCTUnwrap(built)
        XCTAssertTrue(pack.masks)
        XCTAssertGreaterThanOrEqual(pack.frameCount, 8)
        print("PHONE_SUBJECT_PACK frames=\(pack.frameCount) masks=\(pack.masks) bytes=\(pack.byteSize) sha256=\(pack.sha256)")
    }

    func testScan16HighQualityRepairPreservesQuick() async throws {
        guard ProcessInfo.processInfo.environment["PHOCOSCAN_REPAIR_SCAN16"] == "1" else {
            throw XCTSkip("Explicit scan-16 repair acceptance required")
        }
        let id = "cb1630fe-59f5-41d4-96b9-4d03a9ac1118"
        let failedID = "77ca7a32-a4c1-407c-86ab-f88592bc3e5d"
        let priorIdleTimer = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = priorIdleTimer }
        let cloud = ReconstructionSync.shared.cloud
        try await readyForForegroundWork(cloud)
        await cloud.reconstructions.refresh(captureID: id)
        let before = try XCTUnwrap(cloud.reconstructions.result(captureID: id))
        let quick = try XCTUnwrap(before.task(role: "preview")?.result)
        XCTAssertEqual(quick.id, "334c9736-38dc-436c-aa55-3f1c300e7322")
        XCTAssertEqual(quick.sha256, "c9f04a87c302554fd85f25e6a7711b6c5738d5aefd71772f58113b8fc9ebf2dc")
        XCTAssertEqual(quick.cameraSha256, "99b4161b2099f8a09144179c2531e4f1986892f27a031ceca05cfa245bf45b6c")
        let current = try XCTUnwrap(before.task(role: "refined"))
        if current.id == failedID {
            guard current.canRetry else { throw AcceptanceError.providerFailed }
            await cloud.reconstructions.retry(captureID: id, failedTaskID: failedID)
        }
        let replacement = try XCTUnwrap(cloud.reconstructions.result(captureID: id)?.task(role: "refined"))
        guard replacement.id != failedID else { throw AcceptanceError.providerFailed }
        print("PHONE_REPAIR retry_task=\(replacement.id) old_failure=\(failedID)")
        let high = try await waitForCloud("refined", captureID: id, store: cloud.reconstructions)
        XCTAssertEqual(high.algorithm, "gs_mcmc")
        for variant in [high, quick] {
            let prepared = try await cloud.reconstructions.prepare(captureID: id, variant: variant)
            let visible = try await render(prepared.modelURL, cameras: prepared.cameras)
            XCTAssertGreaterThan(visible, 100)
            print("PHONE_REPAIR rendered=\(variant.role) result=\(variant.id) pixels=\(visible)")
        }
        let after = try XCTUnwrap(cloud.reconstructions.result(captureID: id))
        XCTAssertEqual(after.task(role: "preview")?.result, quick)
        XCTAssertEqual(Set(after.tasks.map(\.role)), ["preview", "refined"])
        print("PHONE_REPAIR ready=true quick_id_hash_cameras_unchanged=true")
    }

    /// Read-only source/result baseline around an attended UI pass. Never generates or retries jobs.
    func testExperienceSourceAndResultIntegrity() async throws {
        guard let mode = ProcessInfo.processInfo.environment["PHOCOSCAN_EXPERIENCE_INTEGRITY"],
              ["before", "after"].contains(mode) else { throw XCTSkip("Explicit existing-scan integrity check required") }
        let idle = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = idle }
        let cloud = ReconstructionSync.shared.cloud
        try await readyForForegroundWork(cloud)
        let packages = try ScanPackage.loadAll()
        let root = try ARScanRecorder.packagesDirectory()
        var snapshot = try await Task.detached(priority: .utility) { try Self.sourceHashes(root) }.value
        for package in packages {
            let id = package.captureID
            // A direct GET cannot replay an earlier saved generation intent.
            if cloud.status(for: id)?.verifiedReceipt != nil,
               let result = try await cloud.imageAPI.nativeReconstruction(captureID: id) {
                for task in result.tasks {
                    snapshot["cloud/" + id + "/" + task.role] = [task.id, task.status,
                        task.result?.id ?? "", task.result?.sha256 ?? "", task.result?.cameraSha256 ?? ""].joined(separator: "|")
                }
            }
            let a = ScanCaptureAssessment(isComplete: package.isComplete, analysis: package.analysis)
            print("EXPERIENCE_SOURCE name=\(ScanNameStore.shared.displayName(for: id)) id=\(id) assessment=\(a.title) coverage=\(a.coverageText) keys=\(a.keyframes ?? -1) mode=\(package.analysis?.mode ?? "unknown")")
        }
        let images = ImageGenerationStore(api: cloud.imageAPI)
        await images.refresh()
        for entry in images.entries {
            snapshot["image/" + entry.id] = [entry.image.status, entry.image.attemptId ?? "",
                entry.image.result?.ply.sha256 ?? "", entry.image.result?.spz.sha256 ?? ""].joined(separator: "|")
            if let url = images.sourceURL(entry.id) { snapshot["image-source/" + entry.id] = try Self.fileSHA(url) }
        }
        let baseline = FileManager.default.temporaryDirectory.appendingPathComponent("phocoscan-experience-baseline.json")
        if mode == "before" {
            try JSONEncoder().encode(snapshot).write(to: baseline, options: .atomic)
        } else {
            let saved = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: baseline))
            XCTAssertEqual(Set(snapshot.keys), Set(saved.keys), "No capture, source file or reconstruction may be added/deleted")
            let changed = snapshot.keys.filter { snapshot[$0] != saved[$0] }
            XCTAssertTrue(changed.isEmpty, "Changed source/result identities: \(changed)")
            if changed.isEmpty && Set(snapshot.keys) == Set(saved.keys) { try FileManager.default.removeItem(at: baseline) }
        }
        print("EXPERIENCE_INTEGRITY phase=\(mode) scans=\(packages.count) records=\(snapshot.count) images=\(images.entries.count)")
    }

    /// Exercise the real retry-download row while a separate XCUITest taps it.
    /// Only a reversible model-cache move is used; original captures are never touched.
    /// Explicit, attended lifecycle check on copied result bytes and a read-only link to a real
    /// capture. No cloud jobs, changes to original material, or replacement of its local result.
    func testLocalTrainingBackgroundWithActualHomeButton() async throws {
        guard ProcessInfo.processInfo.environment["PHOCOSCAN_LOCAL_RESUME"] == "1" else { throw XCTSkip("Attended resume acceptance only") }
        let store = OnDeviceTrainingStore.shared
        guard !store.isTraining else { throw XCTSkip("User training is already active") }
        let idle = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = idle }
        let sourceID = "fdfe1085-9d91-4a29-85b8-f43372950a74"
        let source = try XCTUnwrap(OnDeviceTrainingStore.scanFolder(sourceID))
        let id = UUID().uuidString.lowercased(), scan = try XCTUnwrap(OnDeviceTrainingStore.scanFolder(id))
        try FileManager.default.createDirectory(at: scan, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scan) }
        try FileManager.default.createSymbolicLink(at: scan.appendingPathComponent("capture"), withDestinationURL: source.appendingPathComponent("capture"))
        try FileManager.default.copyItem(at: source.appendingPathComponent("ondevice"), to: scan.appendingPathComponent("ondevice"))
        let paths = ["capture/transforms.json", "capture/points3d.ply", "capture/meta.json", "ondevice/scene.ply", "ondevice/cameras.json", "ondevice/meta.json"]
            + (try FileManager.default.contentsOfDirectory(atPath: source.appendingPathComponent("capture/images").path)).map { "capture/images/" + $0 }
        let hashes = try paths.map { try Self.fileSHA(source.appendingPathComponent($0)) }
        let oldHash = try Self.fileSHA(scan.appendingPathComponent("ondevice/scene.ply"))
        let control = ResumeAcceptanceControl()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive })
        let window = try XCTUnwrap(scene.windows.first { $0.isKeyWindow })
        var presenter = try XCTUnwrap(window.rootViewController)
        while let next = presenter.presentedViewController { presenter = next }
        let host = UIHostingController(rootView: ResumeAcceptancePanel(captureID: id, control: control))
        host.modalPresentationStyle = .fullScreen
        await withCheckedContinuation { c in presenter.present(host, animated: false) { c.resume() } }
        var backgroundStep = 0, afterStep = 0
        do {
            let deadline = Date().addingTimeInterval(240)
            while !control.startRequested && Date() < deadline { try await Task.sleep(for:.milliseconds(100)) }
            XCTAssertTrue(control.startRequested)
            store.start(captureID:id)
            while !control.finished && Date() < deadline {
                if case .failed(let error) = store.phases[id] { XCTFail(error); break }
                if case .training(let progress,_,_) = store.phases[id], progress > 0 {
                    if control.returns == 0 { control.stage = "resume.ready" }
                    else if let header = try TrainingCheckpoint.read(scan), header.state.step > 0 {
                        backgroundStep = header.state.step
                        afterStep = Int((progress * Double(header.session.config.iterations)).rounded())
                        if afterStep > backgroundStep {
                            control.stage = "resume.continued"
                            if ProcessInfo.processInfo.environment["PHOCOSCAN_LOCAL_LOCK"] == "1" { control.finished = true }
                        }
                    }
                }
                try await Task.sleep(for:.milliseconds(50))
            }
            XCTAssertTrue(control.finished, "Actual home/activate check did not finish")
            XCTAssertGreaterThan(control.returns,0)
            XCTAssertGreaterThan(backgroundStep,0); XCTAssertGreaterThan(afterStep,backgroundStep)
        } catch {
            await store.cancelIfTraining(captureID:id)
            await withCheckedContinuation { c in host.dismiss(animated:false) { c.resume() } }
            throw error
        }
        await store.cancelIfTraining(captureID:id)
        await withCheckedContinuation { c in host.dismiss(animated:false) { c.resume() } }
        XCTAssertEqual(try Self.fileSHA(scan.appendingPathComponent("ondevice/scene.ply")),oldHash)
        XCTAssertEqual(try paths.map { try Self.fileSHA(source.appendingPathComponent($0)) },hashes)
        XCTAssertFalse(TrainingCheckpoint.exists(scan))
        print("RESUME_ACTUAL backgroundStep=\(backgroundStep) resumedStep=\(afterStep) sources=\(paths.count) unchanged=true previousResult=unchanged")
    }

    func testExperienceDownloadRecoveryWithActualTaps() async throws {
        guard ProcessInfo.processInfo.environment["PHOCOSCAN_EXPERIENCE_DOWNLOAD"] == "1" else {
            throw XCTSkip("Explicit attended download acceptance required")
        }
        let idle = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = idle }
        let cloud = ReconstructionSync.shared.cloud
        try await readyForForegroundWork(cloud)
        let id = "cb1630fe-59f5-41d4-96b9-4d03a9ac1118"
        let isolated = NativeReconstructionStore(transport: cloud.imageAPI)
        let identity = try XCTUnwrap(cloud.imageAPI.connectionIdentity)
        isolated.configure(identity: identity, captures: Array(cloud.statuses.values), connected: true)
        XCTAssertFalse(isolated.hasPendingRetry(id)); XCTAssertFalse(isolated.hasPendingVersionRequest(id))
        XCTAssertFalse(isolated.hasPendingArkitTraining(id))
        await isolated.refresh(captureID: id)
        let before = try XCTUnwrap(isolated.result(captureID: id))
        let high = try XCTUnwrap(before.task(role: "refined")?.result)
        let quick = try XCTUnwrap(before.task(role: "preview")?.result)
        // Keep the normal background prefetcher out of this controlled recovery.
        cloud.reconstructions.suspend()
        defer { cloud.reconstructions.configure(identity: identity, captures: Array(cloud.statuses.values), connected: cloud.isConnected) }
        let source = try NativeReconstructionSource(status: XCTUnwrap(cloud.status(for: id)))
        let prepared = try await cloud.imageAPI.prepareNativeReconstruction(before, variant: high, source: source)
        let originalHash = try Self.fileSHA(prepared.modelURL)
        XCTAssertEqual(originalHash, high.downloadSHA256)
        let backup = prepared.modelURL.appendingPathExtension("experience-backup")
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path))
        try FileManager.default.moveItem(at: prepared.modelURL, to: backup)
        defer {
            if FileManager.default.fileExists(atPath: backup.path) {
                if (try? Self.fileSHA(prepared.modelURL)) == originalHash { try? FileManager.default.removeItem(at: backup) }
                else {
                    try? FileManager.default.removeItem(at: prepared.modelURL)
                    try? FileManager.default.moveItem(at: backup, to: prepared.modelURL)
                }
            }
        }
        // A disconnected store with no cached model must report a download failure.
        isolated.suspend()
        let fetched = await isolated.prefetch(captureID: id, variant: high)
        XCTAssertFalse(fetched); XCTAssertNotNil(isolated.downloadErrors[high.id])
        isolated.configure(identity: identity, captures: Array(cloud.statuses.values), connected: true)
        let control = ExperienceDownloadControl()
        let panel = ExperienceDownloadPanel(store: isolated, captureID: id, control: control)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive })
        let window = try XCTUnwrap(scene.windows.first { $0.isKeyWindow })
        var presenter = try XCTUnwrap(window.rootViewController)
        while let next = presenter.presentedViewController { presenter = next }
        let host = UIHostingController(rootView: panel.environment(\.scenePhase, .active))
        host.modalPresentationStyle = .fullScreen
        await withCheckedContinuation { c in presenter.present(host, animated: false) { c.resume() } }
        print("EXPERIENCE_DOWNLOAD ready_for_ui=true high=\(high.id) quick=\(quick.id)")
        let deadline = Date().addingTimeInterval(180)
        while !control.finished && Date() < deadline { try await Task.sleep(for: .milliseconds(250)) }
        await withCheckedContinuation { c in host.dismiss(animated: false) { c.resume() } }
        XCTAssertTrue(control.finished, "Attended XCUITest did not finish")
        XCTAssertTrue(isolated.isDownloaded(high.id))
        XCTAssertNil(isolated.downloadErrors[high.id])
        XCTAssertEqual(try Self.fileSHA(prepared.modelURL), originalHash)
        let response = try await cloud.imageAPI.nativeReconstruction(captureID: id)
        let after = try XCTUnwrap(response)
        XCTAssertEqual(after.task(role: "preview")?.result, quick)
        XCTAssertEqual(after.task(role: "refined")?.result, high)
        print("EXPERIENCE_DOWNLOAD actual_bytes_restored=true sha_unchanged=true task_ids_unchanged=true")
    }

    nonisolated private static func fileSHA(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var sha = SHA256()
        while true {
            let more = try autoreleasepool { () throws -> Bool in
                guard let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty else { return false }
                sha.update(data: data)
                return true
            }
            if !more { break }
        }
        return sha.finalize().map { String(format: "%02x", $0) }.joined()
    }
    nonisolated private static func sourceHashes(_ root: URL) throws -> [String: String] {
        var hashes: [String: String] = [:]
        let folders = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).filter { $0.pathExtension == "scan" }
        for folder in folders {
            hashes["scan/" + folder.lastPathComponent] = "present"
            print("EXPERIENCE_HASH scan=\(folder.lastPathComponent)")
            guard let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey], options: []) else { throw CocoaError(.fileReadUnknown) }
            for case let file as URL in files {
                if try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                    hashes["source/" + String(file.path.dropFirst(root.path.count + 1))] = try fileSHA(file)
                }
            }
        }
        return hashes
    }

    private func waitForCloud(_ role:String,captureID:String,store:NativeReconstructionStore) async throws -> ReconstructionVariant {
        let deadline=Date().addingTimeInterval(1200)
        var previous=""
        while Date()<deadline {
            await store.refresh(captureID:captureID)
            guard let task=store.result(captureID:captureID)?.task(role:role) else { throw AcceptanceError.offline }
            let state=task.status+":"+task.phase
            if state != previous { print("PHONE_CLOUD role=\(role) state=\(state) code=\(task.error?.code ?? "none")");previous=state }
            if let result=task.result { return result }
            if task.canRetry || task.status == "blocked" { throw AcceptanceError.providerFailed }
            try await Task.sleep(for:.seconds(5))
        }
        throw AcceptanceError.timeout
    }

    private func readyForForegroundWork(_ cloud: CaptureV2UploadStore) async throws {
        let deadline=Date().addingTimeInterval(100)
        while cloud.isBusy {
            guard Date()<deadline else { throw AcceptanceError.timeout }
            try await Task.sleep(for:.milliseconds(200))
        }
        if !cloud.isConnected { await cloud.connect() }
        guard cloud.isConnected else { throw AcceptanceError.offline }
        var activeSince: Date?
        var logged = false
        while true {
            guard Date()<deadline else { throw AcceptanceError.notForeground }
            if UIApplication.shared.applicationState == .active {
                if activeSince == nil { activeSince=Date() }
                if Date().timeIntervalSince(activeSince!) >= 2 { break }
            } else {
                activeSince=nil
                if !logged { print("PHONE_WAIT_FOREGROUND app=\(UIApplication.shared.applicationState.rawValue)");logged=true }
            }
            try await Task.sleep(for:.milliseconds(200))
        }
        print("PHONE_FOREGROUND active=true connected=true")
    }
    private enum AcceptanceError: Error { case timeout, offline, notForeground, alreadyGenerated, providerFailed }

    private func render(_ url:URL,cameras:SceneCameraPath?=nil,hint:ImageGeneration.Hint?=nil) async throws -> Int {
        let device=try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let view=MTKView(frame:CGRect(x:0,y:0,width:192,height:256),device:device)
        view.colorPixelFormat = .bgra8Unorm_srgb; view.depthStencilPixelFormat = .depth32Float; view.isPaused=true
        let status=GaussianViewerStatus()
        let renderer=try PocketSplatRenderer(view:view,status:status,screenScale:1)
        defer { renderer.invalidate() }
        if let cameras, let limits=OrbitLimits(path:cameras) {
            renderer.orbitTarget=SIMD3<Float>(limits.target);renderer.orbitDistance=Float(limits.initialDistance)
            renderer.yaw=limits.initialYaw(flipped:false);renderer.pitch=limits.initialPitch(flipped:false)
        } else if let p=hint?.presentation { renderer.orbitTarget=p.target;renderer.orbitDistance=p.distance;renderer.yaw=p.yaw;renderer.pitch=p.pitch }
        await renderer.load(url:url)
        XCTAssertNil(status.error);XCTAssertGreaterThan(status.loadedPoints,0)
        var visible=0
        try await renderer.renderClip(poses:[renderer.orbitPose],width:192,height:256,progress:{_ in},deliver:{texture,_ in
            var bytes=[UInt8](repeating:0,count:192*256*4)
            texture.getBytes(&bytes,bytesPerRow:192*4,from:MTLRegionMake2D(0,0,192,256),mipmapLevel:0)
            visible=stride(from:0,to:bytes.count,by:4).filter { bytes[$0]>3 || bytes[$0+1]>3 || bytes[$0+2]>3 }.count
        })
        return visible
    }

}

@MainActor private final class ExperienceDownloadControl: ObservableObject {
    @Published var finished = false
}
private struct ExperienceDownloadPanel: View {
    let store: NativeReconstructionStore
    let captureID: String
    @ObservedObject var control: ExperienceDownloadControl
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack {
                    Text("下载恢复检查").accessibilityIdentifier("acceptance.downloadReady")
                    NativeReconstructionPanel(captureID: captureID, store: store, title: "扫描 16")
                    Button("完成检查") { control.finished = true }.accessibilityIdentifier("acceptance.downloadFinish")
                }.padding(20)
            }.background(Theme.background).preferredColorScheme(.dark)
        }
    }
}

@MainActor private final class ResumeAcceptanceControl: ObservableObject {
    @Published var stage = "resume.waiting"
    @Published var startRequested = false
    @Published var finished = false
    var departed = false
    var returns = 0
}
private struct ResumeAcceptancePanel: View {
    let captureID: String
    @ObservedObject var control: ResumeAcceptanceControl
    var body: some View {
        VStack(spacing: 24) {
            Text("本机训练恢复检查").font(.headline).foregroundStyle(.white)
            Text(control.stage == "resume.waiting" ? "准备好后点开始检查" : control.stage == "resume.ready" ? "请锁屏，等待 5 秒后解锁并回到这里" : "已从断点继续，请点完成检查")
                .foregroundStyle(.white).accessibilityIdentifier(control.stage)
            OnDeviceTrainingCard(captureID:captureID,title:"恢复检查")
            if !control.startRequested {
                Button("开始检查") { control.startRequested = true }.accessibilityIdentifier("resume.start")
            }
            if control.stage == "resume.continued" {
                Button("完成检查") { control.finished = true }.accessibilityIdentifier("resume.finish")
            }
        }.padding().frame(maxWidth:.infinity,maxHeight:.infinity).background(Theme.background).preferredColorScheme(.dark)
        .onReceive(NotificationCenter.default.publisher(for:UIScene.willDeactivateNotification)) { _ in
            if control.startRequested { control.departed = true; print("RESUME_LIFECYCLE scene_deactivated=true") }
        }
        .onReceive(NotificationCenter.default.publisher(for:UIScene.didActivateNotification)) { _ in
            if control.departed { control.returns += 1; control.departed = false; print("RESUME_LIFECYCLE scene_reactivated=true") }
        }
    }
}
