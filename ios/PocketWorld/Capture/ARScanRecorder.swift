import ARKit
import AVFoundation
import Combine
import CryptoKit
import Foundation
import SceneKit
import SwiftUI
import UIKit
import Vision

/// A research capture path. One ARSession supplies both the encoded RGB frames and
/// their camera metadata; the older AVCaptureMovieFileOutput path remains separate.
/// Nothing here assigns a quality grade or a real-world accuracy guarantee.
final class ARScanRecorder: NSObject, ObservableObject, ARSessionDelegate {
    enum State: Equatable {
        case idle
        case requestingPermission
        case recording
        case saving
        case saved
        case failed(String)
    }

    let session = ARSession()
    @Published private(set) var state: State = .idle
    @Published private(set) var frameCount = 0
    @Published private(set) var elapsedSeconds = 0
    @Published private(set) var trackingMessage = "等待相机追踪"
    @Published private(set) var trackingNeedsAttention = true
    @Published private(set) var depthSupported = false
    @Published private(set) var savedPackageURL: URL?
    /// Live guidance derived from ARKit poses only (UI feedback, not a quality grade).
    @Published private(set) var coverage = ScanCoverage()
    /// Quality report of the last saved scan (also written to `analysis.json`).
    @Published private(set) var lastAnalysis: ScanAnalysis?
    /// Live red/green supervision of the captured surfaces (LiDAR devices only).
    @Published private(set) var liveQuality = LiveQualitySnapshot()
    @Published private(set) var nextPosition: SubjectStepGuidance?
    @Published private(set) var spaceGuidance = SpaceGuidance()
    @Published private(set) var previewCamera: simd_float4x4?
    @Published private(set) var cameraReadiness = CaptureCameraReadiness()
    @Published private(set) var framing = CaptureFraming()
    /// Maximum recording length enforced by the frame loop.
    static let maxDurationSeconds: TimeInterval = 90
    var onFinished: ((Result<URL, Error>) -> Void)?

    private enum Phase: Equatable { case idle, recording, saving, finished }
    private let captureQueue = DispatchQueue(label: "world.pocket.arkit.capture", qos: .userInitiated)
    private var phase: Phase = .idle // Accessed only on captureQueue.
    private var captureID = ""
    private var createdAt = Date()
    private var stopReason = "user"
    private var partialURL: URL?
    private var metadataHandle: FileHandle?
    private var writer: AVAssetWriter?
    private var writerInput: AVAssetWriterInput?
    private var writerAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var firstTimestamp: TimeInterval?
    private var lastFeedbackTimestamp: TimeInterval?
    private var lastPTS = CMTime.invalid
    private var writtenFrames = 0
    private var skippedFrames = 0
    private var depthFrames = 0
    private var imageWidth = 0
    private var imageHeight = 0
    private var useDepth = false
    private var backgroundObserver: NSObjectProtocol?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid // Main thread only.
    private var readinessTracker = CaptureCameraReadiness() // captureQueue only.
    private var framingTracker = CaptureFraming() // captureQueue only.
    private var captureMotion = CaptureMotion() // consumes EVERY live frame, including rejected ones.
    private var viewportSize = CGSize.zero // captureQueue only; actual portrait preview size.
    private var stepPlanner = SubjectStepPlanner() // captureQueue only.
    private var spaceTracker = SpaceGuidance() // captureQueue only.
    private var coverageTracker = ScanCoverageTracker() // captureQueue only.
    private var analyzer = ScanAnalyzer() // captureQueue only.
    private var captureMode: ScanMode = .object // captureQueue only.
    private var lastCoveragePublish: TimeInterval?
    private var lastPivotRefine: TimeInterval?
    private var previewRunning = false // captureQueue only.
    private var trackingWasReset = true // captureQueue only.
    private var pendingTarget: ScanTargetBox? // captureQueue only; set before start.
    private var activeTarget: ScanTargetBox? // captureQueue only.
    private var qualityVolume: QualityVolume? // captureQueue only.
    private var lastQualityView: TimeInterval? // captureQueue only.
    private var qualityVersion = 0 // captureQueue only.
    private var lastPreviewFeedback: TimeInterval?
    // Training package (keyframes, depth, masks, transforms.json); captureQueue only.
    private var keyframes = KeyframeSelector(policy: .forMode(.object))
    private let sharpnessMeter = SharpnessMeter()
    private var package: TrainingPackageWriter?
    private var exposureInfo: [String: Any]?
    private var videoFormatInfo: [String: Any] = [:]
    // Person mode: Vision checks on sampled frames; captureQueue only.
    private let visionQueue = DispatchQueue(label: "world.pocket.arkit.vision", qos: .userInitiated)
    private var stillness = SubjectStillnessTracker()
    private var stillnessReliable = true
    private var visionBusy = false
    private var savedFaceBusy = false
    private var lastVisionSample: TimeInterval?

