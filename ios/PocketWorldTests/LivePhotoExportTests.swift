import AVFoundation
import ImageIO
import MetalKit
import XCTest
@testable import PocketWorld

/// Live Photo export: pose planning (pure) and an end-to-end render of a small synthetic Gaussian
/// model through the real Metal renderer into a paired movie + still. Saving to Photos needs the
/// system permission prompt and is checked on a device, not here.
@MainActor
final class LivePhotoExportTests: XCTestCase {
    // MARK: - Pose planning

    func testOrbitLoopStartsAndEndsAtTheCurrentView() {
        let center = OrbitPose(yaw: 0.2, pitch: 0.1, distanceScale: 1.3, panOffset: SIMD2(0.1, 0), flipUp: false)
        let poses = LivePhotoExport.orbitPoses(center: center, yawRange: nil, frameCount: 90)
        XCTAssertEqual(poses.count, 90)
        XCTAssertEqual(poses[0].yaw, 0.2, accuracy: 1e-6)
        XCTAssertEqual(poses[LivePhotoExport.stillFrameIndex(frameCount: 90)].yaw, 0.2, accuracy: 1e-5)
        XCTAssertEqual(poses.map(\.yaw).max()!, 0.2 + LivePhotoExport.swing, accuracy: 1e-3)
        // Only yaw moves; the rest of the user's view is kept.
        XCTAssertTrue(poses.allSatisfy { $0.pitch == 0.1 && $0.distanceScale == 1.3 && $0.panOffset == SIMD2(0.1, 0) })
    }

    func testOrbitLoopStaysInsideTheCapturedRange() {
        let center = OrbitPose(yaw: 0, pitch: 0, distanceScale: 1, panOffset: .zero, flipUp: false)
        let range: ClosedRange<Float> = -0.1...0.4
        let poses = LivePhotoExport.orbitPoses(center: center, yawRange: range, frameCount: 90)
        XCTAssertTrue(poses.allSatisfy { range.lowerBound - 1e-5 <= $0.yaw && $0.yaw <= range.upperBound + 1e-5 })
    }

    // MARK: - End-to-end render

    /// A small standard-layout 3DGS PLY: a sphere of opaque, normal-coloured splats at the origin.
    private func writeSyntheticModel(count: Int, to directory: URL) throws -> URL {
        let names = ["x", "y", "z", "f_dc_0", "f_dc_1", "f_dc_2", "opacity",
                     "scale_0", "scale_1", "scale_2", "rot_0", "rot_1", "rot_2", "rot_3"]
        var data = Data(("ply\nformat binary_little_endian 1.0\nelement vertex \(count)\n"
            + names.map { "property float \($0)\n" }.joined() + "end_header\n").utf8)
        let c0: Float = 0.28209479177387814
        for i in 0..<count {
            // Fibonacci sphere, radius 0.5.
            let y = 1 - 2 * (Float(i) + 0.5) / Float(count)
            let r = (1 - y * y).squareRoot()
            let phi = Float(i) * 2.399963
            let n = SIMD3(r * cos(phi), y, r * sin(phi))
            let colour = (n + 1) / 2
            var values: [Float] = [n.x * 0.5, n.y * 0.5, n.z * 0.5,
                                   (colour.x - 0.5) / c0, (colour.y - 0.5) / c0, (colour.z - 0.5) / c0,
                                   4, log(0.02), log(0.02), log(0.02), 1, 0, 0, 0]
            data.append(Data(bytes: &values, count: values.count * 4))
        }
        let url = directory.appendingPathComponent("synthetic.ply")
        try data.write(to: url)
        return url
    }

    func testRendersTheLoadedModelIntoAPairedMovieAndStill() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let view = MTKView(frame: CGRect(x: 0, y: 0, width: 120, height: 200), device: device)
        view.colorPixelFormat = .bgra8Unorm_srgb
        view.depthStencilPixelFormat = .depth32Float
        view.isPaused = true
        let status = GaussianViewerStatus()
        let renderer = try PocketSplatRenderer(view: view, status: status, screenScale: 2)
        let model = try writeSyntheticModel(count: 4000, to: directory)
        await renderer.load(url: model)
        XCTAssertNil(status.error)
        XCTAssertEqual(status.loadedPoints, 4000)

        let identifier = UUID().uuidString
        let frames = 12, still = LivePhotoExport.stillFrameIndex(frameCount: frames)
        let movie = directory.appendingPathComponent("motion.mov")
        let writer = try LivePhotoMovieWriter(url: movie, width: 270, height: 480, fps: 30,
                                              identifier: identifier, stillFrame: still)
        var stillImage: CGImage?
        var progress: [Double] = []
        let center = OrbitPose(yaw: 0, pitch: 0, distanceScale: 1, panOffset: .zero, flipUp: false)
        try await renderer.renderClip(
            poses: LivePhotoExport.orbitPoses(center: center, yawRange: nil, frameCount: frames),
            width: 270, height: 480, progress: { progress.append($0) },
            deliver: { texture, index in
                if index == still { stillImage = LivePhotoExport.makeImage(texture) }
                try await writer.append(texture, frame: index)
            })
        try await writer.finish()
        XCTAssertEqual(progress.last ?? 0, 1, accuracy: 1e-9)

        // The movie carries the pairing identifier, a still-image-time track and every frame.
        let asset = AVURLAsset(url: movie)
        let duration = try await asset.load(.duration)
        XCTAssertEqual(duration.seconds, Double(frames) / 30, accuracy: 0.05)
        let items = try await asset.load(.metadata)
        var identifiers: [String] = []
        for item in items where item.identifier?.rawValue.hasSuffix("com.apple.quicktime.content.identifier") == true {
            if let value = try await item.load(.stringValue) { identifiers.append(value) }
        }
        XCTAssertEqual(identifiers, [identifier])
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let metadataTracks = try await asset.loadTracks(withMediaType: .metadata)
        XCTAssertEqual(videoTracks.count, 1)
        XCTAssertEqual(metadataTracks.count, 1)

        // The still is a real render (the sphere fills the centre), tagged with the same identifier.
        let image = try XCTUnwrap(stillImage)
        XCTAssertGreaterThan(Self.centreBrightness(image), 0.1)
        let photo = try LivePhotoExport.writeStill(image, identifier: identifier, to: directory)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(photo as CFURL, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        let maker = try XCTUnwrap(properties[kCGImagePropertyMakerAppleDictionary] as? [String: Any])
        XCTAssertEqual(maker["17"] as? String, identifier)
    }

    private static func centreBrightness(_ image: CGImage) -> Double {
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        context?.draw(image, in: CGRect(x: -Double(image.width) / 2 + 0.5, y: -Double(image.height) / 2 + 0.5,
                                        width: Double(image.width), height: Double(image.height)))
        return Double(Int(pixel[0]) + Int(pixel[1]) + Int(pixel[2])) / (3 * 255)
    }
}
