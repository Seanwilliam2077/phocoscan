import Foundation
import Metal
import UIKit
import os

/// Runs 3DGS training on this iPhone's GPU for one scan at a time (本机版). Inputs are the scan's
/// keyframes, ARKit poses and LiDAR points; nothing is uploaded. The result lives in the scan
/// folder (`<scan>/ondevice/`), so deleting the scan deletes it. Training needs the app in the
/// foreground. On deactivation it checkpoints CPU-visible state and resumes when active again.
@MainActor
final class OnDeviceTrainingStore: ObservableObject {
    static let shared = OnDeviceTrainingStore()

    enum Phase: Equatable {
        case preparing
        case training(progress: Double, secondsLeft: Int?, hot: Bool)
        case saving
        case paused(progress: Double)
        case failed(String)
    }

    struct Result: Equatable, Identifiable {
        var id: URL { model }
        var subjectModel: URL? {
            let url = model.deletingLastPathComponent().appendingPathComponent("subject.ply")
            return FileManager.default.fileExists(atPath:url.path) ? url : nil
        }
        let model: URL
        let cameras: URL
        let iterations: Int
        let seconds: Int
        let gaussians: Int
    }

    @Published private(set) var phases: [String: Phase] = [:]
    @Published private(set) var revision = 0
    private var worker: Task<Void, Error>?
    private var runningID: String?
    private var runToken: UUID?
    private var control: TrainingRunControl?
    private var previousIdleTimerDisabled = false
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var foreground = false
    private var discarding = false
    private var lifecycleObservers: [NSObjectProtocol] = []
    private let defaults: UserDefaults
    private let resolveFolder: (String) -> URL?
    private let planOverride: TrainingQualityPlan?
    private let iterationCount: Int
    private let managesApplication: Bool
    private static let pendingKey = "PocketWorld.localTraining.pending.v1"
    private struct Intent: Codable {
        let captureID: String
        let sessionID: UUID
        var autoResume: Bool
    }
    private var pending: Intent?

    nonisolated static let iterations = 3000
    nonisolated static let folderName = "ondevice"
    var isTraining: Bool { runningID != nil }
    func hasProgress(_ captureID: String) -> Bool { pending?.captureID == captureID }