    override init() {
        super.init()
        session.delegate = self
        session.delegateQueue = captureQueue
        backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil
        ) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                if self.state == .recording || self.state == .saving { self.beginBackgroundTask() }
                self.stop(reason: "background")
            }
        }
    }

    deinit {
        if let backgroundObserver { NotificationCenter.default.removeObserver(backgroundObserver) }
        session.pause()
    }

    func start(captureID requestedID: UUID = UUID(), mode: ScanMode = .object) {
        DispatchQueue.main.async { self.state = .requestingPermission }
        guard ARWorldTrackingConfiguration.isSupported else {
            reportBeforeStart(ScanError.unsupportedDevice)
            return
        }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            captureQueue.async { self.startAuthorized(id: requestedID, mode: mode) }
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                guard let self else { return }
                if granted { self.captureQueue.async { self.startAuthorized(id: requestedID, mode: mode) } }
                else { self.reportBeforeStart(ScanError.cameraDenied) }
            }
        default:
            reportBeforeStart(ScanError.cameraDenied)
        }
    }

    /// Runs a tracking-only session so the camera is live before recording starts.
    /// Nothing is written until `start` re-runs the session in recording mode.
    func startPreview() {
        guard ARWorldTrackingConfiguration.isSupported else { reportBeforeStart(ScanError.unsupportedDevice); return }
        let run: () -> Void = { [weak self] in
            guard let self else { return }
            self.captureQueue.async {
                guard self.phase == .idle || self.phase == .finished else { return }
                let configuration = ARWorldTrackingConfiguration()
                configuration.worldAlignment = .gravity
                configuration.planeDetection = [.horizontal] // support surface for the target box
                // Same format as the recording, so starting to record never restarts the camera.
                if let format = ARScanRecorder.preferredVideoFormat { configuration.videoFormat = format }
                if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
                    configuration.frameSemantics.insert(.sceneDepth) // sizes the target box
                }
                self.lastPreviewFeedback = nil
                self.readinessTracker = CaptureCameraReadiness()
                self.phase = .idle
                DispatchQueue.main.async { self.cameraReadiness = CaptureCameraReadiness(); self.state = .idle }
                self.session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
                self.previewRunning = true
            }
        }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: run()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                if granted { run() } else { self?.reportBeforeStart(ScanError.cameraDenied) }
            }
        default: reportBeforeStart(ScanError.cameraDenied)
        }
    }

    /// Pauses the preview session; an active recording is never interrupted here.
    func pausePreview() {
        captureQueue.async {
            guard self.phase != .recording, self.phase != .saving else { return }
            self.session.pause()
            self.previewRunning = false
            self.invalidateReadiness()
        }
    }

    func setViewport(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        captureQueue.async { self.viewportSize = size }
    }

    /// The confirmed target box (object mode) for the next recording, or nil.
    func setTarget(_ box: ScanTargetBox?) {
        captureQueue.async { self.pendingTarget = box }
    }

    func stop() { stop(reason: "user") }

    private func stop(reason: String) {
        captureQueue.async {
            guard self.phase == .recording else { return }
            self.phase = .saving
            self.stopReason = reason
            self.releaseCamera()
            self.session.pause()
            self.previewRunning = false
            self.publish(.saving)
            guard let writer = self.writer, let input = self.writerInput, self.writtenFrames > 0 else {
                self.fail(ScanError.emptyCapture)
                return
            }
            input.markAsFinished()
            writer.finishWriting { [weak self] in
                guard let self else { return }
                self.captureQueue.async { self.finish(writer: writer) }
            }
        }
    }

    private func startAuthorized(id: UUID, mode: ScanMode) {
        guard phase == .idle || phase == .finished else { return }
        guard previewRunning && readinessTracker.ready else {
            publish(.idle)
            if !previewRunning { startPreview() }
            return
        }
        do {
            let root = try Self.packagesDirectory()
            captureID = id.uuidString.lowercased()
            let destination = root.appendingPathComponent(captureID + ".partial", isDirectory: true)
            // A repeated ID must never replace a previous or interrupted recording.
            guard !FileManager.default.fileExists(atPath: destination.path),
                  !FileManager.default.fileExists(atPath: root.appendingPathComponent(captureID + ".scan").path) else {
                throw ScanError.duplicateID
            }
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
            try? FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: destination.path
            )
            partialURL = destination
            metadataHandle = try FileHandle(forWritingTo: destination.appendingPathComponent("frames.jsonl", isDirectory: false).creatingEmptyFile())
            createdAt = Date()
            firstTimestamp = nil
            lastFeedbackTimestamp = nil
            lastPTS = .invalid
            writtenFrames = 0
            skippedFrames = 0
            depthFrames = 0
            imageWidth = 0
            imageHeight = 0
            writer = nil
            writerInput = nil
            writerAdaptor = nil
            coverageTracker = ScanCoverageTracker(portrait: mode == .portrait)
            analyzer = ScanAnalyzer()
            captureMode = mode
            lastCoveragePublish = nil
            lastPivotRefine = nil
            keyframes = KeyframeSelector(policy: .forMode(mode))
            // The training package is an addition: if its folders cannot be made, the scan still records.
            package = try? TrainingPackageWriter(root: destination, mode: mode)
            exposureInfo = nil
            stillness = SubjectStillnessTracker()
            stillnessReliable = true
            visionBusy = false
            savedFaceBusy = false
            lastVisionSample = nil
            let configuration = ARWorldTrackingConfiguration()
            configuration.worldAlignment = .gravity
            configuration.planeDetection = [.horizontal]
            if let format = Self.preferredVideoFormat { configuration.videoFormat = format }
            let format = configuration.videoFormat
            videoFormatInfo = ["width": Int(format.imageResolution.width), "height": Int(format.imageResolution.height),
                               "fps": format.framesPerSecond,
                               "rule": "highest resolution with the default 4:3 wide-camera view"]
            useDepth = ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
            if useDepth { configuration.frameSemantics.insert(.sceneDepth) }
            phase = .recording
            stepPlanner = SubjectStepPlanner(); spaceTracker = SpaceGuidance(); framingTracker = CaptureFraming(); captureMotion = CaptureMotion()
            let supportsDepthForThisCapture = useDepth
            DispatchQueue.main.async {
                self.frameCount = 0
                self.elapsedSeconds = 0
                self.trackingMessage = "等待相机追踪"
                self.trackingNeedsAttention = true
                self.depthSupported = supportsDepthForThisCapture
                self.savedPackageURL = nil
                self.coverage = ScanCoverage()
                self.nextPosition = nil; self.framing = CaptureFraming(); self.spaceGuidance = SpaceGuidance(); self.previewCamera = nil
                self.state = .recording
            }
            // Continue the preview's world (no reset) so a target box confirmed during
            // preview stays exactly in place; otherwise start from a fresh world.
            activeTarget = previewRunning ? pendingTarget : nil
            trackingWasReset = !previewRunning
            if let activeTarget {
                coverageTracker.lockPivot(activeTarget.simdCenter, axis: activeTarget.bodyAxis,
                                          body: activeTarget.isPerson
                                              ? activeTarget.baseCenter.y...(activeTarget.baseCenter.y + activeTarget.size[1])
                                              : nil)
            }
            qualityVolume = useDepth ? QualityVolume(target: activeTarget, cropToTarget: true) : nil
            lastQualityView = nil
            DispatchQueue.main.async { self.liveQuality = LiveQualitySnapshot() }
            if previewRunning { session.run(configuration) }
            else { session.run(configuration, options: [.resetTracking, .removeExistingAnchors]) }
            previewRunning = false
        } catch {
            fail(error)
        }
    }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard phase == .recording else {
            publishPreviewTracking(frame)
            return
        }
        if let firstTimestamp, frame.timestamp - firstTimestamp > Self.maxDurationSeconds {
            stop(reason: "duration_limit")
            return
        }
        // Live alignment must not wait for the video writer/depth file IO. Saved
        // observations and training frames still update only after persistence.
        captureMotion.update(pose: frame.camera.transform, timestamp: frame.timestamp)
        updateCoverage(frame)
        do {
            if writer == nil { try makeWriter(for: frame.capturedImage) }
            guard let input = writerInput, let adaptor = writerAdaptor else { throw ScanError.writerUnavailable }
            guard input.isReadyForMoreMediaData else { skippedFrames += 1; return }
            let baseline = firstTimestamp ?? frame.timestamp
            let relativeTime = frame.timestamp - baseline
            let pts = CMTime(seconds: relativeTime, preferredTimescale: 60_000)
            guard !lastPTS.isValid || pts > lastPTS else { skippedFrames += 1; return }
            guard adaptor.append(frame.capturedImage, withPresentationTime: pts) else {
                throw writer?.error ?? ScanError.writerUnavailable
            }
            firstTimestamp = baseline
            lastPTS = pts
            let index = writtenFrames
            var depth: AuxiliaryFrame?
            var confidence: AuxiliaryFrame?
            if let sceneDepth = frame.sceneDepth, useDepth, let partialURL {
                // Auxiliary failure never turns a missing depth map into invented data.
                depth = try? writeAuxiliary(sceneDepth.depthMap, index: index, folder: "depth",
                                            extension: "f32", bytesPerPixel: 4, pixelFormat: kCVPixelFormatType_DepthFloat32,
                                            root: partialURL)
                if depth != nil, let confidenceMap = sceneDepth.confidenceMap {
                    confidence = try? writeAuxiliary(confidenceMap, index: index, folder: "confidence",
                                                     extension: "u8", bytesPerPixel: 1, pixelFormat: kCVPixelFormatType_OneComponent8,
                                                     root: partialURL)
                }
                if depth != nil { depthFrames += 1 }
            }
            let record = FrameRecord(
                index: index, arTimestampSeconds: frame.timestamp, videoPTSSeconds: relativeTime,
                rgbWidth: CVPixelBufferGetWidth(frame.capturedImage), rgbHeight: CVPixelBufferGetHeight(frame.capturedImage),
                cameraImageWidth: Int(frame.camera.imageResolution.width),
                cameraImageHeight: Int(frame.camera.imageResolution.height),
                cameraToWorldARKit: Self.matrix4(frame.camera.transform),
                intrinsicsPixels: Self.matrix3(frame.camera.intrinsics),
                trackingState: String(describing: frame.camera.trackingState),
                depth: depth, confidence: confidence
            )
            let line = try JSONEncoder().encode(record)
            guard let metadataHandle else { throw ScanError.writerUnavailable }
            try metadataHandle.write(contentsOf: line + Data([0x0a]))
            writtenFrames += 1
            // Lock exposure and white balance once frames flow, so every keyframe shares
            // one appearance (3DGS assumes it).
            if exposureInfo == nil { exposureInfo = lockCamera() }
            updateKeyframe(frame)
            if captureMode == .portrait { samplePerson(frame) }
            analyzer.add(timestamp: frame.timestamp, transform: frame.camera.transform,
                         tracking: Self.analysisTracking(frame.camera.trackingState),
                         ambientLux: frame.lightEstimate.map { Double($0.ambientIntensity) },
                         featurePoints: frame.rawFeaturePoints?.points.count,
                         hasDepth: depth != nil, targetDistance: coverageTracker.snapshot.targetDistance)
            if lastFeedbackTimestamp.map({ frame.timestamp - $0 >= 0.5 }) ?? true {
                lastFeedbackTimestamp = frame.timestamp
                let count = writtenFrames
                let elapsed = max(0, Int(relativeTime))
                let tracking = Self.trackingFeedback(for: frame.camera.trackingState)
                DispatchQueue.main.async {
                    self.frameCount = count
                    self.elapsedSeconds = elapsed
                    self.trackingMessage = tracking.message
                    self.trackingNeedsAttention = tracking.needsAttention
                }
            }
        } catch {
            fail(error)
        }
    }

    private func updateCoverage(_ frame: ARFrame) {
        updateFraming(frame)
        guard case .normal = frame.camera.trackingState else {
            stepPlanner.suspend()
            let framing = framingTracker
            DispatchQueue.main.async { self.nextPosition = nil; self.previewCamera = nil; self.framing = framing }
            return
        }
        if coverageTracker.needsPivot {
            coverageTracker.setPivot(transform: frame.camera.transform,
                                     distance: Self.centerDepth(frame) ?? 1.2)
        }
        coverageTracker.add(transform: frame.camera.transform, timestamp: frame.timestamp, recordCoverage: false)
        if lastPivotRefine.map({ frame.timestamp - $0 >= 0.5 }) ?? true {
            lastPivotRefine = frame.timestamp
            coverageTracker.refine()
        }
        guard lastCoveragePublish.map({ frame.timestamp - $0 >= 0.1 }) ?? true else { return }
        lastCoveragePublish = frame.timestamp
        let snapshot = coverageTracker.snapshot
        let next = activeTarget.flatMap { stepPlanner.update(transform: frame.camera.transform, target: $0, timestamp: frame.timestamp) }
        spaceTracker.update(transform: frame.camera.transform, timestamp: frame.timestamp)
        let space = spaceTracker, camera = frame.camera.transform, framing = framingTracker
        DispatchQueue.main.async {
            self.coverage = snapshot; self.nextPosition = next; self.spaceGuidance = space; self.previewCamera = camera; self.framing = framing
        }
    }

    private func updateFraming(_ frame: ARFrame) {
        let normal: Bool
        if case .normal = frame.camera.trackingState { normal = true } else { normal = false }
        guard let target = activeTarget else {
            framingTracker.update(points: [CGPoint(x: 0.5, y: 0.5)], normal: normal, timestamp: frame.timestamp, steady: captureMotion.steady)
            return
        }
        guard viewportSize.width > 0, viewportSize.height > 0 else {
            framingTracker.update(points: [], normal: false, timestamp: frame.timestamp); return
        }
        let display = frame.displayTransform(for: .portrait, viewportSize: viewportSize)
        var world = [target.simdCenter]
        if let axis = target.bodyAxis {
            world = (0...8).map { i in SIMD3(target.simdCenter.x, axis.lowerBound + Float(i)/8 * (axis.upperBound-axis.lowerBound), target.simdCenter.z) }
        }
        let points = world.compactMap {
            CaptureFraming.project($0, cameraToWorld: frame.camera.transform, intrinsics: frame.camera.intrinsics,
                                   resolution: frame.camera.imageResolution, display: display)
        }
        framingTracker.update(points: points, normal: normal, timestamp: frame.timestamp, steady: captureMotion.steady)
    }

    /// Adds one LiDAR view to the live red/green volume every `QualityVolume.viewInterval`.
    private func updateQuality(_ frame: ARFrame) {
        guard qualityVolume != nil, case .normal = frame.camera.trackingState,
              lastQualityView.map({ frame.timestamp - $0 >= QualityVolume.viewInterval }) ?? true,
              let sceneDepth = frame.sceneDepth,
              CVPixelBufferGetPixelFormatType(sceneDepth.depthMap) == kCVPixelFormatType_DepthFloat32 else { return }
        lastQualityView = frame.timestamp
        let map = sceneDepth.depthMap
        let width = CVPixelBufferGetWidth(map), height = CVPixelBufferGetHeight(map)
        CVPixelBufferLockBaseAddress(map, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(map, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(map) else { return }
        let rowBytes = CVPixelBufferGetBytesPerRow(map)
        var confidenceBase: UnsafeMutableRawPointer?
        var confidenceRow = 0
        let confidenceMap = sceneDepth.confidenceMap.flatMap {
            CVPixelBufferGetWidth($0) == width && CVPixelBufferGetHeight($0) == height ? $0 : nil
        }
        if let confidenceMap {
            CVPixelBufferLockBaseAddress(confidenceMap, .readOnly)
            confidenceBase = CVPixelBufferGetBaseAddress(confidenceMap)
            confidenceRow = CVPixelBufferGetBytesPerRow(confidenceMap)
        }
        defer { if let confidenceMap { CVPixelBufferUnlockBaseAddress(confidenceMap, .readOnly) } }
        let k = frame.camera.intrinsics, resolution = frame.camera.imageResolution
        let sx = Float(width) / Float(resolution.width), sy = Float(height) / Float(resolution.height)
        let points = QualityVolume.unproject(
            width: width, height: height,
            intrinsics: SIMD4(k[0][0] * sx, k[1][1] * sy, k[2][0] * sx, k[2][1] * sy),
            cameraToWorld: frame.camera.transform,
            depth: { base.advanced(by: ($0 / width) * rowBytes).assumingMemoryBound(to: Float32.self)[$0 % width] },
            confidence: confidenceBase.map { cBase in
                { cBase.advanced(by: ($0 / width) * confidenceRow).assumingMemoryBound(to: UInt8.self)[$0 % width] }
            })
        let t = frame.camera.transform
        let camera = SIMD3(t.columns.3.x, t.columns.3.y, t.columns.3.z)
        qualityVolume?.add(points: points, camera: camera) // in place: no copy of the cells
        guard let volume = qualityVolume else { return }
        qualityVersion += 1
        let snapshot = LiveQualitySnapshot(volume: volume, camera: camera, version: qualityVersion)
        DispatchQueue.main.async { self.liveQuality = snapshot }
    }

    /// Keyframe selection: pose gates on every frame, a blur check only for candidates.
    private func updateKeyframe(_ frame: ARFrame) {
        guard let package, case .normal = frame.camera.trackingState, framingTracker.acceptsKeyframe,
              captureMotion.allows(speed: keyframes.policy.maxSpeed, turn: keyframes.policy.maxTurnDegrees * .pi / 180),
              keyframes.poseGate(transform: frame.camera.transform, timestamp: frame.timestamp,
                                 captureWaypoint: stepPlanner.needsSavedView(transform: frame.camera.transform)) == nil,
              package.canAccept,
              let sharpness = sharpnessMeter.measure(frame.capturedImage),
              keyframes.sharpnessGate(sharpness: sharpness, transform: frame.camera.transform,
                                      timestamp: frame.timestamp) == .keep else { return }
        let moving = captureMode == .portrait && stillnessReliable && stillness.isMoving
        let id = captureID
        _ = package.add(frame: frame, sharpness: sharpness, subjectMoving: moving) { [weak self] in
            self?.captureQueue.async {
                guard let self, self.captureID == id, self.phase == .recording || self.phase == .saving else { return }
                guard !moving else { return }
                self.coverageTracker.recordSaved(transform: frame.camera.transform)
                if let target = self.activeTarget {
                    self.stepPlanner.recordSaved(transform: frame.camera.transform, target: target, timestamp: frame.timestamp)
                }
                self.spaceTracker.recordSaved(transform: frame.camera.transform, timestamp: frame.timestamp)
                self.updateQuality(frame)
                if self.captureMode == .portrait && !self.savedFaceBusy && !self.coverageTracker.snapshot.frontFaceSeen {
                    self.savedFaceBusy = true
                    self.visionQueue.async { [weak self] in
                        let result = PersonVision.analyze(frame.capturedImage, intrinsics: frame.camera.intrinsics,
                                                          cameraToWorld: frame.camera.transform, checkFace: true)
                        self?.captureQueue.async {
                            guard let self, self.captureID == id else { return }
                            self.savedFaceBusy = false
                            guard self.phase == .recording || self.phase == .saving else { return }
                            if result.frontalFace { self.coverageTracker.markFrontFace() }
                        }
                    }
                }
                let snapshot = self.coverageTracker.snapshot
                DispatchQueue.main.async { self.coverage = snapshot }
            }
        }
    }

    /// Person mode, about four times a second: is the person still, and has a frontal
    /// face been seen up close? Vision runs off the capture queue on one frame at a time.
    private func samplePerson(_ frame: ARFrame) {
        guard !visionBusy, lastVisionSample.map({ frame.timestamp - $0 >= 0.25 }) ?? true,
              case .normal = frame.camera.trackingState else { return }
        visionBusy = true
        lastVisionSample = frame.timestamp
        let image = frame.capturedImage
        let intrinsics = frame.camera.intrinsics, transform = frame.camera.transform
        let checkFace = false // Face completeness is checked only on saved keyframes.
        visionQueue.async { [weak self] in
            let result = PersonVision.analyze(image, intrinsics: intrinsics, cameraToWorld: transform, checkFace: checkFace)
            self?.captureQueue.async { self?.applyPerson(result) }
        }
    }

    private func applyPerson(_ result: PersonVision.Result) {
        visionBusy = false
        guard phase == .recording else { return }
        guard stillnessReliable, let target = activeTarget, target.isPerson else { return }
        let axis = SIMD2(target.center[0], target.center[2])
        func miss(_ body: [String: SubjectStillnessTracker.Ray]) -> Float {
            body.values.map { SubjectStillnessTracker.horizontalMiss(origin: $0.origin, direction: $0.direction, axis: axis) }
                .min() ?? .infinity
        }
        // The body nearest the anchored person; a passer-by further away is ignored.
        if let body = result.bodies.min(by: { miss($0) < miss($1) }), miss(body) < 0.6 {
            stillness.add(rays: body)
            if let joint = stillness.jointPoints["neck"] ?? stillness.jointPoints["root"],
               simd_length(SIMD2(joint.x, joint.z) - axis) > 0.45 {
                // The joints do not meet at the anchored person: do not judge movement.
                stillnessReliable = false
            }
        }
        coverageTracker.setSubjectMoving(stillnessReliable && stillness.isMoving)
    }

    /// Locks auto exposure and white balance on the ARKit camera (focus stays automatic;
    /// ARKit reports per-frame intrinsics). Returns what was locked, for `meta.json`.
    private func lockCamera() -> [String: Any] {
        guard let device = ARWorldTrackingConfiguration.configurableCaptureDeviceForPrimaryCamera else {
            return ["locked": false, "reason": "camera not configurable on this device"]
        }
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            var info: [String: Any] = ["focus": "automatic (per-frame intrinsics)"]
            if device.isExposureModeSupported(.locked) { device.exposureMode = .locked; info["exposure"] = "locked" }
            if device.isWhiteBalanceModeSupported(.locked) { device.whiteBalanceMode = .locked; info["white_balance"] = "locked" }
            info["locked"] = device.exposureMode == .locked && device.whiteBalanceMode == .locked
            info["exposure_duration_s"] = device.exposureDuration.seconds
            info["iso"] = device.iso
            let gains = device.deviceWhiteBalanceGains
            info["white_balance_gains"] = ["red": gains.redGain, "green": gains.greenGain, "blue": gains.blueGain]
            info["lens_position"] = device.lensPosition
            return info
        } catch {
            return ["locked": false, "reason": error.localizedDescription]
        }
    }

    /// Records whether the lock held to the end, then returns the camera to automatic.
    private func releaseCamera() {
        guard exposureInfo != nil, let device = ARWorldTrackingConfiguration.configurableCaptureDeviceForPrimaryCamera,
              (try? device.lockForConfiguration()) != nil else { return }
        exposureInfo?["still_locked_at_end"] = device.exposureMode == .locked && device.whiteBalanceMode == .locked
        if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
        if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) { device.whiteBalanceMode = .continuousAutoWhiteBalance }
        device.unlockForConfiguration()
    }

    /// The highest-resolution format that keeps the default 4:3 wide-camera view (and
    /// so the LiDAR alignment); ties keep ARKit's own preference order.
    static var preferredVideoFormat: ARConfiguration.VideoFormat? {
        let formats = ARWorldTrackingConfiguration.supportedVideoFormats
        guard let standard = formats.first, standard.imageResolution.height > 0 else { return nil }
        let aspect = standard.imageResolution.width / standard.imageResolution.height
        var best = standard
        for format in formats where format.captureDevicePosition == standard.captureDevicePosition
            && format.captureDeviceType == standard.captureDeviceType
            && format.imageResolution.height > 0
            && abs(format.imageResolution.width / format.imageResolution.height - aspect) < 0.01
            && format.imageResolution.width * format.imageResolution.height
               > best.imageResolution.width * best.imageResolution.height {
            best = format
        }
        return best
    }

    private static func analysisTracking(_ state: ARCamera.TrackingState) -> ScanAnalyzer.Tracking {
        switch state {
        case .normal: return .normal
        case .notAvailable: return .notAvailable
        case .limited(let reason): return .limited(String(describing: reason))
        @unknown default: return .notAvailable
        }
    }

    private func publishPreviewTracking(_ frame: ARFrame) {
        guard phase == .idle || phase == .finished else { return }
        let normal: Bool
        if case .normal = frame.camera.trackingState { normal = true } else { normal = false }
        readinessTracker.update(normal: normal, intrinsics: frame.camera.intrinsics,
                                resolution: frame.camera.imageResolution, transform: frame.camera.transform,
                                features: frame.rawFeaturePoints?.points.count, timestamp: frame.timestamp)
        guard lastPreviewFeedback.map({ frame.timestamp - $0 >= 0.1 }) ?? true else { return }
        lastPreviewFeedback = frame.timestamp
        let tracking = Self.trackingFeedback(for: frame.camera.trackingState), readiness = readinessTracker
        DispatchQueue.main.async {
            guard self.state == .idle || self.state == .saved else { return }
            self.trackingMessage = tracking.message; self.trackingNeedsAttention = tracking.needsAttention
            self.cameraReadiness = readiness
        }
    }

    /// Center-pixel LiDAR depth in meters, when available, to place the orbit pivot.
    private static func centerDepth(_ frame: ARFrame) -> Float? {
        guard let map = frame.sceneDepth?.depthMap,
              CVPixelBufferGetPixelFormatType(map) == kCVPixelFormatType_DepthFloat32 else { return nil }
        CVPixelBufferLockBaseAddress(map, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(map, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(map) else { return nil }
        let width = CVPixelBufferGetWidth(map), height = CVPixelBufferGetHeight(map)
        let row = base.advanced(by: (height / 2) * CVPixelBufferGetBytesPerRow(map))
        let value = row.assumingMemoryBound(to: Float32.self)[width / 2]
        guard value.isFinite, value > 0 else { return nil }
        return min(4, max(0.25, value))
    }

    func session(_ session: ARSession, didFailWithError error: Error) { fail(error) }
    func sessionWasInterrupted(_ session: ARSession) {
        invalidateReadiness()
        stop(reason: "interrupted")
    }

    private func invalidateReadiness() {
        readinessTracker = CaptureCameraReadiness()
        lastPreviewFeedback = nil
        DispatchQueue.main.async { self.cameraReadiness = CaptureCameraReadiness() }
    }

    private static func trackingFeedback(for state: ARCamera.TrackingState) -> (message: String, needsAttention: Bool) {
        switch state {
        case .normal:
            return ("相机追踪正常", false)
        case .notAvailable:
            return ("相机追踪尚不可用，请停稳片刻", true)
        case .limited(let reason):
            switch reason {
            case .excessiveMotion: return ("移动较快，请放慢并保持目标清晰", true)
            case .insufficientFeatures: return ("画面纹理较少，请对准有细节的静止区域", true)
            case .initializing: return ("正在建立相机追踪，请停稳片刻", true)
            case .relocalizing: return ("正在重新定位，请缓慢看回刚才的区域", true)
            @unknown default: return ("相机追踪受限，请放慢移动", true)
            }
        @unknown default:
            return ("相机追踪状态未知，请放慢移动", true)
        }
    }

    private func makeWriter(for image: CVPixelBuffer) throws {
        guard let partialURL else { throw ScanError.writerUnavailable }
        let width = CVPixelBufferGetWidth(image)
        let height = CVPixelBufferGetHeight(image)
        guard width > 0, height > 0 else { throw ScanError.writerUnavailable }
        let output = partialURL.appendingPathComponent("video.mov")
        let writer = try AVAssetWriter(outputURL: output, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: max(8_000_000, width * height * 5)]
        ])
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else { throw ScanError.writerUnavailable }
        writer.add(input)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        guard writer.startWriting() else { throw writer.error ?? ScanError.writerUnavailable }
        writer.startSession(atSourceTime: .zero)
        imageWidth = width
        imageHeight = height
        self.writer = writer
        writerInput = input
        writerAdaptor = adaptor
    }

    private func finish(writer: AVAssetWriter, packageDrained: Bool = false, visionDrained: Bool = false) {
        if !packageDrained, let package {
            package.drain { [weak self] in
                self?.captureQueue.async { self?.finish(writer: writer, packageDrained: true) }
            }
            return
        }
        if !visionDrained {
            visionQueue.async { [weak self] in
                self?.captureQueue.async { self?.finish(writer: writer, packageDrained: true, visionDrained: true) }
            }
            return
        }
        guard phase == .saving, let partialURL else { return }
        do {
            guard writer.status == .completed else { throw writer.error ?? ScanError.writerUnavailable }
            try metadataHandle?.synchronize()
            try metadataHandle?.close()
            metadataHandle = nil
            let videoURL = partialURL.appendingPathComponent("video.mov")
            let framesURL = partialURL.appendingPathComponent("frames.jsonl")
            let manifest = ScanManifest(
                schemaVersion: 1, captureID: captureID,
                createdAtUTC: createdAt.ISO8601Format(), completedAtUTC: Date().ISO8601Format(),
                stopReason: stopReason, videoFile: "video.mov", framesFile: "frames.jsonl",
                videoSHA256: try Self.sha256(videoURL), framesSHA256: try Self.sha256(framesURL),
                frameCount: writtenFrames, skippedFrameCount: skippedFrames, depthFrameCount: depthFrames,
                rgbWidth: imageWidth, rgbHeight: imageHeight, depthSupported: useDepth,
                initialTrackingReset: trackingWasReset,
                coordinateConvention: "ARKit camera-to-world, world alignment gravity, nominal meters; matrices stored row-major; camera axes from ARKit; intrinsics in capturedImage pixels; no global geolocation",
                videoOrientation: "capturedImage sensor orientation, no rotation or stabilization applied",
                audioPolicy: "no audio track"
            )
            try JSONEncoder().encode(manifest).write(to: partialURL.appendingPathComponent("manifest.json"), options: .atomic)
            // Advisory report; never blocks saving the scan itself.
            coverageTracker.refine()
            var analysis = analyzer.finalize(
                coverage: coverageTracker.snapshot, mode: captureMode,
                extras: .init(keyframes: package?.keyframeCount, keyframeRange: keyframes.policy.count,
                              movingKeyframes: package?.movingCount ?? 0,
                              exposureLocked: exposureInfo?["locked"] as? Bool))
            analysis.targetBox = activeTarget
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try? encoder.encode(analysis).write(to: partialURL.appendingPathComponent("analysis.json"), options: .atomic)
            // The package folder must be complete before the scan folder is renamed.
            if let package {
                self.package = nil
                package.finish(meta: packageMeta(analysis: analysis)) { [weak self] in
                    self?.captureQueue.async { self?.complete(partialURL: partialURL, analysis: analysis) }
                }
            } else {
                complete(partialURL: partialURL, analysis: analysis)
            }
        } catch { fail(error) }
    }

    private func complete(partialURL: URL, analysis: ScanAnalysis) {
        guard phase == .saving, self.partialURL == partialURL else { return }
        do {
            let final = partialURL.deletingLastPathComponent().appendingPathComponent(captureID + ".scan", isDirectory: true)
            try FileManager.default.moveItem(at: partialURL, to: final)
            self.partialURL = nil
            phase = .finished
            let finalFrameCount = writtenFrames
            DispatchQueue.main.async {
                self.frameCount = finalFrameCount
                self.lastAnalysis = analysis
                self.savedPackageURL = final
                self.state = .saved
                self.endBackgroundTask()
                self.onFinished?(.success(final))
            }
        } catch { fail(error) }
    }

    /// Device, rig, target, exposure lock and keyframe statistics for `capture/meta.json`.
    private func packageMeta(analysis: ScanAnalysis) -> [String: Any] {
        var system = utsname()
        uname(&system)
        let model = withUnsafeBytes(of: &system.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        let policy = keyframes.policy
        var meta: [String: Any] = [
            "capture_id": captureID,
            "created_at": createdAt.ISO8601Format(),
            "duration_s": analysis.durationSeconds,
            "stop_reason": stopReason,
            "app": ["name": "phocoscan", "bundle_id": Bundle.main.bundleIdentifier ?? "",
                    "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""],
            "device": ["model": model, "system": ProcessInfo.processInfo.operatingSystemVersionString,
                       "lidar": useDepth],
            "capture_rig": "world_tracking",
            "video_format": videoFormatInfo,
            "exposure_lock": exposureInfo ?? ["locked": false, "reason": "no frame recorded"],
            "keyframes": [
                "target_range": [policy.count.lowerBound, policy.count.upperBound],
                "rejected_too_fast": keyframes.rejectedFast,
                "rejected_blurry": keyframes.rejectedBlurry,
                "policy": ["min_translation_m": policy.minTranslation, "min_rotation_deg": policy.minRotationDegrees,
                           "min_interval_s": policy.minInterval, "max_speed_mps": policy.maxSpeed,
                           "max_turn_dps": policy.maxTurnDegrees,
                           "blur": "Laplacian variance of the luma ≥ a falling share of the recent median"]
            ] as [String: Any],
            "source": ["video": "../video.mov", "frames": "../frames.jsonl", "manifest": "../manifest.json",
                       "same_ar_session": true]
        ]
        let coverage = coverageTracker.snapshot
        if let target = activeTarget {
            meta["target"] = ["center": target.center, "size": target.size, "yaw_radians": target.yawRadians,
                              "source": target.source, "subject": target.subject ?? "object"] as [String: Any]
            if target.isPerson {
                meta["person"] = [
                    "axis_xz": [target.center[0], target.center[2]],
                    "floor_y": target.baseCenter.y,
                    "height_m": target.size[1],
                    "front_face_seen": coverage.frontFaceSeen,
                    "stillness_check": stillnessReliable
                        ? "body joints (Vision) triangulated across views; frames listed in moving_frames were taken while they drifted"
                        : "disabled: the joint rays did not meet at the anchored person",
                    "consent": "confirmed by the user on the capture screen before recording"
                ] as [String: Any]
            }
        }
        if captureMode == .space {
            meta["loop_closed"] = coverage.loopClosed
            meta["travel_m"] = coverage.travelMeters
        }
        return meta
    }

    private func fail(_ error: Error) {
        guard phase != .finished else { return }
        releaseCamera()
        session.pause()
        previewRunning = false
        invalidateReadiness()
        writer?.cancelWriting()
        try? metadataHandle?.close()
        metadataHandle = nil
        phase = .finished
        publish(.failed(error.localizedDescription))
        DispatchQueue.main.async {
            self.endBackgroundTask()
            self.onFinished?(.failure(error))
        }
        // Deliberately keep the .partial directory for inspection, never as a valid scan.
    }

    private func beginBackgroundTask() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "FinalizeARScan") { [weak self] in
            guard let self else { return }
            self.captureQueue.async { self.fail(ScanError.backgroundExpired) }
        }
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    private func reportBeforeStart(_ error: Error) {
        DispatchQueue.main.async {
            self.state = .failed(error.localizedDescription)
            self.onFinished?(.failure(error))
        }
    }

    private func publish(_ newState: State) { DispatchQueue.main.async { self.state = newState } }

    static func packagesDirectory() throws -> URL {
        let support = try FileManager.default.url(for: .applicationSupportDirectory,
                                                  in: .userDomainMask, appropriateFor: nil, create: true)
        var root = support.appendingPathComponent("ScanPackages", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? root.setResourceValues(values)
        return root
    }

    static func completedPackages() -> [URL] {
        guard let root = try? packagesDirectory(),
              let urls = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return [] }
        return urls.filter { $0.pathExtension == "scan" &&
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("manifest.json").path) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Diagnostics only. A .partial directory may contain an unfinalized movie and
    /// must never be treated as an uploadable, completed capture package.
    static func interruptedPackages() -> [URL] {
        guard let root = try? packagesDirectory(),
              let urls = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return [] }
        return urls.filter { $0.pathExtension == "partial" }
    }

    private static func sha256(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func matrix4(_ matrix: simd_float4x4) -> [[Float]] {
        let columns = [matrix.columns.0, matrix.columns.1, matrix.columns.2, matrix.columns.3]
        return (0..<4).map { row in (0..<4).map { column in columns[column][row] } }
    }

    private static func matrix3(_ matrix: simd_float3x3) -> [[Float]] {
        let columns = [matrix.columns.0, matrix.columns.1, matrix.columns.2]
        return (0..<3).map { row in (0..<3).map { column in columns[column][row] } }
    }

    private func writeAuxiliary(_ buffer: CVPixelBuffer, index: Int, folder: String,
                                extension ext: String, bytesPerPixel: Int, pixelFormat: OSType,
                                root: URL) throws -> AuxiliaryFrame {
        guard CVPixelBufferGetPixelFormatType(buffer) == pixelFormat else { throw ScanError.unexpectedDepthFormat }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let rowBytes = width * bytesPerPixel
        guard CVPixelBufferGetBytesPerRow(buffer) >= rowBytes else { throw ScanError.unexpectedDepthFormat }
        let directory = root.appendingPathComponent(folder, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { throw ScanError.unexpectedDepthFormat }
        var bytes = Data(capacity: rowBytes * height)
        for row in 0..<height {
            let source = base.advanced(by: row * CVPixelBufferGetBytesPerRow(buffer)).assumingMemoryBound(to: UInt8.self)
            bytes.append(source, count: rowBytes)
        }
        let file = String(format: "frame-%06d.%@", index, ext)
        let url = directory.appendingPathComponent(file)
        try bytes.write(to: url, options: .atomic)
        return AuxiliaryFrame(file: folder + "/" + file, width: width, height: height,
                              pixelFormat: ext == "f32" ? "float32_le_meters" : "uint8_arkit_confidence",
                              sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
    }

    private enum ScanError: LocalizedError {
        case unsupportedDevice, cameraDenied, duplicateID, emptyCapture, writerUnavailable, unexpectedDepthFormat, backgroundExpired
        var errorDescription: String? {
            switch self {
            case .unsupportedDevice: return "这台设备不支持 ARKit 世界跟踪。"
            case .cameraDenied: return "请在系统设置中允许相机权限。"
            case .duplicateID: return "该扫描编号已有本地数据，已停止以避免覆盖。"
            case .emptyCapture: return "尚未录到可保存的画面。"
            case .writerUnavailable: return "视频编码器未能保存扫描；临时目录仍保留。"
            case .unexpectedDepthFormat: return "深度像素格式与预期不同。"
            case .backgroundExpired: return "后台保存时间已到，扫描保留在未完成目录供检查。"
            }
        }
    }
}

private struct AuxiliaryFrame: Encodable {
    let file: String
    let width: Int
    let height: Int
    let pixelFormat: String
    let sha256: String
}

private struct FrameRecord: Encodable {
    let index: Int
    let arTimestampSeconds: Double
    let videoPTSSeconds: Double
    let rgbWidth: Int
    let rgbHeight: Int
    let cameraImageWidth: Int
    let cameraImageHeight: Int
    let cameraToWorldARKit: [[Float]]
    let intrinsicsPixels: [[Float]]
    let trackingState: String
    let depth: AuxiliaryFrame?
    let confidence: AuxiliaryFrame?
}

private struct ScanManifest: Encodable {
    let schemaVersion: Int
    let captureID: String
    let createdAtUTC: String
    let completedAtUTC: String
    let stopReason: String
    let videoFile: String
    let framesFile: String
    let videoSHA256: String
    let framesSHA256: String
    let frameCount: Int
    let skippedFrameCount: Int
    let depthFrameCount: Int
    let rgbWidth: Int
    let rgbHeight: Int
    let depthSupported: Bool
    let initialTrackingReset: Bool
    let coordinateConvention: String
    let videoOrientation: String
    let audioPolicy: String
}

private extension URL {
    func creatingEmptyFile() throws -> URL {
        guard FileManager.default.createFile(atPath: path, contents: Data()) else { throw CocoaError(.fileWriteUnknown) }
        return self
    }
}

/// Remembers the scene type picked on the capture screen so the upload step can
/// preselect it. Only a default; the first submitted value stays authoritative.
enum CaptureEnvironmentMemory {
    private static func key(_ captureID: String) -> String { "PocketWorld.captureEnvironment." + captureID }
    static func save(_ environment: String, captureID: String) {
        UserDefaults.standard.set(environment, forKey: key(captureID))
    }
    static func load(captureID: String) -> String? { UserDefaults.standard.string(forKey: key(captureID)) }
    static func clear(captureID: String) { UserDefaults.standard.removeObject(forKey: key(captureID)) }
}

enum ScanMode: String, CaseIterable, Identifiable {
    case object, portrait, space
    var id: String { rawValue }
    var title: String {
        switch self {
        case .object: return "物体"
        case .portrait: return "人像"
        case .space: return "空间"
        }
    }
    var symbol: String {
        switch self {
        case .object: return "cube"
        case .portrait: return "person.fill"
        case .space: return "square.split.bottomrightquarter"
        }
    }
    /// Object and portrait scans use a target; space scans walk freely.
    var usesAnchor: Bool { self != .space }
    /// Reference steps for optional help; not shown over the camera.
    var steps: [String] {
        switch self {
        case .object: return ["物体放稳，四周留出活动空间",
                              "对准物体开始，按下一步提示换机位",
                              "到位停稳，再补拍顶部和低处"]
        case .portrait: return ["先征得对方同意，请对方站定、眼睛看一个固定点",
                                "离人 1–2 米，对准全身，按下一步提示移动",
                                "补拍不同高度与正脸，尽量 1 分钟内拍完"]
        case .space: return ["从有纹理的地方开始，别对着白墙或镜子",
                             "手机朝外慢慢走动，横着走，别原地转身",
                             "最后走回起点，对准开始的画面再结束"]
        }
    }
    /// Person scans are timed: people cannot hold still for long.
    var timeBudgetSeconds: Int? { self == .portrait ? 60 : nil }
    /// Comfortable phone–target distance in meters (median over the scan).
    var distanceRange: ClosedRange<Double> { self == .portrait ? 0.6...2.5 : 0.2...2.5 }
}

/// Full-screen capture with one anchored subject and the next recommended position.
/// Recording, metadata and saving stay in
/// `ARScanRecorder`.
struct ARScanCaptureView: View {
    let onSaved: (URL) -> Void
    let onCancel: () -> Void
    @StateObject private var recorder: ARScanRecorder
    @State private var mode: ScanMode = .object
    @State private var showTips = false
    @StateObject private var anchor: ScanAnchorController
    @State private var anchorMiss = false
    /// Portrait: the user confirmed the person agreed (asked once per capture screen).
    @State private var portraitConsent = false
    @State private var askConsent = false
    @State private var confirmEndWithoutFace = false
    @State private var previousIdleTimerDisabled: Bool?

    @MainActor init(onSaved: @escaping (URL) -> Void, onCancel: @escaping () -> Void, initialMode: ScanMode = .object,
         recorder: ARScanRecorder? = nil, anchor: ScanAnchorController? = nil) {
        self.onSaved = onSaved; self.onCancel = onCancel
        _mode = State(initialValue: initialMode)
        _recorder = StateObject(wrappedValue: recorder ?? ARScanRecorder())
        _anchor = StateObject(wrappedValue: anchor ?? ScanAnchorController())
    }

    private var canAnchor: Bool { mode.usesAnchor && !isLocked && failureMessage == nil && recorder.cameraReadiness.ready }

    private var isRecording: Bool { recorder.state == .recording }
    private var isLocked: Bool {
        recorder.state == .recording || recorder.state == .saving || recorder.state == .requestingPermission
    }
    private var failureMessage: String? {
        if case let .failed(message) = recorder.state { return message }
        return nil
    }

    /// Camera first: optional help at the top, contextual guidance above the shutter.
    /// No pre-recording steps card; recovery arrows stay at the screen edges.
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            ARScanPreview(session: recorder.session, anchor: anchor, recorder: recorder)
                .ignoresSafeArea()
                .onTapGesture { location in anchorTapped(at: location) }
                .blur(radius: isRecording && recorder.framing.needsRecovery ? 4 : 0)
            Color.black.opacity((!isRecording && !recorder.cameraReadiness.ready) || (isRecording && recorder.framing.needsRecovery) ? 0.20 : 0)
                .ignoresSafeArea().allowsHitTesting(false)
            LinearGradient(colors: [.black.opacity(0.45), .clear, .clear, .black.opacity(0.55)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea().allowsHitTesting(false)
            if failureMessage == nil {
                CaptureCameraOverlay(recording: isRecording, ready: recorder.cameraReadiness.ready,
                                     framing: recorder.framing, usesAnchor: mode.usesAnchor,
                                     showAim: mode == .space || anchor.phase == .aiming)
                    .ignoresSafeArea()
            }
            VStack(spacing: 0) {
                topBar
                Spacer(minLength: 12)
                if let failureMessage { failureCard(failureMessage).padding(.bottom, 14) }
                bottomControls
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 8)
            if recorder.state == .saving { savingOverlay }
        }
        .foregroundStyle(.white)
        .onChange(of: recorder.nextPosition) { _, next in
            anchor.showNextPosition(next, recording: isRecording, suppressed: recorder.framing.needsRecovery)
        }
        .onChange(of: isRecording) { _, recording in
            anchor.showNextPosition(recorder.nextPosition, recording: recording, suppressed: recorder.framing.needsRecovery)
        }
        .onChange(of: recorder.framing.needsRecovery) { _, recovering in
            anchor.showNextPosition(recorder.nextPosition, recording: isRecording, suppressed: recovering)
        }
        .onChange(of: recorder.cameraReadiness.ready) { wasReady, ready in
            if !isRecording && wasReady && !ready { anchor.clear() }
            if ready && !isRecording { UISelectionFeedbackGenerator().selectionChanged() }
        }
        .onChange(of: recorder.coverage.frontFaceSeen) { _, seen in
            if seen && isRecording && mode == .portrait { UINotificationFeedbackGenerator().notificationOccurred(.success) }
        }
        .onChange(of: recorder.coverage.loopClosed) { _, closed in
            if closed && isRecording && mode == .space { UINotificationFeedbackGenerator().notificationOccurred(.success) }
        }
        .statusBarHidden(isRecording)
        .sheet(isPresented: $showTips) { ScanTipsSheet(mode: mode) }
        .alert("对方同意拍摄了吗？", isPresented: $askConsent) {
            Button("取消", role: .cancel) {}
            Button("已同意，开始") {
                portraitConsent = true
                shutterTapped()
            }
        } message: {
            Text("人脸和身体属于敏感个人信息。原片只保存在这台手机上，上传前会再次询问你。")
        }
        .alert("还没拍到正脸", isPresented: $confirmEndWithoutFace) {
            Button("继续拍", role: .cancel) {}
            Button("仍然结束", role: .destructive) { recorder.stop() }
        } message: {
            Text("走到人的正面，在头部高度拍几秒，3DGS 里的脸才会清楚。")
        }
        .onAppear {
            if previousIdleTimerDisabled == nil { previousIdleTimerDisabled = UIApplication.shared.isIdleTimerDisabled }
            UIApplication.shared.isIdleTimerDisabled = true
            recorder.onFinished = { result in
                guard case let .success(url) = result else { return }
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                onSaved(url)
            }
            anchor.portrait = mode == .portrait
            recorder.startPreview()
        }
        .onDisappear {
            recorder.pausePreview()
            if let previousIdleTimerDisabled { UIApplication.shared.isIdleTimerDisabled = previousIdleTimerDisabled }
            previousIdleTimerDisabled = nil
        }
        .onChange(of: mode) { _, newMode in
            // An object anchor is not a person anchor (and vice versa): start over.
            anchor.portrait = newMode == .portrait
            anchor.clear(); anchorMiss = false
        }
        .interactiveDismissDisabled(isLocked)
    }

    /// A tap on the camera view anchors the object or person under the finger (before
    /// recording); another tap elsewhere moves the anchor.
    private func anchorTapped(at location: CGPoint) {
        guard canAnchor else { return }
        anchored(anchor.place(at: location))
    }

    @discardableResult
    private func anchored(_ found: Bool) -> Bool {
        anchorMiss = !found
        UINotificationFeedbackGenerator().notificationOccurred(found ? .success : .warning)
        return found
    }

    /// One press records. In object and portrait mode an unanchored press first anchors
    /// what the reticle points at; if nothing is found there, nothing starts.
    private func shutterTapped() {
        switch recorder.state {
        case .recording:
            // A person scan without a clear frontal face is allowed to end, but only on purpose.
            if mode == .portrait && !recorder.coverage.frontFaceSeen {
                UINotificationFeedbackGenerator().notificationOccurred(.warning)
                confirmEndWithoutFace = true
                return
            }
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            recorder.stop()
        case .idle, .failed, .saved:
            guard recorder.cameraReadiness.ready else { return }
            if mode == .portrait && !portraitConsent { askConsent = true; return }
            if mode.usesAnchor && anchor.phase != .anchored && !anchored(anchor.placeAtCenter()) { return }
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            recorder.setTarget(mode.usesAnchor && anchor.phase == .anchored ? anchor.target : nil)
            recorder.start(mode: mode)
        case .requestingPermission, .saving:
            break
        }
    }

    // MARK: Top

    private var topBar: some View {
        HStack {
            if isRecording {
                GlassIconButton(symbol: "xmark", label: "结束并保存", size: 36) { shutterTapped() }
            } else if !isLocked {
                GlassIconButton(symbol: "xmark", label: "关闭", size: 36) { onCancel() }
            }
            Spacer()
            if !isLocked {
                GlassIconButton(symbol: "questionmark", label: "拍摄技巧", size: 36) { showTips = true }
            }
        }
        .frame(height: 36)
        .overlay { if isRecording { recordingStatus } }
        .padding(.top, 6)
        .animation(.easeInOut(duration: 0.2), value: isLocked)
    }

    /// Time only: do not turn angular bins into a requirement to walk a complete circle.
    private var recordingStatus: some View {
        let remaining = mode.timeBudgetSeconds.map { $0 - recorder.elapsedSeconds }
        return HStack(spacing: 10) {
            HStack(spacing: 6) {
                Circle().fill(Theme.record).frame(width: 7, height: 7)
                if let remaining {
                    Text(remaining >= 0 ? Self.clock(remaining) : "+" + Self.clock(-remaining))
                        .foregroundStyle(remaining <= 15 ? Theme.warning : .white)
                } else {
                    Text(Self.clock(recorder.elapsedSeconds))
                }
            }

        }
        .font(.subheadline.weight(.semibold).monospacedDigit())
        .padding(.horizontal, 12).frame(height: 30)
        .background(.black.opacity(0.4), in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(remaining.map { $0 >= 0 ? "还剩 \($0) 秒" : "已超时 \(-$0) 秒" }
                            ?? "已录 \(recorder.elapsedSeconds) 秒")
    }

    @ViewBuilder private var hintLine: some View {
        if let hint = currentHint {
            CaptureGuideBadge(text: hint.text, symbol: hint.symbol, warning: hint.warning)
                .allowsHitTesting(false)
                .onChange(of: hint.warning && isRecording) { _, warn in
                    if warn { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
                }
        }
    }

    /// One contextual action at a time. Warnings take priority over walking arrows.
    /// Before recording only an actionable state/error is shown, not a tutorial.
    private var currentHint: (text: String, symbol: String, warning: Bool)? {
        func hint(_ text: String, _ symbol: String, _ warning: Bool = false) -> (text: String, symbol: String, warning: Bool) {
            (text, symbol, warning)
        }
        if recorder.state == .requestingPermission { return hint("打开相机", "camera") }
        if failureMessage != nil { return nil } // The recovery card already explains the failure.
        let portrait = mode == .portrait
        guard isRecording else {
            if !recorder.cameraReadiness.ready { return hint(recorder.cameraReadiness.hint, "iphone.gen3.radiowaves.left.and.right") }
            if anchorMiss { return hint(portrait ? "靠近并对准人" : "靠近并对准物体", "viewfinder", true) }
            return hint(mode == .space ? "对准墙角，按下开始" : "将中心点对准主体", "scope")
        }
        if recorder.framing.reacquiring { return hint("停稳，恢复采集", "viewfinder") }
        if case .tracking = recorder.framing.state { return hint("慢慢看回刚才的画面", "viewfinder", true) }
        if mode.usesAnchor, recorder.framing.needsRecovery {
            switch recorder.framing.correction {
            case .left: return hint("向左找回主体", "arrow.left", true)
            case .right: return hint("向右找回主体", "arrow.right", true)
            case .up: return hint("抬高镜头，找回主体", "arrow.up", true)
            case .down: return hint("放低镜头，找回主体", "arrow.down", true)
            case nil: return hint("将镜头转回主体", "viewfinder", true)
            }
        }
        let c = recorder.coverage
        if c.speed > Self.fastSpeed || c.turnRate > Self.fastTurn { return hint("慢一点", "hand.raised.fill", true) }
        if portrait && c.subjectMoving { return hint("请保持不动", "person.fill", true) }
        if mode.usesAnchor, let aim = recorder.framing.correction {
            switch aim {
            case .left: return hint("镜头向左", "arrow.left", true)
            case .right: return hint("镜头向右", "arrow.right", true)
            case .up: return hint("镜头抬高", "arrow.up", true)
            case .down: return hint("镜头放低", "arrow.down", true)
            }
        }
        if portrait, let d = c.horizontalDistance {
            if d < (c.currentHeightBand == 4 ? 0.5 : 0.8) { return hint("后退一点", "arrow.down.right.and.arrow.up.left", true) }
            if d > 2.5 { return hint("靠近到 1–2 米", "arrow.up.left.and.arrow.down.right", true) }
        }
        if mode == .object, let d = c.targetDistance, d > 2.5 { return hint("靠近一点", "arrow.up.left.and.arrow.down.right", true) }
        if mode == .space && c.travelMeters < 0.4 && c.lookSpanDegrees >= 90 { return hint("横着走，别原地转", "arrow.left.and.right", true) }
        if let budget = mode.timeBudgetSeconds, c.completeness(for: mode) < 0.85 {
            let left = budget - recorder.elapsedSeconds
            if left < 0 { return hint("尽快结束拍摄", "timer", true) }
            if left <= 15 { return hint("还剩 \(left) 秒", "timer", true) }
        }
        if mode == .space {
            let action = recorder.spaceGuidance.action(coverage: c, elapsed: recorder.elapsedSeconds)
            return hint(action.text, action.symbol, action.warning)
        }
        if portrait && !c.frontFaceSeen && recorder.elapsedSeconds >= 35 {
            return hint("到正面，拍清人脸", "face.smiling")
        }
        guard let next = recorder.nextPosition else { return hint("对准主体", "viewfinder") }
        switch next.motion {
        case .left: return hint("下一步向左", "arrow.left")
        case .right: return hint("下一步向右", "arrow.right")
        case .up: return hint("下一步抬高", "arrow.up")
        case .down: return hint("下一步放低", "arrow.down")
        case .forward: return hint("向前一小步", "arrow.up.left.and.arrow.down.right")
        case .backward: return hint("向后一小步", "arrow.down.right.and.arrow.up.left")
        case .hold: return hint("停稳拍摄", "camera")
        }
    }

    /// Live warning thresholds, a little above the analysis ones so the hint does not nag.
    static let fastSpeed: Float = 0.6   // m/s
    static let fastTurn: Float = 75     // °/s

    // MARK: Bottom

    private var bottomControls: some View {
        VStack(spacing: 18) {
            hintLine
            if !isLocked { modePicker.transition(.opacity) }
            if isRecording && (recorder.depthSupported || mode == .space) {
                ZStack {
                    VStack(spacing: 4) {
                        if recorder.depthSupported {
                            LiveQualityPanel(snapshot: recorder.liveQuality, target: anchor.target,
                                             coverage: recorder.coverage, nextPosition: recorder.nextPosition,
                                             cameraTransform: recorder.previewCamera, followsCamera: mode == .space)
                        }
                        if mode == .space {
                            Text(String(format: "%.1f m", recorder.coverage.travelMeters))
                                .font(.caption.monospacedDigit()).foregroundStyle(.white.opacity(0.8))
                                .accessibilityLabel(String(format: "累计移动 %.1f 米", recorder.coverage.travelMeters))
                        }
                    }
                    HStack {
                        Label(mode.title, systemImage: mode.symbol)
                            .font(.caption2.weight(.medium)).padding(.horizontal,10).padding(.vertical,7)
                            .background(.ultraThinMaterial, in: Capsule())
                            .accessibilityLabel("当前模式：\(mode.title)")
                        Spacer(); shutter
                    }
                }
                .frame(maxWidth: .infinity)
            } else { shutter }

        }
        .padding(.bottom, 10)
        .animation(.easeInOut(duration: 0.2), value: isLocked)
    }

    private var shutter: some View {
        ShutterButton(state: recorder.state, compact: isRecording, ready: recorder.cameraReadiness.ready,
                      progress: Double(recorder.elapsedSeconds) / ARScanRecorder.maxDurationSeconds) { shutterTapped() }
    }

    /// A compact horizontal mode capsule; no instructional text in the selector.
    private var modePicker: some View {
        HStack(spacing: 4) {
            ForEach(ScanMode.allCases) { item in
                let selected = mode == item
                Button {
                    guard !selected else { return }
                    mode = item
                    UISelectionFeedbackGenerator().selectionChanged()
                } label: {
                    Text(item.title)
                        .font(.subheadline.weight(selected ? .semibold : .regular))
                        .foregroundStyle(.white.opacity(selected ? 1 : 0.55))
                        .padding(.horizontal, 20).frame(height: 40)
                        .background(selected ? Theme.accent.opacity(0.22) : .clear, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(4).background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().stroke(.white.opacity(0.08)))
        .animation(.easeInOut(duration: 0.15), value: mode)
    }

    private func failureCard(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("扫描未保存", systemImage: "exclamationmark.triangle.fill")
                .font(.headline).foregroundStyle(Theme.warning)
            Text(message).font(.subheadline).foregroundStyle(.white.opacity(0.85))
            if message.contains("相机权限") {
                GhostButton(title: "打开系统设置", symbol: "gearshape") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
            } else if ARWorldTrackingConfiguration.isSupported {
                GhostButton(title: "重新定位", symbol: "viewfinder") {
                    anchor.clear(); anchorMiss = false
                    recorder.startPreview()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var savingOverlay: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
            VStack(spacing: 12) {
                ProgressView().controlSize(.large).tint(.white)
                Text("正在保存…").font(.subheadline.weight(.semibold))
            }
        }
    }

    private static func clock(_ seconds: Int) -> String {
        let value = max(0, seconds)
        return String(format: "%02d:%02d", value / 60, value % 60)
    }
}

/// One compact pictogram and a short action at the bottom.
struct CaptureGuideBadge: View {
    let text: String
    let symbol: String
    var warning = false
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 22, weight: .medium))
                .frame(width: 26).accessibilityHidden(true)
            Text(text).font(.subheadline.weight(.medium))
                .fixedSize(horizontal: false, vertical: true).lineLimit(2)
        }
        .foregroundStyle(warning ? Theme.warning : .white)
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(.white.opacity(0.06)))
        .accessibilityElement(children: .ignore).accessibilityLabel(text)
    }
}

/// Record button with a ring that fills toward the 90-second limit.
private struct ShutterButton: View {
    let state: ARScanRecorder.State
    var compact = false
    var ready = true
    private var diameter: CGFloat { compact ? 72 : 82 }
    let progress: Double
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().stroke(.white.opacity(0.9), lineWidth: 4).frame(width: diameter, height: diameter)
                if state == .recording {
                    Circle().trim(from: 0, to: min(1, max(0, progress)))
                        .stroke(Theme.record, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .frame(width: diameter, height: diameter)
                        .animation(.linear(duration: 0.5), value: progress)
                }
                switch state {
                case .recording:
                    RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.record).frame(width: 32, height: 32)
                case .requestingPermission, .saving:
                    ProgressView().tint(.white)
                default:
                    Circle().fill(ready ? Theme.record : .white.opacity(0.25)).frame(width: 66, height: 66)
                }
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.75), value: state == .recording)
        }
        .buttonStyle(.plain)
        .disabled(state == .requestingPermission || state == .saving || (state != .recording && !ready))
        .accessibilityLabel(state == .recording ? "结束并保存" : "开始扫描")
    }
}

