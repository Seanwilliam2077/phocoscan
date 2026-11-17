import AVFoundation
import ImageIO
import Metal
import Photos
import SwiftUI
import UniformTypeIdentifiers

/// Saves the 3D view as a Live Photo: a short orbit render of the loaded model itself (no substitute
/// footage) paired with a still frame taken from the same clip. Only add-only Photos access is requested.
enum LivePhotoExport {
    static let width = 1080
    static let height = 1920
    static let fps: Int32 = 30
    static let durationSeconds = 3.0
    /// Peak yaw swing either side of the starting view (≈20°).
    static let swing: Float = 0.35

    /// One seamless loop: start at `center`, swing right, back through the centre, swing left and return.
    /// The swing stays inside `yawRange` (the captured angles) when one is given.
    static func orbitPoses(center: OrbitPose, yawRange: ClosedRange<Float>?, frameCount: Int) -> [OrbitPose] {
        var middle = center.yaw
        var amplitude = swing
        if let yawRange {
            amplitude = min(amplitude, (yawRange.upperBound - yawRange.lowerBound) / 2)
            middle = min(yawRange.upperBound - amplitude, max(yawRange.lowerBound + amplitude, middle))
        }
        return (0..<max(1, frameCount)).map { index in
            var pose = center
            let t = Float(index) / Float(max(1, frameCount))
            pose.yaw = middle + amplitude * sin(2 * .pi * t)
            return pose
        }
    }

    /// The still sits halfway through the loop, where the view passes back through the centre.
    static func stillFrameIndex(frameCount: Int) -> Int { frameCount / 2 }

    enum ExportError: LocalizedError {
        case photosDenied, writerFailed, stillFailed
        var errorDescription: String? {
            switch self {
            case .photosDenied: return "没有相册写入权限。可在 设置 › phocoscan › 照片 中允许“仅添加照片”。"
            case .writerFailed: return "实况照片视频编码失败，请重试。"
            case .stillFailed: return "实况照片封面生成失败，请重试。"
            }
        }
    }

    /// Writes `photoURL` (HEIC, JPEG fallback) for a Live Photo with the given asset identifier.
    static func writeStill(_ image: CGImage, identifier: String, to directory: URL) throws -> URL {
        let properties: [CFString: Any] = [
            kCGImagePropertyMakerAppleDictionary: ["17": identifier],
            kCGImageDestinationLossyCompressionQuality: 0.92,
        ]
        for (type, ext) in [(UTType.heic, "heic"), (UTType.jpeg, "jpg")] {
            let url = directory.appendingPathComponent("still.\(ext)")
            guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
                continue
            }
            CGImageDestinationAddImage(destination, image, properties as CFDictionary)
            if CGImageDestinationFinalize(destination) { return url }
            try? FileManager.default.removeItem(at: url)
        }
        throw ExportError.stillFailed
    }

    static func saveToPhotos(photoURL: URL, videoURL: URL) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { throw ExportError.photosDenied }
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            let options = PHAssetResourceCreationOptions()
            options.shouldMoveFile = true
            request.addResource(with: .photo, fileURL: photoURL, options: options)
            request.addResource(with: .pairedVideo, fileURL: videoURL, options: options)
        }
    }

    /// BGRA8 shared texture → CGImage (sRGB bytes, as rendered).
    static func makeImage(_ texture: MTLTexture) -> CGImage? {
        let width = texture.width, height = texture.height, rowBytes = width * 4
        var bytes = Data(count: rowBytes * height)
        bytes.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            texture.getBytes(base, bytesPerRow: rowBytes, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }
        guard let provider = CGDataProvider(data: bytes as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: rowBytes,
                       space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue
                                                | CGImageAlphaInfo.noneSkipFirst.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

/// QuickTime movie with the metadata Photos needs to pair it with a still as a Live Photo:
/// `com.apple.quicktime.content.identifier` and a timed `still-image-time` marker.
final class LivePhotoMovieWriter {
    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let metadataInput: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let fps: Int32
    private let width: Int
    private let height: Int

    init(url: URL, width: Int, height: Int, fps: Int32, identifier: String, stillFrame: Int) throws {
        self.fps = fps
        self.width = width
        self.height = height
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let contentIdentifier = AVMutableMetadataItem()
        contentIdentifier.keySpace = .quickTimeMetadata
        contentIdentifier.key = "com.apple.quicktime.content.identifier" as NSString
        contentIdentifier.value = identifier as NSString
        contentIdentifier.dataType = kCMMetadataBaseDataType_UTF8 as String
        writer.metadata = [contentIdentifier]

        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 12_000_000],
        ])
        videoInput.expectsMediaDataInRealTime = false
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ])

        let specification: NSDictionary = [
            kCMMetadataFormatDescriptionMetadataSpecificationKey_Identifier: "mdta/com.apple.quicktime.still-image-time",
            kCMMetadataFormatDescriptionMetadataSpecificationKey_DataType: "com.apple.metadata.datatype.int8",
        ]
        var description: CMFormatDescription?
        CMMetadataFormatDescriptionCreateWithMetadataSpecifications(allocator: kCFAllocatorDefault,
            metadataType: kCMMetadataFormatType_Boxed, metadataSpecifications: [specification] as CFArray,
            formatDescriptionOut: &description)
        metadataInput = AVAssetWriterInput(mediaType: .metadata, outputSettings: nil, sourceFormatHint: description)
        let metadataAdaptor = AVAssetWriterInputMetadataAdaptor(assetWriterInput: metadataInput)

        guard writer.canAdd(videoInput), writer.canAdd(metadataInput) else { throw LivePhotoExport.ExportError.writerFailed }
        writer.add(videoInput)
        writer.add(metadataInput)
        guard writer.startWriting() else { throw writer.error ?? LivePhotoExport.ExportError.writerFailed }
        writer.startSession(atSourceTime: .zero)

        let still = AVMutableMetadataItem()
        still.keySpace = .quickTimeMetadata
        still.key = "com.apple.quicktime.still-image-time" as NSString
        still.value = 0 as NSNumber
        still.dataType = "com.apple.metadata.datatype.int8"
        let stillTime = CMTime(value: CMTimeValue(stillFrame), timescale: fps)
        let group = AVTimedMetadataGroup(items: [still],
            timeRange: CMTimeRange(start: stillTime, duration: CMTime(value: 1, timescale: fps)))
        guard metadataAdaptor.append(group) else { throw writer.error ?? LivePhotoExport.ExportError.writerFailed }
        metadataInput.markAsFinished()
    }

    func append(_ texture: MTLTexture, frame: Int) async throws {
        while !videoInput.isReadyForMoreMediaData {
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
        videoInput.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? LivePhotoExport.ExportError.writerFailed }
    }

    func cancel() { writer.cancelWriting() }
}

