import AVFoundation
import Metal
import Photos
import SwiftUI

/// A short video of the 3DGS for sharing, rendered from the loaded model itself (no substitute
/// footage) and saved to Photos as an MP4. One template per scan mode, following the plan:
/// objects orbit, people orbit and then push in, spaces drift forward.
enum OrbitVideo {
    enum Style: Equatable, Sendable {
        case orbit, portrait, flythrough

        init(mode: String?) {
            switch mode {
            case ScanMode.portrait.rawValue: self = .portrait
            case ScanMode.space.rawValue: self = .flythrough
            default: self = .orbit
            }
        }
    }

    static let width = 1080
    static let height = 1920
    static let fps: Int32 = 30
    static let durationSeconds = 6.0
    static var frameCount: Int { Int(durationSeconds * Double(fps)) }

    /// Smooth start and stop.
    static func ease(_ t: Float) -> Float { t * t * (3 - 2 * t) }

    /// Camera poses for one video. With a captured yaw range the orbit sweeps that arc and back;
    /// without one (the scan went all the way round) it makes a full turn.
    static func poses(style: Style, center: OrbitPose, yawRange: ClosedRange<Float>?, frameCount: Int) -> [OrbitPose] {
        let count = max(2, frameCount)
        return (0..<count).map { index in
            let t = Float(index) / Float(count - 1)
            var pose = center
            switch style {
            case .orbit, .portrait:
                if let yawRange {
                    let middle = (yawRange.lowerBound + yawRange.upperBound) / 2
                    let amplitude = (yawRange.upperBound - yawRange.lowerBound) / 2
                    pose.yaw = middle - amplitude * cos(2 * .pi * t)
                } else {
                    pose.yaw = center.yaw + 2 * .pi * ease(t)
                }
                if style == .portrait && t > 0.7 {
                    // Last 30%: move in toward the person.
                    pose.distanceScale = center.distanceScale * (1 - 0.35 * ease((t - 0.7) / 0.3))
                }
            case .flythrough:
                pose.distanceScale = center.distanceScale * (1.35 - 0.6 * ease(t))
                let drift: Float = 0.18
                let middle = yawRange.map { min($0.upperBound - drift, max($0.lowerBound + drift, center.yaw)) } ?? center.yaw
                pose.yaw = middle + drift * sin(.pi * (t - 0.5))
            }
            return pose
        }
    }

    static func saveToPhotos(videoURL: URL) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { throw LivePhotoExport.ExportError.photosDenied }
        try await PHPhotoLibrary.shared().performChanges {
            let options = PHAssetResourceCreationOptions()
            options.shouldMoveFile = true
            PHAssetCreationRequest.forAsset().addResource(with: .video, fileURL: videoURL, options: options)
        }
    }
}

/// H.264 MP4 from rendered BGRA textures.
final class OrbitVideoWriter {
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let fps: Int32
    private let width: Int
    private let height: Int

    init(url: URL, width: Int, height: Int, fps: Int32) throws {
        self.width = width; self.height = height; self.fps = fps
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 14_000_000],
        ])
        input.expectsMediaDataInRealTime = false
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ])
        guard writer.canAdd(input) else { throw LivePhotoExport.ExportError.writerFailed }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? LivePhotoExport.ExportError.writerFailed }
        writer.startSession(atSourceTime: .zero)
    }

    func append(_ texture: MTLTexture, frame: Int) async throws {
        while !input.isReadyForMoreMediaData {
            guard writer.status == .writing else { throw writer.error ?? LivePhotoExport.ExportError.writerFailed }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        guard let pool = adaptor.pixelBufferPool else { throw LivePhotoExport.ExportError.writerFailed }
        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer)
        guard let pixelBuffer else { throw LivePhotoExport.ExportError.writerFailed }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        if let base = CVPixelBufferGetBaseAddress(pixelBuffer) {
            texture.getBytes(base, bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                             from: MTLRegionMake2D(0, 0, min(width, texture.width), min(height, texture.height)),
                             mipmapLevel: 0)
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        CVBufferSetAttachment(pixelBuffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(pixelBuffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(pixelBuffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        guard adaptor.append(pixelBuffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: fps)) else {
            throw writer.error ?? LivePhotoExport.ExportError.writerFailed
        }
    }

    func finish() async throws {
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? LivePhotoExport.ExportError.writerFailed }
    }

    func cancel() { writer.cancelWriting() }
}

/// Drives one video export from the viewer and reports progress for its overlay.
@MainActor
final class OrbitVideoExportController: ObservableObject {
    enum Phase: Equatable { case idle, rendering(Double), saving, saved, failed(String) }

    @Published private(set) var phase: Phase = .idle
    weak var renderer: PocketSplatRenderer?
    private var task: Task<Void, Never>?

    var isBusy: Bool {
        switch phase {
        case .rendering, .saving: return true
        default: return false
        }
    }

    func start(poses: [OrbitPose]) {
        guard !isBusy, let renderer else { return }
        phase = .rendering(0)
        task = Task { [weak self] in await self?.run(renderer: renderer, poses: poses) }
    }

    func cancel() {
        task?.cancel()
        task = nil
        if isBusy { phase = .idle }
    }

    func dismissResult() {
        if case .saved = phase { phase = .idle }
        if case .failed = phase { phase = .idle }
    }

    private func run(renderer: PocketSplatRenderer, poses: [OrbitPose]) async {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("orbit-video-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("phocoscan-3dgs.mp4")
            let writer = try OrbitVideoWriter(url: url, width: OrbitVideo.width, height: OrbitVideo.height, fps: OrbitVideo.fps)
            do {
                try await renderer.renderClip(poses: poses, width: OrbitVideo.width, height: OrbitVideo.height,
                    progress: { [weak self] value in self?.phase = .rendering(value) },
                    deliver: { texture, index in try await writer.append(texture, frame: index) })
                try await writer.finish()
            } catch {
                writer.cancel()
                throw error
            }
            phase = .saving
            try await OrbitVideo.saveToPhotos(videoURL: url)
            phase = .saved
        } catch is CancellationError {
            phase = .idle
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }
}