/// Corner-bracket framing guide shown before recording.
private struct ViewfinderFrame: View {
    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let arm: CGFloat = 34
            Path { path in
                for (x, y, dx, dy) in [(0.0, 0.0, 1.0, 1.0), (size.width, 0, -1, 1),
                                       (0, size.height, 1, -1), (size.width, size.height, -1, -1)] {
                    path.move(to: CGPoint(x: x, y: y + dy * arm))
                    path.addLine(to: CGPoint(x: x, y: y))
                    path.addLine(to: CGPoint(x: x + dx * arm, y: y))
                }
            }
            .stroke(.white.opacity(0.9), style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
            Circle().fill(.white.opacity(0.9)).frame(width: 6, height: 6)
                .position(x: size.width / 2, y: size.height / 2)
        }
        .shadow(color: .black.opacity(0.4), radius: 4)
    }
}

/// Tips for the mode on screen, then what applies to every scan.
private struct ScanTipsSheet: View {
    let mode: ScanMode
    @Environment(\.dismiss) private var dismiss

    private var modeTips: [String] {
        switch mode {
        case .object: return [
            "把物体放稳，留出活动空间；对准主体开始，或先点一下选中。",
            "底部箭头每次只推荐一个附近机位；到位后停稳，保存清晰画面后才推荐下一步。也可以选择自己的路线，随时结束。",
            "下方红绿预览表示实际保存的观察数据。红色需要更多不同角度，绿色表示观察较充分，不保证重建质量。",
            "机位建议没有检测障碍物，按现场可通行的位置移动。顶部、侧面和遮挡处需要不同高度补拍。"]
        case .portrait: return [
            "先征得对方同意。请对方站定，手臂稍微离开身体，整个过程保持不动。",
            "离人 1–2 米，先对准全身。底部每次提示一个下一步机位，到位停稳再继续，没有必须走完的环绕圈。",
            "按抬高或放低的提示补拍不同高度；到正面拍清人脸和头发。红绿预览显示实际保存的数据。",
            "尽量在一分钟内完成。机位建议没有检测障碍物，按现场可通行的位置移动。"]
        case .space: return [
            "从房间里有纹理的地方开始，别对着白墙、玻璃或镜子。",
            "手机朝外，对着墙和家具慢慢走动，像螃蟹一样横着走；相邻画面保持大半重叠。",
            "不要原地转身拍全景：转身时每个位置只有一个视角，重建效果会很差。",
            "最后走回起点、对准开始的画面再结束，首尾能接上，空间不容易歪。",
            "大空间分段扫：每段约 1 分钟，每段都回到这段的起点再结束。",
            "底部预览里红色是拍到次数太少或角度太单一的地方，补拍到变绿。"]
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("\(mode.title)模式").font(.headline)
                        ForEach(Array(modeTips.enumerated()), id: \.offset) { index, tip in
                            HStack(alignment: .top, spacing: 10) {
                                Text("\(index + 1)").font(.caption.weight(.bold).monospacedDigit())
                                    .foregroundStyle(Theme.accent).frame(width: 18)
                                Text(tip).font(.subheadline).foregroundStyle(Theme.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("每次扫描").font(.headline)
                        Text("开始前缓慢移动手机，等视角定位稳定，再用中心点对准主体。偏离时暂不采集训练画面，按箭头找回主体、停稳后自动恢复；原始录像继续保存。保持光线充足、目标静止，避开反光、透明和无纹理的表面。中途别从暗处走到强光下，提示“慢一点”时放慢。")
                            .font(.subheadline).foregroundStyle(Theme.secondary)
                        Text("原片先保存在本机；上传生成 3DGS 前会再次征得你的同意。")
                            .font(.subheadline).foregroundStyle(Theme.secondary)
                    }
                }
                .padding(20)
            }
            .background(Theme.background)
            .navigationTitle("拍摄技巧").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("好的") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }
}

struct ARScanPreview: UIViewRepresentable {
    let session: ARSession
    let anchor: ScanAnchorController
    let recorder: ARScanRecorder
    func makeUIView(context: Context) -> ARSCNView {
        let view = CaptureARView(frame: .zero)
        view.onLayout = { [weak recorder] size in recorder?.setViewport(size) }
        view.session = session
        view.automaticallyUpdatesLighting = false
        anchor.attach(view)
        return view
    }
    func updateUIView(_ view: ARSCNView, context: Context) {}
}

private final class CaptureARView: ARSCNView {
    var onLayout: ((CGSize) -> Void)?
    private var lastSize = CGSize.zero
    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.size != lastSize { lastSize = bounds.size; onLayout?(bounds.size) }
    }
}

