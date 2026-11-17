import AVFoundation
import Combine
import UIKit

/// AVCapture configuration/start/stop live on one serial queue. Published UI changes use main.
final class NativeCameraController: NSObject, ObservableObject, AVCaptureFileOutputRecordingDelegate {
    let session = AVCaptureSession()
    @Published private(set) var ready = false
    @Published private(set) var isRecording = false
    @Published private(set) var isSaving = false
    @Published private(set) var denied = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var interruptionMessage: String?
    @Published private(set) var recordingStartedAt: Date?
    var onSaved: ((CapturedVideo) -> Void)?
    var sessionID: String?

    private let queue = DispatchQueue(label: "world.pocket.capture", qos: .userInitiated)
    private let movieOutput = AVCaptureMovieFileOutput()
    private var configured = false
    private var wantsRunning = true
    private var observers: [NSObjectProtocol] = []
    private var startedAt = Date()
    private var recordingSessionID: String?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    override init() {
        super.init()
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .AVCaptureSessionWasInterrupted,
                                             object: session, queue: nil) { [weak self] _ in
            self?.interrupted("拍摄被打断了，正在保存已录下的片段。")
        })
        observers.append(center.addObserver(forName: .AVCaptureSessionRuntimeError,
                                             object: session, queue: nil) { [weak self] note in
            let detail = (note.userInfo?[AVCaptureSessionErrorKey] as? Error)?.localizedDescription
            self?.interrupted(detail ?? "相机暂时不可用，请保存后重新进入。")
        })
        observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                                             object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            if self.isRecording {
                self.backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "FinishCapture") { [weak self] in
                    self?.endBackgroundTask()
                }
            }
            self.interrupted("已暂停拍摄，片段会保存在本机。")
        })
        observers.append(center.addObserver(forName: UIApplication.willEnterForegroundNotification,
                                             object: nil, queue: .main) { [weak self] _ in
            self?.prepare()
        })
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    func prepare() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureAndStart()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                if granted { self?.configureAndStart() }
                else { DispatchQueue.main.async { self?.denied = true } }
            }
        default:
            DispatchQueue.main.async { self.denied = true }
        }
    }

    private func configureAndStart() {
        queue.async { [weak self] in
            guard let self, self.wantsRunning else { return }
            do {
                if !self.configured {
                    self.session.beginConfiguration()
                    defer { self.session.commitConfiguration() }
                    if self.session.canSetSessionPreset(.hd1920x1080) {
                        self.session.sessionPreset = .hd1920x1080
                    }
                    guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera,
                                    for: .video, position: .back) else {
                        throw CaptureError.noCamera
                    }
                    let input = try AVCaptureDeviceInput(device: camera)
                    guard self.session.canAddInput(input), self.session.canAddOutput(self.movieOutput) else {
                        throw CaptureError.setup
                    }
                    self.session.addInput(input)
                    self.session.addOutput(self.movieOutput)
                    // Intentionally never add an audio input. No microphone permission is needed.
                    self.movieOutput.maxRecordedDuration = CMTime(seconds: 90, preferredTimescale: 600)
                    self.movieOutput.maxRecordedFileSize = 450 * 1024 * 1024
                    if let connection = self.movieOutput.connection(with: .video) {
                        if connection.isVideoRotationAngleSupported(90) { connection.videoRotationAngle = 90 }
                        // Stabilization can crop/change camera geometry; disable it for raw reconstruction input.
                        if connection.isVideoStabilizationSupported { connection.preferredVideoStabilizationMode = .off }
                        if self.movieOutput.availableVideoCodecTypes.contains(.h264) {
                            self.movieOutput.setOutputSettings([AVVideoCodecKey: AVVideoCodecType.h264], for: connection)
                        }
                    }
                    self.configured = true
                }
                if !self.session.isRunning { self.session.startRunning() }
                DispatchQueue.main.async {
                    self.ready = true
                    self.denied = false
                    self.errorMessage = nil
                }
            } catch {
                DispatchQueue.main.async { self.errorMessage = error.localizedDescription }
            }
        }
    }

    func startRecording() {
        guard ready, !isRecording, !isSaving else { return }
        isSaving = true // Also disables rapid repeated starts until the delegate confirms recording.
        errorMessage = nil
        interruptionMessage = nil
        let initiatingSessionID = sessionID
        queue.async { [weak self] in
            guard let self else { return }
            do {
                guard self.configured, self.session.isRunning, !self.movieOutput.isRecording else {
                    throw CaptureError.setup
                }
                let destination = try CapturedVideo.directory()
                    .appendingPathComponent(UUID().uuidString.lowercased()).appendingPathExtension("mov")
                self.startedAt = Date()
                self.recordingSessionID = initiatingSessionID
                self.movieOutput.startRecording(to: destination, recordingDelegate: self)
            } catch {
                DispatchQueue.main.async {
                    self.isSaving = false
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    func stopRecording() {
        if isRecording { isSaving = true }
        queue.async { [weak self] in
            guard let self, self.movieOutput.isRecording else { return }
            self.movieOutput.stopRecording()
        }
    }

    func shutdown() {
        queue.async { [weak self] in
            guard let self else { return }
            self.wantsRunning = false
            if self.movieOutput.isRecording { self.movieOutput.stopRecording() }
            if self.session.isRunning { self.session.stopRunning() }
            DispatchQueue.main.async { self.ready = false }
        }
    }

    private func interrupted(_ message: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.interruptionMessage = message
            self.stopRecording()
        }
    }

    func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo fileURL: URL,
                    from connections: [AVCaptureConnection]) {
        let timestamp = startedAt
        DispatchQueue.main.async {
            self.isSaving = false
            self.isRecording = true
            self.recordingStartedAt = timestamp
        }
    }

    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL,
                    from connections: [AVCaptureConnection], error: Error?) {
        let capturedAt = startedAt
        let savedSessionID = recordingSessionID
        DispatchQueue.main.async {
            self.isRecording = false
            self.isSaving = true
        }
        let nsError = error as NSError?
        let finishedSuccessfully = nsError?.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool ?? false
        if let error, !finishedSuccessfully {
            DispatchQueue.main.async {
                self.isSaving = false
                self.errorMessage = "片段未能完整保存：\(error.localizedDescription)"
                self.endBackgroundTask()
            }
            return
        }
        Task {
            do {
                let asset = AVURLAsset(url: outputFileURL)
                let duration = try await asset.load(.duration).seconds
                guard duration.isFinite, duration > 0.1,
                      let track = try await asset.loadTracks(withMediaType: .video).first else {
                    throw CaptureError.emptyRecording
                }
                let size = try await track.load(.naturalSize)
                let transform = try await track.load(.preferredTransform)
                let fps = try await track.load(.nominalFrameRate)
                let displaySize = size.applying(transform)
                var thumbnailURL: URL?
                let generator = AVAssetImageGenerator(asset: asset)
                generator.appliesPreferredTrackTransform = true
                generator.maximumSize = CGSize(width: 720, height: 720)
                if let result = try? await generator.image(at: CMTime(seconds: min(duration / 2, 1), preferredTimescale: 600)),
                   let jpeg = UIImage(cgImage: result.image).jpegData(compressionQuality: 0.85) {
                    let target = outputFileURL.deletingPathExtension().appendingPathExtension("jpg")
                    try jpeg.write(to: target, options: .atomic)
                    thumbnailURL = target
                }
                let capture = CapturedVideo(url: outputFileURL, previewURL: thumbnailURL,
                    capturedAt: capturedAt, durationSeconds: duration,
                    width: Int(abs(displaySize.width).rounded()),
                    height: Int(abs(displaySize.height).rounded()), fps: Double(fps),
                    sessionID: savedSessionID)
                try capture.saveSidecar()
                try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                                                       ofItemAtPath: outputFileURL.path)
                await MainActor.run {
                    self.isSaving = false
                    self.onSaved?(capture)
                    self.endBackgroundTask()
                }
            } catch {
                await MainActor.run {
                    self.isSaving = false
                    self.errorMessage = "无法读取刚保存的片段：\(error.localizedDescription)"
                    self.endBackgroundTask()
                }
            }
        }
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    private enum CaptureError: LocalizedError {
        case noCamera, setup, emptyRecording
        var errorDescription: String? {
            switch self {
            case .noCamera: return "未找到可用后置相机。请在真实 iPhone 上拍摄。"
            case .setup: return "暂时无法启动相机，请返回后重试。"
            case .emptyRecording: return "片段太短或没有可读取的视频画面，请重新拍摄。"
            }
        }
    }
}