/// Drives one export from the viewer and reports progress for its overlay.
@MainActor
final class LivePhotoExportController: ObservableObject {
    enum Phase: Equatable {
        case idle
        case rendering(Double)
        case saving
        case saved
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    weak var renderer: PocketSplatRenderer?
    private var task: Task<Void, Never>?

    var isBusy: Bool {
        switch phase {
        case .rendering, .saving: return true
        default: return false
        }
    }

    func start(center: OrbitPose, yawRange: ClosedRange<Float>?) {
        guard !isBusy, let renderer else { return }
        phase = .rendering(0)
        task = Task { [weak self] in
            await self?.run(renderer: renderer, center: center, yawRange: yawRange)
        }
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

    private func run(renderer: PocketSplatRenderer, center: OrbitPose, yawRange: ClosedRange<Float>?) async {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("livephoto-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let identifier = UUID().uuidString
            let frameCount = Int(LivePhotoExport.durationSeconds * Double(LivePhotoExport.fps))
            let stillIndex = LivePhotoExport.stillFrameIndex(frameCount: frameCount)
            let videoURL = directory.appendingPathComponent("motion.mov")
            let writer = try LivePhotoMovieWriter(url: videoURL, width: LivePhotoExport.width,
                height: LivePhotoExport.height, fps: LivePhotoExport.fps,
                identifier: identifier, stillFrame: stillIndex)
            var still: CGImage?
            do {
                try await renderer.renderClip(
                    poses: LivePhotoExport.orbitPoses(center: center, yawRange: yawRange, frameCount: frameCount),
                    width: LivePhotoExport.width, height: LivePhotoExport.height,
                    progress: { [weak self] value in self?.phase = .rendering(value) },
                    deliver: { texture, index in
                        if index == stillIndex { still = LivePhotoExport.makeImage(texture) }
                        try await writer.append(texture, frame: index)
                    })
                try await writer.finish()
            } catch {
                writer.cancel()
                throw error
            }
            guard let still else { throw LivePhotoExport.ExportError.stillFailed }
            phase = .saving
            let photoURL = try LivePhotoExport.writeStill(still, identifier: identifier, to: directory)
            try await LivePhotoExport.saveToPhotos(photoURL: photoURL, videoURL: videoURL)
            phase = .saved
        } catch is CancellationError {
            phase = .idle
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }
}