/// Small crosshair at the screen center while choosing the object to anchor.
private struct AimReticle: View {
    var body: some View {
        ZStack {
            Circle().stroke(.white.opacity(0.9), lineWidth: 2)
            Circle().fill(.white).frame(width: 6, height: 6)
            ForEach(0..<4) { index in
                Capsule().fill(.white.opacity(0.9)).frame(width: 2, height: 10)
                    .offset(y: -34)
                    .rotationEffect(.degrees(Double(index) * 90))
            }
        }
        .shadow(color: .black.opacity(0.45), radius: 4)
        .accessibilityHidden(true)
    }
}

/// UI-only scan guidance computed from ARKit camera poses. It tells the user which
/// angles they have walked around, never claims reconstruction quality.
struct ScanCoverage: Equatable {
    static let binCount = 36          // 10° bins around the target
    static let binsPerSector = 3      // 30° sectors drive the "this part is done" haptic
    static var sectorCount: Int { binCount / binsPerSector }
    /// Space mode: meters to walk sideways before the oblique view is suggested.
    static let spaceTravelGoal: Float = 1.5

    /// Angles around the target from which it was in frame (any height).
    var orbitBins = [Bool](repeating: false, count: binCount)
    /// Per angle, which heights it was seen from: 1 = low, 2 = mid, 4 = high. Object:
    /// elevation above the target <20°, 20–50°, >50°. Portrait (relative to the body
    /// center): < -10° (knee height), -10…15° (waist), >15° (chest and above).
    var heightBands = [UInt8](repeating: 0, count: binCount)
    /// Horizontal directions the camera has looked toward (space mode).
    var lookBins = [Bool](repeating: false, count: binCount)
    /// Current orbit bin (where the phone is around the target), if known.
    var currentBin: Int?
    /// Total path length walked, in meters.
    var travelMeters: Float = 0
    /// Current camera–target distance, in meters.
    var targetDistance: Float?
    /// True once the target center comes from converging view rays, not the first guess.
    var pivotIsRefined = false
    /// Smoothed walking speed (m/s) and turning rate (°/s); both 0 without timestamps.
    var speed: Float = 0
    var turnRate: Float = 0
    /// Anchored modes: which way to point the phone when the target has been out of
    /// frame for a moment; nil while it is in frame.
    var aim: AimCorrection?
    /// Anchored modes: horizontal distance from the phone to the target's vertical axis.
    var horizontalDistance: Float?
    /// Space mode: sideways travel along the first view's right direction (+ = right).
    var lateralMeters: Float = 0
    /// Height band of the latest pose (1 low, 2 mid / chest, 4 high / head); 0 unknown.
    var currentHeightBand: UInt8 = 0
    /// Portrait: a frontal face was seen up close (Vision).
    var frontFaceSeen = false
    /// Portrait: the person's body joints drifted (they moved).
    var subjectMoving = false
    /// Space: horizontal distance back to where recording started; which side the start
    /// lies on (+ = to the right of the current heading); and whether the walk came back
    /// there facing the starting direction (a loop the reconstruction can close).
    var distanceFromStart: Float = 0
    var startSide: Float = 0
    var loopClosed = false
    var savedTravelMeters: Float? = nil