    init(defaults: UserDefaults = .standard, folderResolver: ((String) -> URL?)? = nil,
         plan: TrainingQualityPlan? = nil, iterations: Int = 3000, managesApplication: Bool = true) {
        self.defaults = defaults; self.resolveFolder = folderResolver ?? Self.scanFolder
        self.planOverride = plan; self.iterationCount = iterations; self.managesApplication = managesApplication
        restoreIntentIfNeeded()
    }
    private func restoreIntentIfNeeded() {
        guard pending == nil, runningID == nil else { return }
        if let bytes = defaults.data(forKey: Self.pendingKey), let intent = try? JSONDecoder().decode(Intent.self, from: bytes),
           let folder = resolveFolder(intent.captureID), FileManager.default.fileExists(atPath: folder.path) {
            pending = intent
            phases[intent.captureID] = .paused(progress: Self.savedProgress(folder))
        }
    }
    /// App-wide observation also works while a viewer, camera or another screen is presented.
    func activate() {
        guard managesApplication, lifecycleObservers.isEmpty else { return }
        let center = NotificationCenter.default
        lifecycleObservers = [
            center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.appWillResignActive() }
            },
            center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.appDidBecomeActive() }
            },
            center.addObserver(forName: UIScene.willDeactivateNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.appWillResignActive() }
            },
            center.addObserver(forName: UIScene.didActivateNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.appDidBecomeActive() }
            }
        ]
        if UIApplication.shared.applicationState == .active { appDidBecomeActive() }
    }

    private func persistIntent() {
        if let pending { defaults.set(try? JSONEncoder().encode(pending), forKey: Self.pendingKey) }
        else { defaults.removeObject(forKey: Self.pendingKey) }
    }
    private nonisolated static func savedProgress(_ folder: URL) -> Double {
        guard let h = try? TrainingCheckpoint.read(folder) else { return 0 }
        return Double(h.state.step) / Double(h.session.config.iterations)
    }

    static func scanFolder(_ captureID: String) -> URL? {
        try? ARScanRecorder.packagesDirectory().appendingPathComponent(captureID + ".scan", isDirectory: true)
    }

    static func canTrain(captureID: String) -> Bool {
        guard let folder = scanFolder(captureID), TrainingDataset.available(scanFolder: folder),
              let device = MTLCreateSystemDefaultDevice() else { return false }
        return device.supportsFamily(.apple7)
    }

    func result(captureID: String) -> Result? {
        _ = revision
        guard let folder = resolveFolder(captureID)?.appendingPathComponent(Self.folderName) else { return nil }
        return Self.readResult(folder)
    }

    func previousResult(captureID: String) -> Result? {
        guard let scan = resolveFolder(captureID) else { return nil }
        return ((try? FileManager.default.contentsOfDirectory(at: scan, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("ondevice.previous.") }
            .sorted { ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
                > ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
            .compactMap(Self.readResult).first
    }

    private static func readResult(_ folder: URL) -> Result? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("meta.json")),
              let meta = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let model = folder.appendingPathComponent("scene.ply"), cameras = folder.appendingPathComponent("cameras.json")
        guard FileManager.default.fileExists(atPath: model.path), FileManager.default.fileExists(atPath: cameras.path) else { return nil }
        return Result(model: model, cameras: cameras, iterations: meta["iterations"] as? Int ?? 0,
                      seconds: meta["seconds"] as? Int ?? 0, gaussians: meta["gaussians"] as? Int ?? 0)
    }

    func start(captureID: String) {
        guard runningID == nil, !discarding, let folder = resolveFolder(captureID) else { return }
        guard pending == nil || pending?.captureID == captureID else {
            phases[captureID] = .failed("请先继续或放弃另一份扫描的训练进度。")
            return
        }
        if pending == nil { pending = Intent(captureID: captureID, sessionID: UUID(), autoResume: true) }
        pending?.autoResume = true
        persistIntent()
        if !managesApplication || UIApplication.shared.applicationState == .active { foreground = true }
        guard foreground, let intent = pending else { phases[captureID] = .paused(progress: Self.savedProgress(folder)); return }
        runningID = captureID
        let token = UUID(), control = TrainingRunControl()
        runToken = token; self.control = control
        phases[captureID] = .preparing
        if managesApplication {
            previousIdleTimerDisabled = UIApplication.shared.isIdleTimerDisabled
            UIApplication.shared.isIdleTimerDisabled = true
        }
        let plan = planOverride, count = iterationCount, sessionID = intent.sessionID
        let worker = Task.detached(priority: .userInitiated) { [store = self] in
            try await Self.train(scanFolder: folder, sessionID: sessionID, control: control, planOverride: plan, iterations: count) { phase in
                await store.update(captureID, token: token, phase)
            }
        }
        self.worker = worker
        Task { [weak self] in self?.finish(captureID, token: token, await worker.result) }
    }

    /// Explicit retraining discards only this unfinished job; completed models stay intact.
    func restart(captureID: String) async {
        guard runningID == nil || runningID == captureID else { return }
        await cancelIfTraining(captureID: captureID)
        start(captureID: captureID)
    }

    private func update(_ captureID: String, token: UUID, _ phase: Phase) {
        guard runToken == token, foreground, !discarding else { return }
        phases[captureID] = phase
    }

    private func finish(_ captureID: String, token: UUID, _ outcome: Swift.Result<Void, Error>) {
        guard runToken == token else { return }
        runningID = nil; worker = nil; runToken = nil; control = nil
        if managesApplication { UIApplication.shared.isIdleTimerDisabled = previousIdleTimerDisabled }
        endBackgroundTask()
        if discarding { return }
        switch outcome {
        case .success:
            pending = nil; persistIntent(); phases[captureID] = nil; revision += 1
        case .failure(let error) where error is TrainingPaused || !foreground:
            let progress = resolveFolder(captureID).map(Self.savedProgress) ?? 0
            phases[captureID] = .paused(progress: progress)
            if foreground && pending?.autoResume == true { start(captureID: captureID) }
        case .failure(let error):
            phases[captureID] = .failed(Self.message(for: error))
        }
    }

    /// Manual pause stays paused until Continue; a lifecycle pause resumes on return.
    func pause() {
        pending?.autoResume = false; persistIntent()
        control?.pause()
    }

    func cancel() {
        guard let id = pending?.captureID else { return }
        Task { await cancelIfTraining(captureID: id) }
    }

    /// Drain the worker before deleting progress or the scan. A late completion cannot restart it.
    func cancelIfTraining(captureID: String) async {
        guard pending?.captureID == captureID || runningID == captureID else { return }
        discarding = true
        pending = nil; persistIntent()
        control?.cancel(); worker?.cancel()
        if let worker, let token = runToken {
            let outcome = await worker.result
            finish(captureID, token: token, outcome)
        }
        if let folder = resolveFolder(captureID) {
            do { try TrainingCheckpoint.remove(folder); phases[captureID] = nil }
            catch { phases[captureID] = .failed(Self.message(for: error)) }
        }
        discarding = false
    }

    func appWillResignActive() {
        foreground = false
        guard runningID != nil else { return }
        // Gate first, before returning to UIKit. No new GPU work after deactivation.
        control?.pause()
        if managesApplication && backgroundTask == .invalid {
            backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Save local training") { [weak self] in
                Task { @MainActor in
                    self?.control?.expire() // retain the previous committed generation on expiry
                    self?.endBackgroundTask()
                }
            }
        }
    }

    func appDidBecomeActive() {
        foreground = true
        restoreIntentIfNeeded()
        guard !discarding, runningID == nil, let pending, pending.autoResume else { return }
        // Failed checkpoints require an explicit Continue; never repeatedly retry damaged data.
        if case .failed = phases[pending.captureID] { return }
        start(captureID: pending.captureID)
    }

    private func endBackgroundTask() {
        if backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask); backgroundTask = .invalid
        }
    }

    private static func message(for error: Error) -> String {
        if let error = error as? LocalizedError, let text = error.errorDescription { return text }
        return "本机训练没有完成：\(error.localizedDescription)"
    }

    // MARK: Training (off the main actor)

    private nonisolated static func train(scanFolder: URL, sessionID: UUID, control: TrainingRunControl,
                                          planOverride: TrainingQualityPlan?, iterations: Int,
                                          report: @escaping @Sendable (Phase) async -> Void) async throws {
        // Handles termination between successful publication and clearing the pending intent.
        let finalMeta = scanFolder.appendingPathComponent(folderName + "/meta.json")
        if let data = try? Data(contentsOf: finalMeta),
           let meta = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           meta["trainingSessionID"] as? String == sessionID.uuidString {
            try TrainingCheckpoint.remove(scanFolder); return
        }
        try control.check()
        guard let device = MTLCreateSystemDefaultDevice(), device.supportsFamily(.apple7),
              let library = device.makeDefaultLibrary() else { throw GaussianTrainerError.metalUnavailable }
        let saved = try TrainingCheckpoint.read(scanFolder)
        if let saved, saved.session.id != sessionID { throw TrainingCheckpoint.Failure.invalid }
        let plan = try saved?.session.plan ?? planOverride ?? TrainingQualityPlan.make(
            physicalMemory: ProcessInfo.processInfo.physicalMemory, availableMemory: Int(os_proc_available_memory()))
        // Keep the original frame selection/resolution. Low memory must not silently change inputs.
        let inputBytes = plan.limits.maxFrames * plan.limits.longSide * plan.limits.longSide * 4
        guard Int(os_proc_available_memory()) > inputBytes + plan.metalBudget + 96 * 1024 * 1024 else {
            throw GaussianTrainerError.memoryBudget
        }
        var dataset = try TrainingDataset.load(scanFolder: scanFolder, limits: plan.limits)
        try control.check()
        let digest = try TrainingCheckpoint.sourceDigest(scan: scanFolder, dataset: dataset, control: control)
        if let saved, saved.session.sourceDigest != digest { throw TrainingCheckpoint.Failure.changedSource }
        var config = saved?.session.config ?? GaussianTrainer.Config()
        var subject: TrainingSubject.Prepared?
        // Never upgrade a legacy paused job halfway through its original optimisation.
        if saved == nil || saved?.session.subjectDigest != nil {
            subject = try TrainingSubject.prepare(dataset, scan: scanFolder, sourceDigest: digest,
                expectedDigest: saved?.session.subjectDigest, control: control)
            if let subject { dataset = subject.dataset }
        }
        if saved == nil {
            config.iterations = iterations; config.memoryBudgetBytes = plan.metalBudget; config.pairLimit = plan.pairLimit
            config.subjectWeighting = subject != nil
            config.lineAspectLimit = subject == nil ? nil : 12
            config.refinement = .init(capacity: min(plan.limits.maxGaussians, max(dataset.seeds.count, min(250_000, dataset.seeds.count * 2))), splitLarge: true)
        }
        let iterations = config.iterations
        let trainer = try GaussianTrainer(device: device, library: library, seeds: dataset.seeds, cameras: dataset.cameras,
                                          targets: dataset.targets, width: dataset.width, height: dataset.height, config: config)
        trainer.control = control
        var session = saved?.session ?? TrainingCheckpoint.Session(id: sessionID, plan: plan, config: config, sourceDigest: digest, subjectDigest: subject?.digest)
        if let saved { try TrainingCheckpoint.restore(scanFolder, header: saved, trainer: trainer) }
        let started = Date()
        let split = TrainingQualityPlan.splitViews(count: dataset.cameras.count)
        if saved == nil { try trainer.setTrainingViews(split.train) }
        // For short captures report sampled training views honestly; otherwise these are held out.
        let evaluationViews = split.validation.isEmpty ? Array(split.train.prefix(4)) : Array(split.validation.prefix(8))
        let elapsedBefore = session.elapsed
        func checkpoint() throws {
            session.elapsed = elapsedBefore + Date().timeIntervalSince(started)
            session.peakMetal = max(session.peakMetal, trainer.workingSetBytes)
            try TrainingCheckpoint.save(scanFolder, session: session, trainer: trainer, control: control)
        }
        // Also preserve step zero before evaluation; a pause here can resume preparation safely.
        if saved == nil { try checkpoint() }
        do {
        if session.before == nil { session.before = try TrainingViewMetrics.evaluate(trainer: trainer, dataset: dataset, indices: evaluationViews) }
        let before = session.before!
        var lastCheckpoint = Date()
        var lastReport = Date.distantPast
        var lastError: Float? = session.lastError
        var peakMetal = max(session.peakMetal, trainer.workingSetBytes)
        var stepSeconds = 0.0
        var previousDivisor = 0
        while trainer.step < iterations {
            try Task.checkCancellation()
            try control.check()
            let iteration = trainer.step + 1
            let divisor = TrainingQualityPlan.resolutionDivisor(iteration: iteration, total: iterations)
            if divisor != previousDivisor {
                trainer.setResolution(divisor: divisor); previousDivisor = divisor
                stepSeconds = 0 // The finer stage has a different cost; don't keep an optimistic ETA.
            }
            if iteration % 25 == 1, os_proc_available_memory() < 96 * 1024 * 1024 {
                throw GaussianTrainerError.memoryBudget
            }
            // Heat: slow down when serious, wait while critical.
            var thermal = ProcessInfo.processInfo.thermalState
            while thermal == .critical {
                try control.check()
                await report(.training(progress: Double(iteration) / Double(iterations), secondsLeft: nil, hot: true))
                try await Task.sleep(nanoseconds: 2_000_000_000)
                thermal = ProcessInfo.processInfo.thermalState
            }
            let tick = Date()
            let stats = try autoreleasepool { try trainer.trainStep(measure: iteration % 100 == 0) }
            let gpuSeconds = Date().timeIntervalSince(tick)
            if thermal == .serious || ProcessInfo.processInfo.isLowPowerModeEnabled {
                try await Task.sleep(nanoseconds: UInt64(min(0.25, max(0.015, gpuSeconds)) * 1e9))
            }
            let duration = Date().timeIntervalSince(tick)
            stepSeconds = stepSeconds == 0 ? duration : stepSeconds * 0.9 + duration * 0.1
            peakMetal = max(peakMetal, trainer.workingSetBytes)
            if let error = stats.meanAbsError { lastError = error; session.lastError = error }
            if Date().timeIntervalSince(lastCheckpoint) >= 5 || iteration == iterations {
                try checkpoint(); lastCheckpoint = Date()
            }
            if Date().timeIntervalSince(lastReport) > 0.4 || iteration == iterations {
                lastReport = Date()
                let left = stepSeconds * Double(iterations - iteration)
                await report(.training(progress: Double(iteration) / Double(iterations),
                                       secondsLeft: divisor == 1 && iteration >= 30 ? Int(left.rounded()) : nil, hot: thermal == .serious))
            }
        }
        try Task.checkCancellation()
        await report(.saving)
        let after = try TrainingViewMetrics.evaluate(trainer: trainer, dataset: dataset, indices: evaluationViews)
        guard os_proc_available_memory() >= 96 * 1024 * 1024 else { throw GaussianTrainerError.memoryBudget }
        let seconds = Int((elapsedBefore + Date().timeIntervalSince(started)).rounded())
        let parameters = trainer.parameters()
        let manager = FileManager.default
        let final = scanFolder.appendingPathComponent(folderName, isDirectory: true)
        let staging = scanFolder.appendingPathComponent(folderName + ".partial", isDirectory: true)
        try? manager.removeItem(at: staging)
        defer { try? manager.removeItem(at: staging) }
        try manager.createDirectory(at: staging, withIntermediateDirectories: true)
        let kept = try TrainingOutput.writePLY(means: parameters.means, logScales: parameters.logScales, quats: parameters.quats,
                                               colorOp: parameters.colorOp, to: staging.appendingPathComponent("scene.ply"))
        try TrainingOutput.writeCameras(dataset.frames, to: staging.appendingPathComponent("cameras.json"))
        var meta: [String: Any] = [
            "trainer": config.lineAspectLimit != nil ? "phocoscan on-device 3DGS v4 (shape constraint, subject surface)" :
                (config.refinement == nil ? "phocoscan on-device 3DGS v2" : "phocoscan on-device 3DGS v3 (subject weights, bounded gradient refinement)"),
            "trainingSessionID": sessionID.uuidString,
            "trainerVersion": config.lineAspectLimit != nil ? 4 : (config.refinement == nil ? 2 : 3), "loss": "0.8 L1 + 0.2 (1-SSIM), 5x5 Gaussian sigma 1",
            "resolutionSchedule": "half resolution first 30%, then full, same Adam state",
            "metalBudgetBytes": plan.metalBudget, "peakObservedMetalBytes": peakMetal,
            "evaluation": ["kind": split.validation.isEmpty ? "training_views" : "held_out_views",
                           "sourceFrames": evaluationViews.map { dataset.frames[$0].name },
                           "beforeMAE": before.mae, "afterMAE": after.mae,
                           "beforePSNR": before.psnr, "afterPSNR": after.psnr,
                           "trainingViews": split.train.count] as [String: Any],
            "iterations": iterations, "seconds": seconds, "gaussians": kept,
            "seedGaussians": dataset.seeds.count, "keyframes": dataset.cameras.count,
            "resolution": [dataset.width, dataset.height],
            "poses": "ARKit device poses, not refined",
            "frame": "ARKit world (metres), OpenGL camera convention",
            "createdAt": Date().ISO8601Format()
        ]
        meta["finalTrainingGaussians"] = trainer.count
        meta["densityCapacity"] = trainer.capacity
        if let subject {
            meta["subject"] = ["digest": subject.digest, "maskedFrames": subject.maskedFrames,
                "frames": dataset.frames.count, "foregroundLossMass": 0.85, "backgroundLossMass": 0.15] as [String: Any]
            let metric = try TrainingViewMetrics.evaluate(trainer: trainer, dataset: dataset, indices: evaluationViews, subjectOnly: true)
            meta["subjectEvaluation"] = ["mae": metric.mae, "psnr": metric.psnr, "views": metric.views] as [String: Any]
            if let limit = config.lineAspectLimit {
                let selection = try TrainingSubjectSurface.select(device:device,library:library,dataset:dataset,
                    means:parameters.means,logScales:parameters.logScales,quats:parameters.quats,control:control,trainer:trainer)
                // A failed subject extraction must not destroy a valid full-scene reconstruction.
                let visible = selection.indices.filter { 1 / (1 + exp(-parameters.colorOp[$0].w)) >= 0.02 }.count
                if visible >= 100 {
                    let count = try TrainingSubjectSurface.write(selection,means:parameters.means,logScales:parameters.logScales,
                        quats:parameters.quats,colorOp:parameters.colorOp,to:staging.appendingPathComponent("subject.ply"))
                    meta["subjectSurface"] = ["version":TrainingSubjectSurface.version,"gaussians":count,"trainingViews":selection.views,
                        "unsupportedCenters":selection.unsupportedCenters,"unsupportedExtents":selection.unsupportedExtents,
                        "unsupportedAppearance":selection.unsupportedAppearance,"minimumForegroundMass":0.25,
                        "narrowed":selection.narrowed,"minimumAxisScale":0.85,
                        "harmfulTails":selection.harmfulTails,
                        "lineAspectLimit":limit,"fullSceneRetained":true] as [String:Any]
                }
            }
        }
        if let lastError { meta["meanAbsErrorLastView"] = lastError }
        try JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys])
            .write(to: staging.appendingPathComponent("meta.json"), options: .atomic)
        try control.publish { try Self.publish(staging: staging, final: final) }
        try TrainingCheckpoint.remove(scanFolder)
        } catch {
            // A GPU failure may have partially updated buffers: keep the last disk checkpoint.
            // A normal pause between submissions has a complete last step and can save it.
            if trainer.canCheckpoint { try checkpoint() }
            throw error
        }
    }

    /// Keep the previous result intact if training is cancelled before publication.
    nonisolated static func publish(staging: URL, final: URL) throws {
        try Task.checkCancellation()
        let manager = FileManager.default
        if manager.fileExists(atPath: final.path) {
            _ = try manager.replaceItemAt(final, withItemAt: staging,
                                          backupItemName: "ondevice.previous." + UUID().uuidString,
                                          options: .withoutDeletingBackupItem)
        } else {
            try manager.moveItem(at: staging, to: final)
        }
    }
}
