import XCTest
import UIKit
import Metal
import simd
import ImageIO
import UniformTypeIdentifiers
@testable import PocketWorld

/// Explicitly authorised real-input experiment. Comparison never publishes; a separate opt-in
/// accepts the reviewed model through production publication while archiving the original.
/// The same selected RGB/poses/seeds/view order/iterations are used by both arms.
@MainActor final class LocalTrainingComparisonTests: XCTestCase {
    func testProfileSubjectStatisticsOnExistingScan() async throws {
        guard let id = ProcessInfo.processInfo.environment["PHOCOSCAN_LOCAL_PROFILE_SCAN"], UUID(uuidString: id) != nil else {
            throw XCTSkip("Opt-in existing scan timing")
        }
        let store = OnDeviceTrainingStore.shared
        guard !store.isTraining, !store.hasProgress(id) else { throw XCTSkip("A real job is pending") }
        let scan = try XCTUnwrap(OnDeviceTrainingStore.scanFolder(id)), old = try XCTUnwrap(store.result(captureID: id))
        let idle = UIApplication.shared.isIdleTimerDisabled; UIApplication.shared.isIdleTimerDisabled = true
        let control = TrainingRunControl()
        let observer = NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification,
            object: nil, queue: nil) { _ in control.pause() }
        defer { UIApplication.shared.isIdleTimerDisabled = idle; NotificationCenter.default.removeObserver(observer) }
        try await Task.detached {
            let fm = FileManager.default, temp = fm.temporaryDirectory.appendingPathComponent("LocalProfile-" + UUID().uuidString)
            try fm.createDirectory(at: temp, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: temp) }
            try fm.createSymbolicLink(at: temp.appendingPathComponent("capture"), withDestinationURL: scan.appendingPathComponent("capture"))
            try fm.copyItem(at: scan.appendingPathComponent("analysis.json"), to: temp.appendingPathComponent("analysis.json"))
            let data = try TrainingDataset.load(scanFolder: temp, limits: .init(maxFrames: 113,longSide: 768,maxGaussians: 250_000))
            let digest = try TrainingCheckpoint.sourceDigest(scan: temp, dataset: data, control: control)
            let oldSHA = TrainingCheckpoint.digest(try Data(contentsOf: old.model))
            let weighted = try XCTUnwrap(TrainingSubject.prepare(data, scan: temp, sourceDigest: digest, control: control)).dataset
            let device = try XCTUnwrap(MTLCreateSystemDefaultDevice()), library = try XCTUnwrap(device.makeDefaultLibrary())
            let views = TrainingQualityPlan.splitViews(count: data.frames.count).train
            for cache in [false,true] {
                var config = GaussianTrainer.Config(); config.subjectWeighting = true; config.randomSeed = 42
                config.refinement = .init(capacity: min(250_000,data.seeds.count*2),splitLarge: true)
                let trainer = try GaussianTrainer(device:device,library:library,seeds:data.seeds,cameras:data.cameras,
                    targets:weighted.targets,width:data.width,height:data.height,config:config)
                trainer.control = control; trainer.recordsTiming = true; trainer.cachesTargetStatistics = cache
                for i in 0..<300 { _ = try trainer.trainStep(cameraIndex: views[i % views.count]) }
                print("LOCAL_PROFILE cache=\(cache) timing=\(trainer.timing) points=\(trainer.count) thermal=\(ProcessInfo.processInfo.thermalState.rawValue)")
            }
            XCTAssertEqual(try TrainingCheckpoint.sourceDigest(scan: temp,dataset:data,control:control),digest)
            XCTAssertEqual(TrainingCheckpoint.digest(try Data(contentsOf:old.model)),oldSHA)
        }.value
    }

    /// Keep derived A/B models with their scan (so normal scan deletion removes them), and
    /// remove only this experiment's copied reference photos and rejected candidate directory.
    func testRetainReviewedComparisonAndCleanTemporaryMedia() throws {
        let env = ProcessInfo.processInfo.environment
        guard let id = env["PHOCOSCAN_LOCAL_AB_SCAN"], UUID(uuidString: id) != nil,
              let accepted = env["PHOCOSCAN_LOCAL_AB_RETAIN"],
              [accepted].allSatisfy({ name in
                  name.hasPrefix(id + "-") && UUID(uuidString: String(name.dropFirst(id.count + 1))) != nil
              }) else { throw XCTSkip("Explicit finished-experiment cleanup only") }
        let store = OnDeviceTrainingStore.shared
        guard !store.isTraining, !store.hasProgress(id) else { throw XCTSkip("A real job is pending") }
        let scan = try XCTUnwrap(OnDeviceTrainingStore.scanFolder(id)), current = try XCTUnwrap(store.result(captureID: id))
        let fm = FileManager.default
        let root = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("LocalTrainingComparisons")
        let source = root.appendingPathComponent(accepted)
        let sha = TrainingCheckpoint.digest(try Data(contentsOf: current.model))
        guard sha == TrainingCheckpoint.digest(try Data(contentsOf: source.appendingPathComponent("subject-density/scene.ply"))) else {
            XCTFail("Reviewed candidate is not current"); return
        }
        let destination = scan.appendingPathComponent("ondevice.comparison." + String(accepted.dropFirst(id.count + 1)))
        try fm.moveItem(at: source, to: destination)
        for file in try fm.contentsOfDirectory(at: destination, includingPropertiesForKeys: nil)
            where file.lastPathComponent.hasPrefix("reference-") && file.pathExtension == "png" { try fm.removeItem(at: file) }
        if let rejected=env["PHOCOSCAN_LOCAL_AB_REJECT"], rejected != accepted,
           rejected.hasPrefix(id+"-"), UUID(uuidString:String(rejected.dropFirst(id.count+1))) != nil {
            try fm.removeItem(at:root.appendingPathComponent(rejected))
        }
        XCTAssertEqual(TrainingCheckpoint.digest(try Data(contentsOf: current.model)), sha)
        print("LOCAL_AB_RETAINED derived_comparison=\(destination.lastPathComponent) temporary_reference_photos_removed=true")
    }

    func testPenguinSubjectAndRefinementComparison() async throws {
        guard let id = ProcessInfo.processInfo.environment["PHOCOSCAN_LOCAL_AB_SCAN"],
              UUID(uuidString: id) != nil else { throw XCTSkip("Opt-in real scan A/B") }
        let store = OnDeviceTrainingStore.shared
        guard !store.isTraining, !store.hasProgress(id) else { throw XCTSkip("Do not interfere with a pending real training session") }
        let scan = try XCTUnwrap(OnDeviceTrainingStore.scanFolder(id))
        let old = try XCTUnwrap(store.result(captureID: id))
        let control = TrainingRunControl()
        let idle = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        let observer = NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification,
            object: nil, queue: nil) { _ in control.pause() }
        defer { NotificationCenter.default.removeObserver(observer); UIApplication.shared.isIdleTimerDisabled = idle }
        let output = try await Task.detached(priority: .userInitiated) {
            try await Self.compare(scan: scan, old: old, control: control,
                geometry: ProcessInfo.processInfo.environment["PHOCOSCAN_LOCAL_AB_GEOMETRY"] == "1")
        }.value
        print("LOCAL_AB_OUTPUT " + output.path)
    }

    /// Run only after the report and matched views have been reviewed. Uses production atomic
    /// publication, keeps the original as previous, and leaves both experimental arms untouched.
    func testPublishReviewedComparisonKeepingOriginal() throws {
        guard let id = ProcessInfo.processInfo.environment["PHOCOSCAN_LOCAL_AB_SCAN"], UUID(uuidString: id) != nil,
              let name = ProcessInfo.processInfo.environment["PHOCOSCAN_LOCAL_AB_PUBLISH"],
              name.hasPrefix(id + "-"), UUID(uuidString: String(name.dropFirst(id.count+1))) != nil else {
            throw XCTSkip("Explicit reviewed-comparison publication only")
        }
        let store = OnDeviceTrainingStore.shared
        guard !store.isTraining, !store.hasProgress(id) else { throw XCTSkip("A real job is pending") }
        let scan = try XCTUnwrap(OnDeviceTrainingStore.scanFolder(id)), old = try XCTUnwrap(store.result(captureID: id))
        let fm = FileManager.default
        let comparison = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LocalTrainingComparisons/" + name)
        let reports = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: comparison.appendingPathComponent("comparison.json"))) as? [[String: Any]])
        let baseline = try XCTUnwrap(reports.first { $0["arm"] as? String == "baseline" })
        let candidate = try XCTUnwrap(reports.first { $0["arm"] as? String == "subject-density" })
        let oldHash = try XCTUnwrap(candidate["oldModelHash"] as? String)
        let geometry = candidate["trainerVersion"] as? Int == 4
        func value(_ object:[String:Any],_ key:String) throws -> Double { try XCTUnwrap((object[key] as? NSNumber)?.doubleValue) }
        let quality = try geometry
            ? (value(candidate,"subjectMAE") <= value(baseline,"subjectMAE")*1.03
               && value(candidate,"subjectPSNR") >= value(baseline,"subjectPSNR")-0.3
               && value(candidate,"needleCountOver12") < value(baseline,"needleCountOver12")
               && value(candidate,"seconds") < value(baseline,"seconds"))
            : (value(candidate,"subjectMAE") < value(baseline,"subjectMAE") && value(candidate,"subjectPSNR") > value(baseline,"subjectPSNR"))
        guard TrainingCheckpoint.digest(try Data(contentsOf: old.model)) == oldHash,
              quality else {
            XCTFail("Current result changed, or candidate did not improve the matched subject evaluation"); return
        }
        let data = try TrainingDataset.load(scanFolder: scan, limits: .init(maxFrames: 113,longSide: 768,maxGaussians: 250_000))
        let digest = try TrainingCheckpoint.sourceDigest(scan: scan, dataset: data, control: TrainingRunControl())
        XCTAssertEqual(digest, candidate["sourceDigest"] as? String)
        guard digest == candidate["sourceDigest"] as? String else { return }
        let source = comparison.appendingPathComponent("subject-density")
        let allViews = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: comparison.appendingPathComponent("all-views.json"))) as? [[String: Any]])
        let allBefore = try XCTUnwrap(allViews.first { $0["arm"] as? String == "baseline" })
        let allAfter = try XCTUnwrap(allViews.first { $0["arm"] as? String == "subject-density" })
        let allQuality = try geometry
            ? (value(allAfter,"subjectMAE") <= value(allBefore,"subjectMAE")*1.03
               && value(allAfter,"silhouetteFalsePositivePixels") < value(allBefore,"silhouetteFalsePositivePixels")
               && value(allAfter,"silhouetteRecall") >= value(allBefore,"silhouetteRecall")-0.05
               && value(allAfter,"subjectGaussians") >= 100)
            : value(allAfter,"subjectMAE") < value(allBefore,"subjectMAE")
        guard allQuality,
              allAfter["sourceDigest"] as? String == digest,
              allAfter["modelSHA"] as? String == TrainingCheckpoint.digest(try Data(contentsOf: source.appendingPathComponent("scene.ply"))) else {
            XCTFail("Complete held-out arc did not pass or reviewed model changed"); return
        }
        let staging = scan.appendingPathComponent("ondevice.reviewed." + UUID().uuidString)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        if geometry {
            guard allAfter["subjectModelSHA"] as? String == TrainingCheckpoint.digest(try Data(contentsOf:source.appendingPathComponent("subject.ply"))) else {
                XCTFail("Reviewed subject derivative changed"); return
            }
        }
        for file in ["scene.ply", "cameras.json", "meta.json"] + (geometry ? ["subject.ply"] : []) {
            try fm.copyItem(at: source.appendingPathComponent(file), to: staging.appendingPathComponent(file))
        }
        var publishedMeta = candidate
        publishedMeta["allViewsEvaluation"] = allAfter
        if geometry { publishedMeta["subjectGaussians"] = allAfter["subjectGaussians"]; publishedMeta["surfaceVersion"] = 2 }
        publishedMeta["createdAt"] = Date().ISO8601Format()
        try JSONSerialization.data(withJSONObject: publishedMeta, options: [.prettyPrinted,.sortedKeys])
            .write(to: staging.appendingPathComponent("meta.json"),options: .atomic)
        let newHash = TrainingCheckpoint.digest(try Data(contentsOf: staging.appendingPathComponent("scene.ply")))
        try OnDeviceTrainingStore.publish(staging: staging, final: scan.appendingPathComponent("ondevice"))
        let current = try XCTUnwrap(store.result(captureID: id)), previous = try XCTUnwrap(store.previousResult(captureID: id))
        XCTAssertEqual(TrainingCheckpoint.digest(try Data(contentsOf: current.model)), newHash)
        XCTAssertEqual(TrainingCheckpoint.digest(try Data(contentsOf: previous.model)), oldHash)
        XCTAssertEqual(try TrainingCheckpoint.sourceDigest(scan: scan, dataset: data, control: TrainingRunControl()), digest)
        print("LOCAL_AB_PUBLISHED current=\(current.gaussians) previous_sha_unchanged=true source_sha_unchanged=true archive=\(previous.model.deletingLastPathComponent().lastPathComponent)")
    }

    /// Evaluate the exported files across the entire held-out camera arc, including its back half.
    func testExportedComparisonAcrossAllHeldOutViews() async throws {
        let geometry = ProcessInfo.processInfo.environment["PHOCOSCAN_LOCAL_AB_GEOMETRY"] == "1"
        guard let id = ProcessInfo.processInfo.environment["PHOCOSCAN_LOCAL_AB_SCAN"], UUID(uuidString: id) != nil,
              let name = ProcessInfo.processInfo.environment["PHOCOSCAN_LOCAL_AB_EVALUATE"],
              name.hasPrefix(id + "-"), UUID(uuidString: String(name.dropFirst(id.count+1))) != nil else { throw XCTSkip("Opt-in exported comparison") }
        let scan = try XCTUnwrap(OnDeviceTrainingStore.scanFolder(id))
        let comparison = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LocalTrainingComparisons/" + name)
        let control = TrainingRunControl(), idle = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        let observer = NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification,
            object: nil, queue: nil) { _ in control.pause() }
        defer { NotificationCenter.default.removeObserver(observer); UIApplication.shared.isIdleTimerDisabled = idle }
        try await Task.detached {
            let fm = FileManager.default, temp = fm.temporaryDirectory.appendingPathComponent("LocalEval-" + UUID().uuidString)
            try fm.createDirectory(at: temp, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: temp) }
            try fm.createSymbolicLink(at: temp.appendingPathComponent("capture"), withDestinationURL: scan.appendingPathComponent("capture"))
            try fm.copyItem(at: scan.appendingPathComponent("analysis.json"), to: temp.appendingPathComponent("analysis.json"))
            let raw = try TrainingDataset.load(scanFolder: temp, limits: .init(maxFrames: 113,longSide: 768,maxGaussians: 250_000))
            let source = try TrainingCheckpoint.sourceDigest(scan: temp, dataset: raw, control: control)
            let prepared = try XCTUnwrap(TrainingSubject.prepare(raw, scan: temp, sourceDigest: source, control: control))
            let data = prepared.dataset, held = TrainingQualityPlan.splitViews(count: data.frames.count).validation
            let device = try XCTUnwrap(MTLCreateSystemDefaultDevice()), library = try XCTUnwrap(device.makeDefaultLibrary())
            var reports: [[String: Any]] = []
            for name in ["baseline", "subject-density"] {
                let folder = comparison.appendingPathComponent(name), model = folder.appendingPathComponent("scene.ply")
                let bytes = try Data(contentsOf: model), sha = TrainingCheckpoint.digest(bytes)
                let end = try XCTUnwrap(bytes.range(of: Data("end_header\n".utf8)))
                let header = String(decoding: bytes[..<end.lowerBound], as: UTF8.self)
                XCTAssertEqual(header.split(separator: "\n").filter { $0.hasPrefix("property float ") }.count, 17)
                let count = (bytes.count - end.upperBound) / 68
                var seeds: [GaussianSeed] = [], values: [[SIMD4<Float>]] = [[], [], [], []]
                bytes.withUnsafeBytes { buffer in
                    let base = buffer.baseAddress!.advanced(by: end.upperBound)
                    for i in 0..<count {
                        let p = base.advanced(by: i*68)
                        func v(_ j: Int) -> Float { p.loadUnaligned(fromByteOffset: j*4, as: Float.self) }
                        seeds.append(.init(position: SIMD3(v(0),v(1),v(2)),size: exp(v(10)),color: SIMD3(repeating: 0.5)))
                        values[0].append(SIMD4(v(0),v(1),v(2),0)); values[1].append(SIMD4(v(10),v(11),v(12),0))
                        values[2].append(SIMD4(v(13),v(14),v(15),v(16))); values[3].append(SIMD4(v(6),v(7),v(8),v(9)))
                    }
                }
                let trainer = try GaussianTrainer(device: device,library: library,seeds: seeds,cameras: data.cameras,
                    targets: data.targets,width: data.width,height: data.height)
                trainer.control = control
                for (i, b) in [trainer.means,trainer.logScales,trainer.quats,trainer.colorOp].enumerated() {
                    values[i].withUnsafeBytes { b.contents().copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
                }
                let full = try TrainingViewMetrics.evaluate(trainer: trainer,dataset: data,indices: held)
                let subject = try TrainingViewMetrics.evaluate(trainer: trainer,dataset: data,indices: held,subjectOnly: true)
                for index in held.suffix(2) {
                    let image = try trainer.render(cameraIndex: index)
                    let rgba = image.flatMap { p in (0..<3).map { UInt8(min(255,max(0,Int((p[$0]*255).rounded())))) } + [255] }
                    try Self.png(Data(rgba),width:data.width,height:data.height,to:folder.appendingPathComponent("view-\(index).png"))
                }
                var report: [String: Any] = ["arm": name,"views": held.count,"indices": held,"sourceDigest": source,
                    "subjectDigest": prepared.digest,"modelSHA": sha,"subjectMAE": subject.mae,"subjectPSNR": subject.psnr,
                    "fullMAE": full.mae,"fullPSNR": full.psnr]
                if geometry {
                    let target = try XCTUnwrap(ScanAnalysis.load(from:scan)?.targetBox)
                    let crop = SplatCrop(region:SplatCrop.region(for:target),rotation:matrix_identity_float3x3,scale:1,
                        translation:.zero,fitError:0,matchedCameras:data.frames.count)
                    var keep = Set(0..<count)
                    if name == "subject-density" {
                        let selection = try TrainingSubjectSurface.select(device:device,library:library,dataset:data,
                            means:values[0],logScales:values[1],quats:values[2],control:control)
                        let subjectURL=folder.appendingPathComponent("subject.ply")
                        report["subjectGaussians"] = try TrainingSubjectSurface.write(selection,means:values[0],logScales:values[1],
                            quats:values[2],colorOp:values[3],to:subjectURL)
                        report["subjectModelSHA"] = TrainingCheckpoint.digest(try Data(contentsOf:subjectURL))
                        report["surfaceVersion"] = 2
                        keep = Set(selection.indices)
                    }
                    for i in 0..<count {
                        let p=values[0][i], c=values[3][i]
                        if !keep.contains(i) || !crop.keeps(position:SIMD3(p.x,p.y,p.z),opacity:1/(1+exp(-c.w))) {
                            trainer.setParameter(trainer.colorOp,index:i,value:SIMD4(c.x,c.y,c.z,-100))
                        }
                    }
                    var tp=0.0,fp=0.0,fn=0.0
                    for index in held {
                        let image=try trainer.render(cameraIndex:index)
                        data.targets.withUnsafeBytes { raw in
                            let bytes=raw.bindMemory(to:UInt8.self), offset=data.cameras[index].imageIndex*data.width*data.height*4
                            for i in image.indices {
                                let truth=bytes[offset+i*4+3]>=128, predicted=(1-image[i].w)>0.2
                                if truth && predicted { tp+=1 }; if !truth && predicted { fp+=1 }; if truth && !predicted { fn+=1 }
                            }
                        }
                        if [held.first!,held[min(2,held.count-1)],held.last!].contains(index) {
                            let rgba=image.flatMap { p in (0..<3).map { UInt8(min(255,max(0,Int((p[$0]*255).rounded())))) }+[255] }
                            try Self.png(Data(rgba),width:data.width,height:data.height,to:folder.appendingPathComponent("subject-view-\(index).png"))
                        }
                    }
                    report["silhouetteFalsePositivePixels"]=fp
                    report["silhouetteRecall"]=tp/max(1,tp+fn)
                    report["silhouettePrecision"]=tp/max(1,tp+fp)
                    report["silhouetteIoU"]=tp/max(1,tp+fp+fn)
                }
                reports.append(report)
                print("LOCAL_AB_ALL_VIEWS " + String(decoding: try JSONSerialization.data(withJSONObject: report,options: [.sortedKeys]), as: UTF8.self))
                XCTAssertEqual(TrainingCheckpoint.digest(try Data(contentsOf: model)),sha)
            }
            try JSONSerialization.data(withJSONObject: reports,options: [.prettyPrinted,.sortedKeys])
                .write(to: comparison.appendingPathComponent("all-views.json"),options: .atomic)
        }.value
    }

    nonisolated private static func compare(scan: URL, old: OnDeviceTrainingStore.Result,
                                             control: TrainingRunControl, geometry: Bool = false) async throws -> URL {
        let fm = FileManager.default
        let temp = fm.temporaryDirectory.appendingPathComponent("LocalAB-\(UUID().uuidString)")
        try fm.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: temp) }
        try fm.createSymbolicLink(at: temp.appendingPathComponent("capture"), withDestinationURL: scan.appendingPathComponent("capture"))
        try fm.copyItem(at: scan.appendingPathComponent("analysis.json"), to: temp.appendingPathComponent("analysis.json"))
        let output = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LocalTrainingComparisons/\(scan.deletingPathExtension().lastPathComponent)-\(UUID().uuidString)")
        try fm.createDirectory(at: output, withIntermediateDirectories: true)
        let oldHash = TrainingCheckpoint.digest(try Data(contentsOf: old.model))
        let cameraHash = TrainingCheckpoint.digest(try Data(contentsOf: old.cameras))
        let limits = TrainingDataset.Limits(maxFrames: 113, longSide: 768, maxGaussians: 250_000)
        let raw = try TrainingDataset.load(scanFolder: temp, limits: limits)
        let sourceDigest = try TrainingCheckpoint.sourceDigest(scan: temp, dataset: raw, control: control)
        print("LOCAL_AB preparation frames=\(raw.frames.count) seeds=\(raw.seeds.count)")
        let prepared = try XCTUnwrap(TrainingSubject.prepare(raw, scan: temp, sourceDigest: sourceDigest, control: control))
        let dataset = prepared.dataset
        let split = TrainingQualityPlan.splitViews(count: dataset.cameras.count)
        let held = geometry ? split.validation : Array(split.validation.prefix(8))
        XCTAssertFalse(held.isEmpty)
        print("LOCAL_AB masks=\(prepared.maskedFrames)/\(dataset.frames.count) held=\(held.count)")
        var random = TrainingRandom(state: 151515)
        var order: [Int] = []
        while order.count < 3000 { order += split.train.shuffled(using: &random) }
        guard let device = MTLCreateSystemDefaultDevice(), device.supportsFamily(.apple7),
              let library = device.makeDefaultLibrary() else { throw GaussianTrainerError.metalUnavailable }
        var reports: [[String: Any]] = []
        for candidate in [false, true] {
            let name = candidate ? "subject-density" : "baseline"
            let folder = output.appendingPathComponent(name)
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            var config = GaussianTrainer.Config(); config.randomSeed = 151515
            config.subjectWeighting = geometry || candidate
            if geometry || candidate { config.refinement = .init(capacity: min(250_000, dataset.seeds.count * 2), splitLarge: true) }
            if geometry && candidate { config.lineAspectLimit = 12 }
            func make() throws -> GaussianTrainer {
                let t = try GaussianTrainer(device: device, library: library, seeds: dataset.seeds,
                    cameras: dataset.cameras, targets: dataset.targets, width: dataset.width, height: dataset.height, config: config)
                t.control = control; t.recordsTiming = geometry
                t.cachesTargetStatistics = !geometry || candidate
                return t
            }
            var trainer: GaussianTrainer? = try make()
            try trainer!.setTrainingViews(split.train)
            let started = Date(); var peak = 0
            for i in 1...3000 {
                try control.check()
                if ProcessInfo.processInfo.thermalState == .critical { throw TrainingPaused() }
                trainer!.setResolution(divisor: TrainingQualityPlan.resolutionDivisor(iteration: i, total: 3000))
                _ = try autoreleasepool { try trainer!.trainStep(cameraIndex: order[i-1]) }
                peak = max(peak, trainer!.workingSetBytes)
                if candidate && i == 1499 {
                    let session = TrainingCheckpoint.Session(id: UUID(), plan: .init(limits: limits,
                        metalBudget: config.memoryBudgetBytes, pairLimit: config.pairLimit), config: config,
                        sourceDigest: sourceDigest, subjectDigest: prepared.digest)
                    try TrainingCheckpoint.save(temp, session: session, trainer: trainer!, control: control)
                    let savedCount = trainer!.count
                    trainer = nil
                    let header = try XCTUnwrap(TrainingCheckpoint.read(temp))
                    let restoredInput = try XCTUnwrap(TrainingSubject.prepare(raw, scan: temp, sourceDigest: sourceDigest,
                        expectedDigest: header.session.subjectDigest, control: control))
                    XCTAssertEqual(restoredInput.digest, prepared.digest)
                    trainer = try make()
                    try TrainingCheckpoint.restore(temp, header: header, trainer: trainer!)
                    XCTAssertEqual(trainer!.step, 1499); XCTAssertEqual(trainer!.count, savedCount)
                    print("LOCAL_AB resumed step=1499 points=\(savedCount) mask_digest_unchanged=true")
                }
                if i % 500 == 0 { print("LOCAL_AB_PROGRESS arm=\(name) step=\(i) points=\(trainer!.count) metalMiB=\(peak/1048576)") }
                if ProcessInfo.processInfo.thermalState == .serious { try await Task.sleep(for: .milliseconds(10)) }
            }
            let full = try TrainingViewMetrics.evaluate(trainer: trainer!, dataset: dataset, indices: held)
            let subject = try TrainingViewMetrics.evaluate(trainer: trainer!, dataset: dataset, indices: held, subjectOnly: true)
            let parameters = trainer!.parameters()
            let kept = try TrainingOutput.writePLY(means: parameters.means, logScales: parameters.logScales,
                quats: parameters.quats, colorOp: parameters.colorOp, to: folder.appendingPathComponent("scene.ply"))
            try TrainingOutput.writeCameras(dataset.frames, to: folder.appendingPathComponent("cameras.json"))
            for index in held.prefix(3) {
                let image = try trainer!.render(cameraIndex: index)
                let rgb = image.flatMap { p in (0..<3).map { UInt8(min(255, max(0, Int((p[$0]*255).rounded())))) } + [255] }
                try png(Data(rgb), width: dataset.width, height: dataset.height, to: folder.appendingPathComponent("view-\(index).png"))
                if !candidate {
                    let n = dataset.width * dataset.height * 4, offset = index * dataset.width * dataset.height * 4
                    var original = dataset.targets.subdata(in: offset..<(offset+n))
                    for i in stride(from: 3, to: original.count, by: 4) { original[i] = 255 }
                    try png(original, width: dataset.width, height: dataset.height, to: output.appendingPathComponent("reference-\(index).png"))
                }
            }
            var report: [String: Any] = ["arm": name, "trainerVersion": geometry ? (candidate ? 4 : 3) : (candidate ? 3 : 2),
                "iterations": 3000, "keyframes": dataset.frames.count, "resolution": [dataset.width,dataset.height],
                "seedGaussians": dataset.seeds.count, "finalTrainingGaussians": trainer!.count, "gaussians": kept,
                "seconds": Int(Date().timeIntervalSince(started)), "peakObservedMetalBytes": peak,
                "fullMAE": full.mae, "fullPSNR": full.psnr, "subjectMAE": subject.mae, "subjectPSNR": subject.psnr,
                "sourceDigest": sourceDigest, "subjectDigest": prepared.digest, "oldModelHash": oldHash,
                "maskedFrames": prepared.maskedFrames, "heldOutIndices": held, "checkpointRestored": candidate,
                "splitLarge": config.refinement?.splitLarge == true]
            if geometry {
                report["timing"] = trainer!.timing
                let selection = try TrainingSubjectSurface.select(device:device,library:library,dataset:dataset,
                    means:parameters.means,logScales:parameters.logScales,quats:parameters.quats,control:control)
                let scales = parameters.logScales.map { p -> Float in
                    let s=[p.x,p.y,p.z].sorted();return exp(s[2]-s[1])
                }
                report["needleCountOver12"] = scales.filter { $0 > 12.01 }.count
                report["unsupportedCenters"] = selection.unsupportedCenters
                report["unsupportedExtents"] = selection.unsupportedExtents
                if candidate {
                    report["subjectGaussians"] = try TrainingSubjectSurface.write(selection,means:parameters.means,logScales:parameters.logScales,
                        quats:parameters.quats,colorOp:parameters.colorOp,to:folder.appendingPathComponent("subject.ply"))
                }
                if let target = ScanAnalysis.load(from:scan)?.targetBox {
                    let crop=SplatCrop(region:SplatCrop.region(for:target),rotation:matrix_identity_float3x3,scale:1,
                        translation:.zero,fitError:0,matchedCameras:dataset.frames.count)
                    let selected=Set(selection.indices)
                    for i in parameters.means.indices {
                        let p=parameters.means[i], c=parameters.colorOp[i]
                        if !crop.keeps(position:SIMD3(p.x,p.y,p.z),opacity:1/(1+exp(-c.w))) || (candidate && !selected.contains(i)) {
                            trainer!.setParameter(trainer!.colorOp,index:i,value:SIMD4(c.x,c.y,c.z,-100))
                        }
                    }
                    for index in [held[0],held[min(2,held.count-1)],held.last!] {
                        let rendered=try trainer!.render(cameraIndex:index)
                        let rgba=rendered.flatMap { p in (0..<3).map { UInt8(min(255,max(0,Int((p[$0]*255).rounded())))) }+[255] }
                        try png(Data(rgba),width:dataset.width,height:dataset.height,to:folder.appendingPathComponent("subject-view-\(index).png"))
                    }
                }
            }
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted,.sortedKeys])
                .write(to: folder.appendingPathComponent("meta.json"), options: .atomic)
            print("LOCAL_AB_RESULT " + String(decoding: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), as: UTF8.self))
            reports.append(report); trainer = nil
        }
        XCTAssertEqual(try TrainingCheckpoint.sourceDigest(scan: temp, dataset: raw, control: control), sourceDigest)
        XCTAssertEqual(TrainingCheckpoint.digest(try Data(contentsOf: old.model)), oldHash)
        XCTAssertEqual(TrainingCheckpoint.digest(try Data(contentsOf: old.cameras)), cameraHash)
        try JSONSerialization.data(withJSONObject: reports, options: [.prettyPrinted,.sortedKeys])
            .write(to: output.appendingPathComponent("comparison.json"), options: .atomic)
        print("LOCAL_AB original_inputs_and_current_result_unchanged=true")
        return output
    }

    nonisolated private static func png(_ rgba: Data, width: Int, height: Int, to url: URL) throws {
        guard let provider = CGDataProvider(data: rgba as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: width*4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider,
                decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw GaussianTrainerError.invalidInput
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw GaussianTrainerError.invalidInput }
    }
}