    var orbitFraction: Double { Double(orbitBins.filter { $0 }.count) / Double(Self.binCount) }
    /// Angles seen from at least two different heights.
    var multiHeightFraction: Double {
        Double(heightBands.filter { $0.nonzeroBitCount >= 2 }.count) / Double(Self.binCount)
    }
    var lookSpanDegrees: Int { lookBins.filter { $0 }.count * (360 / Self.binCount) }
    /// Share of the angles seen from a given height band.
    func bandFraction(_ bit: UInt8) -> Double {
        Double(heightBands.filter { $0 & bit != 0 }.count) / Double(Self.binCount)
    }
    /// Portrait: the head-height round needs this share of the angles.
    static let headRoundGoal = 0.6
    var hasStarted: Bool { currentBin != nil }

    func isSectorComplete(_ sector: Int) -> Bool {
        (0..<Self.binsPerSector).allSatisfy { orbitBins[sector * Self.binsPerSector + $0] }
    }
    var completedSectorCount: Int { (0..<Self.sectorCount).filter(isSectorComplete).count }

    /// Uncovered orbit ranges in degrees, as [start, end) pairs (may wrap past 360).
    var gapsDegrees: [[Int]] {
        guard orbitBins.contains(true) else { return orbitBins.isEmpty ? [] : [[0, 360]] }
        let step = 360 / Self.binCount
        guard let anchor = orbitBins.firstIndex(of: true) else { return [] }
        var gaps: [[Int]] = []
        var runStart: Int?
        for offset in 1...Self.binCount {
            let index = (anchor + offset) % Self.binCount
            if !orbitBins[index] { if runStart == nil { runStart = anchor + offset } }
            else if let start = runStart {
                gaps.append([(start % Self.binCount) * step, (start % Self.binCount) * step + (anchor + offset - start) * step])
                runStart = nil
            }
        }
        return gaps
    }

    /// One 0…1 score. Object: a full orbit at any height is 85%; seeing half of the
    /// angles from a second height adds the last 15%. Space: travel plus view spread.
    func completeness(for mode: ScanMode) -> Double {
        switch mode {
        case .object:
            return min(1, 0.85 * orbitFraction + 0.15 * min(1, multiHeightFraction / 0.5))
        case .portrait:
            // Round 1 at chest height (whole body), round 2 at head height (face and
            // hair), and a frontal face seen up close.
            return min(1, 0.55 * orbitFraction + 0.3 * min(1, bandFraction(4) / Self.headRoundGoal)
                       + (frontFaceSeen ? 0.15 : 0))
        case .space:
            return min(1, 0.5 * min(1, Double(savedTravelMeters ?? travelMeters) / 2.0) + 0.3 * min(1, Double(lookSpanDegrees) / 120)
                       + (loopClosed ? 0.2 : 0))
        }
    }

    /// Where to move next. "Right" means the user's right while facing the target,
    /// which increases the orbit bin index (see ScanCoverageTracker.bin).
    func suggestedDirection(for mode: ScanMode) -> ScanDirection {
        switch mode {
        case .object, .portrait:
            guard let current = currentBin else { return .none }
            // 1. Close the first round at any height.
            if let gap = nearestGap(from: current, missing: { !orbitBins[$0] }) { return gap }
            // 2. A second height: the head round for a person; for an object the less
            //    covered of top-down (high) and level (low) views.
            if let band = missingBand(for: mode) {
                if currentHeightBand == band {
                    if let gap = nearestGap(from: current, missing: { heightBands[$0] & band == 0 }) { return gap }
                } else {
                    return band == 1 ? .down : .up
                }
            }
            // 3. A person's face, frontal and close.
            if mode == .portrait && !frontFaceSeen { return .face }
            return .none
        case .space:
            if travelMeters < Self.spaceTravelGoal { return .sideways }
            if !loopClosed { return .returnToStart }
            return .none
        }
    }

    /// The height band still to cover after the first round, if any.
    func missingBand(for mode: ScanMode) -> UInt8? {
        switch mode {
        case .portrait:
            return bandFraction(4) < Self.headRoundGoal ? 4 : nil
        case .object:
            guard multiHeightFraction < 0.5 else { return nil }
            return bandFraction(1) < bandFraction(4) ? 1 : 4
        case .space:
            return nil
        }
    }

    /// The nearest orbit bin (either way round) for which `missing` holds.
    private func nearestGap(from current: Int, missing: (Int) -> Bool) -> ScanDirection? {
        var right: Int?, left: Int?
        for step in 1...(Self.binCount / 2) {
            if right == nil, missing((current + step) % Self.binCount) { right = step }
            if left == nil, missing((current - step + Self.binCount) % Self.binCount) { left = step }
            if right != nil || left != nil { break }
        }
        let degrees = 360 / Self.binCount
        if let right, left.map({ right <= $0 }) ?? true { return .right(degrees: right * degrees) }
        if let left { return .left(degrees: left * degrees) }
        return nil
    }
}

enum ScanDirection: Equatable {
    /// face: get in front of the person at head height; returnToStart: walk back to
    /// where the space scan began, facing the same way.
    case left(degrees: Int), right(degrees: Int), up, down, sideways, face, returnToStart, none
}

/// How to turn the phone to bring an anchored target back into frame.
enum AimCorrection: Equatable { case left, right, up, down }

/// Accumulates poses into `ScanCoverage`. Not thread-safe; owned by one queue.
/// The target center starts as a guess (LiDAR depth or 1.2 m ahead) and is refined
/// to the point the camera keeps looking at: the least-squares intersection of all
/// view rays. Coverage is recomputed from every stored pose whenever it moves.
struct ScanCoverageTracker {
    private(set) var pivot: SIMD3<Float>?
    private(set) var snapshot = ScanCoverage()
    private var lastSavedPosition: SIMD3<Float>?
    private var savedOrigin: (position: SIMD3<Float>, forward: SIMD3<Float>)?
    private var savedMaxDistance: Float = 0
    private var samples: [(position: SIMD3<Float>, forward: SIMD3<Float>)] = []
    private var lastPosition: SIMD3<Float>?
    private var rayA = simd_float3x3()
    private var rayB = SIMD3<Float>(repeating: 0)
    private var firstForward: SIMD3<Float>?
    private var maxRaySpreadCos: Float = 1
    private var lastTimestamp: Double?
    private var lastForward: SIMD3<Float>?
    private var origin: (position: SIMD3<Float>, right: SIMD3<Float>, forward: SIMD2<Float>)?
    private var maxDistanceFromStart: Float = 0
    private var outOfFrameSince: Double?
    /// Seconds the target must stay out of frame before `aim` is reported.
    static let aimDelay = 0.6

    /// The target must be within this angle of the view center to count as "in frame".
    static let inFrameCos: Float = cos(32 * .pi / 180)

    private var pivotLocked = false
    /// Elevation (degrees) separating the low/mid and mid/high bands.
    private let bandEdges: (Float, Float)
    /// Portrait: the person's vertical extent (world Y). The phone counts as pointing at
    /// the person when any point of that segment is in frame, not only the center.
    private var axis: ClosedRange<Float>?
    /// Portrait: floor…top of the person (world Y). Heights are then judged from where
    /// the phone is: below half the body is low, up to 88% is chest, above is head.
    private var body: ClosedRange<Float>?

    var needsPivot: Bool { pivot == nil }

    init(portrait: Bool = false) {
        bandEdges = portrait ? (-10, 15) : (20, 50)
    }

    /// Uses a user-confirmed target center; disables automatic refinement.
    mutating func lockPivot(_ point: SIMD3<Float>, axis: ClosedRange<Float>? = nil, body: ClosedRange<Float>? = nil) {
        pivot = point
        pivotLocked = true
        self.axis = axis
        self.body = body.flatMap { $0.upperBound - $0.lowerBound > 0.3 ? $0 : nil }
        snapshot.pivotIsRefined = true
    }

    /// Places the first-guess pivot `distance` meters in front of the first tracked pose.
    mutating func setPivot(transform: simd_float4x4, distance: Float) {
        pivot = Self.position(transform) + Self.forward(transform) * max(0.25, distance)
    }

    mutating func add(transform: simd_float4x4, timestamp: Double? = nil, recordCoverage: Bool = true) {
        if !recordCoverage, snapshot.savedTravelMeters == nil { snapshot.savedTravelMeters = 0 }
        let position = Self.position(transform)
        let forward = Self.forward(transform)
        if let lastPosition {
            let step = simd_length(position - lastPosition)
            // Ignore tracking jumps; a hand-held walk never moves this far in one frame.
            if step < 0.25 {
                snapshot.travelMeters += step
                if let timestamp, let lastTimestamp, let lastForward {
                    let dt = timestamp - lastTimestamp
                    if dt > 0.005 && dt < 0.5 {
                        // About 0.4 s of smoothing, so one shaky frame does not trigger "slow down".
                        let alpha = Float(dt / (0.4 + dt))
                        let degrees = acos(min(1, max(-1, simd_dot(forward, lastForward)))) * 180 / .pi
                        snapshot.speed += alpha * (step / Float(dt) - snapshot.speed)
                        snapshot.turnRate += alpha * (degrees / Float(dt) - snapshot.turnRate)
                    }
                }
            }
        }
        lastPosition = position
        lastTimestamp = timestamp
        lastForward = forward
        if origin == nil, simd_length(SIMD2(forward.x, forward.z)) > 0.2 {
            // The user's right while facing the first view: forward × up, kept horizontal.
            origin = (position, simd_normalize(SIMD3(-forward.z, 0, forward.x)),
                      simd_normalize(SIMD2(forward.x, forward.z)))
        }
        if let origin { updateStart(position: position, forward: forward, origin: origin, allowClosure: recordCoverage) }
        if let pivot { mark(position: position, forward: forward, pivot: pivot, setCurrent: true, counts: false) }
        if pivotLocked, let pivot { updateAim(position: position, forward: forward, pivot: pivot, timestamp: timestamp) }
        if recordCoverage { recordSaved(transform: transform) }
    }

    /// Only call after the selected JPEG has been written successfully.
    mutating func recordSaved(transform: simd_float4x4) {
        let position = Self.position(transform), forward = Self.forward(transform)
        if let look = Self.bin(x: forward.x, z: forward.z) { snapshot.lookBins[look] = true }
        if snapshot.savedTravelMeters != nil {
            if let lastSavedPosition {
                let step = simd_length(position - lastSavedPosition)
                if step < 0.75 { snapshot.savedTravelMeters! += step }
            }
            if savedOrigin == nil { savedOrigin = (position, forward) }
            if let savedOrigin {
                let distance = simd_length(position - savedOrigin.position)
                savedMaxDistance = max(savedMaxDistance, distance)
                if savedMaxDistance >= 0.8, distance < 0.5,
                   snapshot.savedTravelMeters! >= ScanCoverage.spaceTravelGoal,
                   simd_dot(forward, savedOrigin.forward) > cos(35 * Float.pi / 180) { snapshot.loopClosed = true }
            }
            lastSavedPosition = position
        }
        // Least-squares accumulation for the point closest to all view rays.
        let projector = matrix_identity_float3x3 - simd_float3x3(columns: (forward * forward.x,
                                                                            forward * forward.y,
                                                                            forward * forward.z))
        rayA += projector
        rayB += projector * position
        if let firstForward { maxRaySpreadCos = min(maxRaySpreadCos, simd_dot(firstForward, forward)) }
        else { firstForward = forward }

        if samples.last.map({ simd_length($0.position - position) > 0.01 || simd_dot($0.forward, forward) < 0.9995 }) ?? true {
            samples.append((position, forward))
        }
        if let pivot { mark(position: position, forward: forward, pivot: pivot, setCurrent: false) }
    }

    mutating func markFrontFace() { snapshot.frontFaceSeen = true }
    mutating func setSubjectMoving(_ moving: Bool) { snapshot.subjectMoving = moving }

    /// Sideways travel, the way back to the start, and loop closure: back within 50 cm
    /// of the start, facing within 35° of the first view, after walking away ≥ 0.8 m.
    private mutating func updateStart(position: SIMD3<Float>, forward: SIMD3<Float>,
                                      origin: (position: SIMD3<Float>, right: SIMD3<Float>, forward: SIMD2<Float>), allowClosure: Bool) {
        snapshot.lateralMeters = simd_dot(position - origin.position, origin.right)
        let away = SIMD2(position.x - origin.position.x, position.z - origin.position.z)
        snapshot.distanceFromStart = simd_length(away)
        maxDistanceFromStart = max(maxDistanceFromStart, snapshot.distanceFromStart)
        let flat = SIMD2(forward.x, forward.z)
        guard simd_length(flat) > 0.2 else { return }
        let heading = simd_normalize(flat), toStart = -away
        // + when the start is to the right: the opposite sign of forward × toStart (Y).
        snapshot.startSide = heading.x * toStart.y - heading.y * toStart.x
        if allowClosure, !snapshot.loopClosed, snapshot.travelMeters >= ScanCoverage.spaceTravelGoal,
           maxDistanceFromStart >= 0.8, snapshot.distanceFromStart < 0.5,
           simd_dot(heading, origin.forward) > cos(35 * Float.pi / 180) {
            snapshot.loopClosed = true
        }
    }

    private mutating func updateAim(position: SIMD3<Float>, forward: SIMD3<Float>, pivot: SIMD3<Float>,
                                    timestamp: Double?) {
        snapshot.horizontalDistance = simd_length(SIMD2(position.x - pivot.x, position.z - pivot.z))
        guard !isInFrame(position: position, forward: forward, pivot: pivot) else {
            outOfFrameSince = nil
            snapshot.aim = nil
            return
        }
        let now = timestamp ?? 0
        let since = outOfFrameSince ?? now
        outOfFrameSince = since
        if timestamp == nil || now - since >= Self.aimDelay {
            snapshot.aim = Self.aim(position: position, forward: forward, pivot: pivot, axis: axis)
        }
    }

    /// Turn left/right when the target is well off to the side, else tilt toward the
    /// target's vertical extent (the whole body for a person).
    static func aim(position: SIMD3<Float>, forward: SIMD3<Float>, pivot: SIMD3<Float>,
                    axis: ClosedRange<Float>?) -> AimCorrection {
        let to = pivot - position
        let flatForward = SIMD2(forward.x, forward.z), flatTo = SIMD2(to.x, to.z)
        let horizontal = max(0.05, simd_length(flatTo))
        var turn: AimCorrection = .right
        if simd_length(flatForward) > 0.1, simd_length(flatTo) > 0.05 {
            let f = simd_normalize(flatForward), t = simd_normalize(flatTo)
            // Y of forward × toTarget: positive when the target is to the left.
            turn = f.y * t.x - f.x * t.y > 0 ? .left : .right
            if simd_dot(f, t) < cos(20 * Float.pi / 180) { return turn }
        }
        let pitch = atan2(forward.y, simd_length(flatForward))
        let extent = axis ?? pivot.y...pivot.y
        if pitch > atan2(extent.upperBound - position.y, horizontal) { return .down }
        if pitch < atan2(extent.lowerBound - position.y, horizontal) { return .up }
        return turn
    }

    /// Refines the pivot once views span > 25° and rebuilds coverage from all poses.
    mutating func refine() {
        guard !pivotLocked, maxRaySpreadCos < cos(25 * .pi / 180), abs(rayA.determinant) > 1e-4 else { return }
        let candidate = rayA.inverse * rayB
        guard candidate.x.isFinite, candidate.y.isFinite, candidate.z.isFinite else { return }
        // Accept only a point in front of most views and at a hand-held distance.
        let recent = samples.suffix(300)
        let inFront = recent.filter { simd_dot($0.forward, candidate - $0.position) > 0 }.count
        let distances = recent.map { simd_length(candidate - $0.position) }.sorted()
        guard !recent.isEmpty, inFront * 10 >= recent.count * 7,
              let median = distances.dropFirst(distances.count / 2).first, median > 0.15, median < 6 else { return }
        pivot = candidate
        snapshot.pivotIsRefined = true
        let current = snapshot.currentBin
        snapshot.orbitBins = [Bool](repeating: false, count: ScanCoverage.binCount)
        snapshot.heightBands = [UInt8](repeating: 0, count: ScanCoverage.binCount)
        for sample in samples { mark(position: sample.position, forward: sample.forward, pivot: candidate, setCurrent: false) }
        if let last = samples.last { mark(position: last.position, forward: last.forward, pivot: candidate, setCurrent: true) }
        else { snapshot.currentBin = current }
    }

    private mutating func mark(position: SIMD3<Float>, forward: SIMD3<Float>, pivot: SIMD3<Float>, setCurrent: Bool, counts: Bool = true) {
        let offset = position - pivot
        let distance = simd_length(offset)
        let horizontal = simd_length(SIMD2(offset.x, offset.z))
        guard distance > 0.05, horizontal > 0.03, let orbit = Self.bin(x: offset.x, z: offset.z) else { return }
        let band: UInt8
        if let body {
            let share = (position.y - body.lowerBound) / (body.upperBound - body.lowerBound)
            band = share < 0.5 ? 1 : (share < 0.88 ? 2 : 4)
        } else {
            let elevation = atan2(offset.y, horizontal) * 180 / .pi
            band = elevation < bandEdges.0 ? 1 : (elevation < bandEdges.1 ? 2 : 4)
        }
        if setCurrent {
            snapshot.currentBin = orbit
            snapshot.targetDistance = distance
            snapshot.currentHeightBand = band
        }
        // Count the angle only if the target is actually in frame.
        guard counts, isInFrame(position: position, forward: forward, pivot: pivot) else { return }
        snapshot.orbitBins[orbit] = true
        snapshot.heightBands[orbit] |= band
    }

    private func isInFrame(position: SIMD3<Float>, forward: SIMD3<Float>, pivot: SIMD3<Float>) -> Bool {
        func sees(_ point: SIMD3<Float>) -> Bool {
            let toPoint = point - position
            let length = simd_length(toPoint)
            return length > 1e-3 && simd_dot(forward, toPoint / length) >= Self.inFrameCos
        }
        guard let axis else { return sees(pivot) }
        // Five points from the feet to the head stand in for the whole body.
        return (0...4).contains { step in
            sees(SIMD3(pivot.x, axis.lowerBound + (axis.upperBound - axis.lowerBound) * Float(step) / 4, pivot.z))
        }
    }

    static func bin(x: Float, z: Float) -> Int? {
        guard x.isFinite, z.isFinite, abs(x) + abs(z) > 1e-4 else { return nil }
        let angle = atan2(x, z) + .pi // 0..2π
        let index = Int(angle / (2 * .pi) * Float(ScanCoverage.binCount))
        return min(ScanCoverage.binCount - 1, max(0, index))
    }

    private static func position(_ t: simd_float4x4) -> SIMD3<Float> {
        SIMD3(t.columns.3.x, t.columns.3.y, t.columns.3.z)
    }

    /// ARKit cameras look down their local -Z axis.
    private static func forward(_ t: simd_float4x4) -> SIMD3<Float> {
        let back = SIMD3(t.columns.2.x, t.columns.2.y, t.columns.2.z)
        let length = simd_length(back)
        return length > 0 ? -back / length : SIMD3(0, 0, -1)
    }
}

/// Capture-quality report written next to the scan (`analysis.json`) to guide the
/// user before upload and to inform reconstruction. Heuristic, not a quality grade.
struct ScanAnalysis: Codable, Equatable {
    var schemaVersion = 1
    var mode: String
    var durationSeconds: Double
    var frameCount: Int
    var depthFrameRatio: Double
    var trackingNormalRatio: Double
    var limitedReasons: [String: Int]
    var meanSpeed: Double
    var maxSpeed: Double
    var fastMotionRatio: Double
    var meanAngularSpeedDegrees: Double
    var fastRotationRatio: Double
    var meanAmbientLux: Double?
    var darkRatio: Double
    var meanFeaturePoints: Double?
    var lowTextureRatio: Double
    var medianTargetDistance: Double?
    var orbitCoverage: Double
    var multiHeightCoverage: Double
    var completeness: Double
    var travelMeters: Double
    var lookSpanDegrees: Int
    var gapsDegrees: [[Int]]
    var orbitBins: [Bool]
    var heightBands: [UInt8]
    var lookBins: [Bool]
    var verdict: String          // good | fair | poor
    var issues: [String]
    var suggestions: [String]
    /// Object box confirmed before recording (ARKit world frame, same as frames.jsonl).
    var targetBox: ScanTargetBox? = nil
    /// Training package (`capture/`): keyframes kept, and how many were taken while the
    /// person moved. Optional so older reports decode unchanged.
    var keyframeCount: Int? = nil
    var movingKeyframeCount: Int? = nil
    var frontFaceSeen: Bool? = nil
    var loopClosed: Bool? = nil
    var exposureLocked: Bool? = nil

    var verdictLabel: String {
        switch verdict {
        case "good": return "适合重建"
        case "fair": return "可以重建，效果可能受影响"
        default: return "建议重拍"
        }
    }

    var coverage: ScanCoverage {
        var value = ScanCoverage()
        if orbitBins.count == ScanCoverage.binCount { value.orbitBins = orbitBins }
        if heightBands.count == ScanCoverage.binCount { value.heightBands = heightBands }
        if lookBins.count == ScanCoverage.binCount { value.lookBins = lookBins }
        value.travelMeters = Float(travelMeters)
        return value
    }

    static func load(from folder: URL) -> ScanAnalysis? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("analysis.json")) else { return nil }
        return try? JSONDecoder().decode(ScanAnalysis.self, from: data)
    }
}

/// Per-frame accumulator for `ScanAnalysis`. Pure value type; owned by one queue.
struct ScanAnalyzer {
    enum Tracking { case normal, limited(String), notAvailable }

    private var firstTimestamp: Double?
    private var lastTimestamp: Double?
    private var lastPosition: SIMD3<Float>?
    private var lastForward: SIMD3<Float>?
    private var frames = 0, depthFrames = 0, normalFrames = 0
    private var limited: [String: Int] = [:]
    private var speedSum = 0.0, speedCount = 0, maxSpeed = 0.0, fastMotion = 0
    private var angularSum = 0.0, fastRotation = 0
    private var luxSum = 0.0, luxCount = 0, dark = 0
    private var featureSum = 0.0, featureCount = 0, lowTexture = 0
    private var distances: [Float] = []

    static let fastSpeed = 0.5          // m/s
    static let fastRotation = 60.0      // °/s
    static let darkLux = 250.0
    static let lowFeatures = 40

    mutating func add(timestamp: Double, transform: simd_float4x4, tracking: Tracking,
                      ambientLux: Double?, featurePoints: Int?, hasDepth: Bool, targetDistance: Float?) {
        frames += 1
        if hasDepth { depthFrames += 1 }
        switch tracking {
        case .normal: normalFrames += 1
        case .limited(let reason): limited[reason, default: 0] += 1
        case .notAvailable: limited["notAvailable", default: 0] += 1
        }
        if firstTimestamp == nil { firstTimestamp = timestamp }
        let position = SIMD3(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
        let back = SIMD3(transform.columns.2.x, transform.columns.2.y, transform.columns.2.z)
        let forward = simd_length(back) > 0 ? -simd_normalize(back) : SIMD3<Float>(0, 0, -1)
        if let lastTimestamp, let lastPosition, let lastForward {
            let dt = timestamp - lastTimestamp
            if dt > 0.005 && dt < 0.5 {
                let speed = Double(simd_length(position - lastPosition)) / dt
                let angle = Double(acos(min(1, max(-1, simd_dot(forward, lastForward))))) * 180 / .pi / dt
                if speed < 5 { // ignore tracking jumps
                    speedSum += speed; speedCount += 1; maxSpeed = max(maxSpeed, speed)
                    if speed > Self.fastSpeed { fastMotion += 1 }
                    angularSum += angle
                    if angle > Self.fastRotation { fastRotation += 1 }
                }
            }
        }
        lastTimestamp = timestamp; lastPosition = position; lastForward = forward
        if let ambientLux { luxSum += ambientLux; luxCount += 1; if ambientLux < Self.darkLux { dark += 1 } }
        if let featurePoints {
            featureSum += Double(featurePoints); featureCount += 1
            if featurePoints < Self.lowFeatures { lowTexture += 1 }
        }
        if let targetDistance, targetDistance.isFinite { distances.append(targetDistance) }
    }

    /// What the recorder knows beyond poses (training package, exposure lock).
    struct Extras {
        var keyframes: Int? = nil
        var keyframeRange: ClosedRange<Int>? = nil
        var movingKeyframes = 0
        var exposureLocked: Bool? = nil
    }

    func finalize(coverage: ScanCoverage, mode: ScanMode, extras: Extras = Extras()) -> ScanAnalysis {
        func ratio(_ count: Int, _ total: Int) -> Double { total > 0 ? Double(count) / Double(total) : 0 }
        let sortedDistances = distances.sorted()
        let completeness = coverage.completeness(for: mode)
        var issues: [String] = [], suggestions: [String] = []
        let duration = (lastTimestamp ?? 0) - (firstTimestamp ?? 0)
        let trackingRatio = ratio(normalFrames, frames)
        let motionRatio = ratio(fastMotion, speedCount)
        let rotationRatio = ratio(fastRotation, speedCount)
        let darkRatio = ratio(dark, luxCount)
        let lowTextureRatio = ratio(lowTexture, featureCount)
        let median = sortedDistances.isEmpty ? nil : Double(sortedDistances[sortedDistances.count / 2])

        if mode.usesAnchor && coverage.orbitFraction < 0.85 {
            let missing = coverage.gapsDegrees.prefix(3).map { "\($0[0] % 360)°–\($0[1] % 360 == 0 ? 360 : $0[1] % 360)°" }
            issues.append("环绕只覆盖了 \(Int(coverage.orbitFraction * 100))%" + (missing.isEmpty ? "" : "，缺少 \(missing.joined(separator: "、"))"))
            suggestions.append(mode == .portrait ? "从不同位置补拍侧面和背面" : "换几个机位，补拍遮挡和缺少的角度")
        }
        if mode == .portrait && coverage.bandFraction(4) < 0.3 {
            issues.append("头部高度的素材偏少")
            suggestions.append("举到头部高度，从不同位置补拍脸和头发")
        } else if mode == .object && coverage.multiHeightFraction < 0.25 {
            issues.append("几乎只从一个高度拍摄")
            suggestions.append(coverage.missingBand(for: .object) == 1
                ? "放低手机，从不同位置补拍侧面和低处"
                : "举高手机，从不同位置补拍顶部")
        }
        if mode == .portrait && !coverage.frontFaceSeen {
            issues.append("没有拍到清楚的正脸")
            suggestions.append("走到人的正面，在头部高度拍几秒")
        }
        if mode == .portrait, let keyframes = extras.keyframes, keyframes > 0,
           Double(extras.movingKeyframes) / Double(keyframes) > 0.15 {
            issues.append("拍摄中对方动了（\(extras.movingKeyframes) 张关键帧已标记）")
            suggestions.append("请对方全程站定不动，眼睛看一个固定点")
        }
        if mode == .space && coverage.travelMeters < 1 {
            issues.append(String(format: "只移动了 %.1f 米", coverage.travelMeters))
            suggestions.append("慢慢走动至少 2 米，不要原地转身")
        }
        if mode == .space && coverage.travelMeters >= 1 && !coverage.loopClosed {
            issues.append("没有走回起点")
            suggestions.append("最后走回起点，对准开始的画面再结束")
        }
        if trackingRatio < 0.85 {
            let top = limited.max { $0.value < $1.value }?.key
            issues.append("相机追踪不稳定的画面占 \(Int((1 - trackingRatio) * 100))%" + (top.map { "（主要原因：\(Self.reasonLabel($0))）" } ?? ""))
            suggestions.append("放慢移动，对准有细节的静止区域")
        }
        if max(motionRatio, rotationRatio) > 0.15 {
            issues.append("移动或转动过快的画面占 \(Int(max(motionRatio, rotationRatio) * 100))%，可能模糊")
            suggestions.append("走得再慢一些，转身时尤其要慢")
        }
        if darkRatio > 0.3 {
            issues.append("光线偏暗的画面占 \(Int(darkRatio * 100))%")
            suggestions.append("打开灯或换到更明亮的地方")
        }
        if lowTextureRatio > 0.3 {
            issues.append("纹理较少的画面占 \(Int(lowTextureRatio * 100))%")
            suggestions.append("避开纯色、反光或透明表面，或在周围放些有图案的物品")
        }
        if mode == .object, let median {
            if median > 2.5 { issues.append(String(format: "离物体偏远（约 %.1f 米）", median)); suggestions.append("靠近到 0.5–1.5 米") }
            if median < 0.2 { issues.append("离物体太近"); suggestions.append("后退到 0.5 米左右，让物体完整入画") }
        }
        if mode == .portrait, let median {
            if median > 2.5 { issues.append(String(format: "离人偏远（约 %.1f 米）", median)); suggestions.append("靠近到 1–1.5 米") }
            if median < 0.6 { issues.append("离人太近"); suggestions.append("后退到 1 米左右，让上半身完整入画") }
        }
        if mode == .portrait && duration > 60 {
            issues.append(String(format: "人像拍了 %.0f 秒，超过 1 分钟", duration))
            suggestions.append("人很难长时间不动，尽量 1 分钟内拍完")
        }
        if duration < 15 {
            issues.append(String(format: "拍摄时间较短（%.0f 秒）", duration))
            suggestions.append(mode == .portrait ? "一般需要 30–60 秒" : "一般需要 30–90 秒")
        }
        if let keyframes = extras.keyframes, let range = extras.keyframeRange, keyframes < range.lowerBound,
           duration >= 15 {
            issues.append("清晰的训练关键帧偏少（\(keyframes) 张，建议 \(range.lowerBound)–\(range.upperBound)）")
            suggestions.append("放慢移动并拍得更完整，模糊和重复的画面不算")
        }
        let verdict: String
        if completeness < 0.5 || trackingRatio < 0.6 || frames < 90 { verdict = "poor" }
        else if issues.isEmpty { verdict = "good" }
        else { verdict = "fair" }

        var analysis = ScanAnalysis(
            mode: mode.rawValue, durationSeconds: duration, frameCount: frames,
            depthFrameRatio: ratio(depthFrames, frames), trackingNormalRatio: trackingRatio,
            limitedReasons: limited,
            meanSpeed: speedCount > 0 ? speedSum / Double(speedCount) : 0, maxSpeed: maxSpeed,
            fastMotionRatio: motionRatio,
            meanAngularSpeedDegrees: speedCount > 0 ? angularSum / Double(speedCount) : 0,
            fastRotationRatio: rotationRatio,
            meanAmbientLux: luxCount > 0 ? luxSum / Double(luxCount) : nil, darkRatio: darkRatio,
            meanFeaturePoints: featureCount > 0 ? featureSum / Double(featureCount) : nil,
            lowTextureRatio: lowTextureRatio, medianTargetDistance: median,
            orbitCoverage: coverage.orbitFraction, multiHeightCoverage: coverage.multiHeightFraction,
            completeness: completeness, travelMeters: Double(coverage.travelMeters),
            lookSpanDegrees: coverage.lookSpanDegrees, gapsDegrees: coverage.gapsDegrees,
            orbitBins: coverage.orbitBins, heightBands: coverage.heightBands, lookBins: coverage.lookBins,
            verdict: verdict, issues: issues, suggestions: suggestions)
        analysis.keyframeCount = extras.keyframes
        analysis.movingKeyframeCount = extras.keyframes == nil ? nil : extras.movingKeyframes
        analysis.frontFaceSeen = mode == .portrait ? coverage.frontFaceSeen : nil
        analysis.loopClosed = mode == .space ? coverage.loopClosed : nil
        analysis.exposureLocked = extras.exposureLocked
        return analysis
    }

    static func reasonLabel(_ key: String) -> String {
        switch key {
        case "excessiveMotion": return "移动过快"
        case "insufficientFeatures": return "纹理不足"
        case "initializing": return "正在初始化"
        case "relocalizing": return "重新定位"
        case "notAvailable": return "追踪不可用"
        default: return "追踪受限"
        }
    }
}
