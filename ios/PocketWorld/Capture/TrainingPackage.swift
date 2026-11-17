import Accelerate
import ARKit
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision
import simd

/// The nerfstudio-compatible training package written next to each scan
/// (`<id>.scan/capture/`), from the same ARSession as `video.mov` and `frames.jsonl`:
///
///     transforms.json   fl_x, fl_y, cx, cy, w, h, frames[{file_path, transform_matrix,
///                       depth_file_path?, mask_path?}], ply_file_path?
///     images/*.jpg      keyframes, sensor orientation (landscape), not rotated
///     depth/*.png       16-bit millimeters (0 = no depth); confidence/*.png 0/1/2
///     masks/*.png       person mode only: coarse on-device person segmentation
///     points3d.ply      LiDAR points of the keyframes, voxel-downsampled, colored
///     meta.json         device, mode, rig, target, exposure lock, flagged frames
///
/// Poses are ARKit camera-to-world matrices, which already use the nerfstudio/OpenGL
/// camera convention (looking down -Z, +Y up). Nothing here is a reconstruction.
final class TrainingPackageWriter {
    static let folderName = "capture"
    /// In-flight keyframes (each holds one camera buffer); more are skipped, never queued.
    static let maxInFlight = 2

    struct FrameEntry {
        let index: Int
        let image: String
        let depth: String?
        let confidence: String?
        let mask: String?
        let transform: simd_float4x4
        let intrinsics: simd_float3x3
        let width: Int
        let height: Int
        let timestamp: Double
        let sharpness: Float
        let subjectMoving: Bool
    }

    let root: URL
    let mode: ScanMode
    private let ioQueue = DispatchQueue(label: "world.pocket.package.io", qos: .utility)
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let lock = NSLock()
    private var savedCount = 0
    private var savedMovingCount = 0
    private var inFlight = 0            // lock
    private var entries: [FrameEntry] = [] // caller queue
    private var failed = Set<Int>()     // ioQueue
    private var missingDepth = Set<Int>() // ioQueue
    private var missingMask = Set<Int>()  // ioQueue
    private(set) var skippedBusy = 0    // caller queue
    private var cloud = PointCloudAccumulator(voxel: 0.01) // caller queue
    private var depthSize: (Int, Int)?

    init(root: URL, mode: ScanMode) throws {
        self.root = root.appendingPathComponent(Self.folderName, isDirectory: true)
        self.mode = mode
        for folder in ["images", "depth", "confidence"] + (mode == .portrait ? ["masks"] : []) {
            try FileManager.default.createDirectory(at: self.root.appendingPathComponent(folder, isDirectory: true),
                                                    withIntermediateDirectories: true)
        }
        cloud = PointCloudAccumulator(voxel: mode == .space ? 0.02 : 0.01)
    }

    var keyframeCount: Int { lock.lock(); defer { lock.unlock() }; return savedCount }
    var movingCount: Int { lock.lock(); defer { lock.unlock() }; return savedMovingCount }
    var canAccept: Bool {
        lock.lock(); defer { lock.unlock() }
        return inFlight < Self.maxInFlight
    }

    /// Queues one keyframe. Called on the capture queue; pixel work happens on `ioQueue`.
    func add(frame: ARFrame, sharpness: Float, subjectMoving: Bool, onSaved: @escaping () -> Void = {}) -> Bool {
        lock.lock()
        guard inFlight < Self.maxInFlight else { lock.unlock(); skippedBusy += 1; return false }
        inFlight += 1
        lock.unlock()

        let index = entries.count + 1
        let name = String(format: "frame_%05d", index)
        let image = frame.capturedImage
        let width = CVPixelBufferGetWidth(image), height = CVPixelBufferGetHeight(image)
        var depthCopy: (meters: [Float], confidence: [UInt8]?, width: Int, height: Int)?
        if let scene = frame.sceneDepth, let copy = Self.copyDepth(scene) {
            depthCopy = copy
            depthSize = (copy.width, copy.height)
            cloud.add(depth: copy.meters, confidence: copy.confidence, width: copy.width, height: copy.height,
                      image: image, intrinsics: frame.camera.intrinsics,
                      imageResolution: frame.camera.imageResolution, cameraToWorld: frame.camera.transform)
        }
        let portrait = mode == .portrait
        entries.append(FrameEntry(
            index: index, image: "images/\(name).jpg",
            depth: depthCopy == nil ? nil : "depth/\(name).png",
            confidence: depthCopy?.confidence == nil ? nil : "confidence/\(name).png",
            mask: portrait ? "masks/\(name).png" : nil,
            transform: frame.camera.transform, intrinsics: frame.camera.intrinsics,
            width: width, height: height, timestamp: frame.timestamp,
            sharpness: sharpness, subjectMoving: subjectMoving))

        ioQueue.async { [self] in
            defer { lock.lock(); inFlight -= 1; lock.unlock() }
            let jpeg = context.jpegRepresentation(
                of: CIImage(cvPixelBuffer: image), colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.92])
            guard let jpeg, (try? jpeg.write(to: root.appendingPathComponent("images/\(name).jpg"), options: .atomic)) != nil else {
                failed.insert(index)
                return
            }
            lock.lock(); savedCount += 1; if subjectMoving { savedMovingCount += 1 }; lock.unlock()
            onSaved()
            if let depthCopy {
                let millimeters = depthCopy.meters.map { d -> UInt16 in
                    guard d.isFinite, d > 0 else { return 0 }
                    return UInt16(min(65535, (d * 1000).rounded()))
                }
                let wroteDepth = Self.writePNG16(millimeters, width: depthCopy.width, height: depthCopy.height,
                                                 to: root.appendingPathComponent("depth/\(name).png"))
                if !wroteDepth { missingDepth.insert(index) }
                if let confidence = depthCopy.confidence {
                    _ = Self.writePNG8(confidence, width: depthCopy.width, height: depthCopy.height,
                                       to: root.appendingPathComponent("confidence/\(name).png"))
                }
            }
            if portrait {
                let mask = Self.personMask(image, width: width, height: height)
                if mask == nil || !Self.writePNG8(mask!, width: width, height: height,
                                                  to: root.appendingPathComponent("masks/\(name).png")) {
                    missingMask.insert(index)
                }
            }
        }
        return true
    }

    /// Drain all writes before capture analysis snapshots the saved-frame coverage.
    func drain(_ completion: @escaping () -> Void) { ioQueue.async(execute: completion) }

    /// Writes transforms.json, meta.json and points3d.ply after every queued keyframe
    /// has been written, then calls `completion` (on the io queue). Never throws: the
    /// package is an addition to the scan and must not block saving it.
    func finish(meta: [String: Any], completion: @escaping () -> Void) {
        let entries = self.entries
        let points = cloud.points()
        let skippedBusy = self.skippedBusy
        let depthSize = self.depthSize
        ioQueue.async { [self] in
            let kept = entries.filter { !failed.contains($0.index) }
            var plyName: String?
            if !points.isEmpty, Self.writePLY(points, to: root.appendingPathComponent("points3d.ply")) {
                plyName = "points3d.ply"
            }
            var transforms: [String: Any] = ["camera_model": "OPENCV", "k1": 0, "k2": 0, "p1": 0, "p2": 0]
            if let first = kept.first {
                let k = first.intrinsics
                transforms["fl_x"] = k[0][0]; transforms["fl_y"] = k[1][1]
                transforms["cx"] = k[2][0]; transforms["cy"] = k[2][1]
                transforms["w"] = first.width; transforms["h"] = first.height
            }
            if let plyName { transforms["ply_file_path"] = plyName }
            transforms["frames"] = kept.map { entry -> [String: Any] in
                let k = entry.intrinsics
                var frame: [String: Any] = [
                    "file_path": entry.image,
                    "transform_matrix": Self.rows(entry.transform),
                    "fl_x": k[0][0], "fl_y": k[1][1], "cx": k[2][0], "cy": k[2][1],
                    "w": entry.width, "h": entry.height,
                    "timestamp": entry.timestamp, "sharpness": entry.sharpness
                ]
                if let depth = entry.depth, !missingDepth.contains(entry.index) { frame["depth_file_path"] = depth }
                if let mask = entry.mask, !missingMask.contains(entry.index) { frame["mask_path"] = mask }
                if entry.subjectMoving { frame["subject_moving"] = true }
                return frame
            }
            var info = meta
            info["schema"] = "phocoscan-capture/1"
            info["mode"] = Self.planMode(mode)
            info["coordinate_convention"] = "transform_matrix is the ARKit camera-to-world pose (row-major 4×4), world gravity-aligned, meters; camera looks down -Z with +Y up and +X right of the stored image, i.e. the nerfstudio/OpenGL convention. Images are stored in sensor orientation (landscape), unrotated; intrinsics are in those pixels. Lens distortion is not modeled (ARKit provides pinhole intrinsics)."
            var keyframes = (info["keyframes"] as? [String: Any]) ?? [:]
            keyframes["count"] = kept.count
            keyframes["write_failures"] = entries.count - kept.count
            keyframes["skipped_busy"] = skippedBusy
            info["keyframes"] = keyframes
            info["moving_frames"] = kept.filter(\.subjectMoving).map(\.image)
            if let depthSize {
                info["depth"] = ["unit": "millimeter", "format": "16-bit grayscale PNG, 0 = no depth",
                                 "width": depthSize.0, "height": depthSize.1, "depth_unit_scale_factor": 0.001,
                                 "confidence": "8-bit PNG, ARKit 0 low / 1 medium / 2 high"] as [String: Any]
            } else {
                info["depth"] = NSNull()
            }
            info["masks"] = mode == .portrait
                ? "coarse on-device person segmentation (Vision), 255 = person, 0 = background; refine before training" as Any
                : NSNull()
            info["points3d"] = plyName.map { ["file": $0, "points": points.count,
                                              "voxel_m": mode == .space ? 0.02 : 0.01,
                                              "source": "LiDAR depth of the keyframes (confidence ≥ medium)"] as [String: Any] }
                ?? NSNull()
            Self.writeJSON(transforms, to: root.appendingPathComponent("transforms.json"))
            Self.writeJSON(info, to: root.appendingPathComponent("meta.json"))
            completion()
        }
    }

    /// The plan's mode names: object / room / person.
    static func planMode(_ mode: ScanMode) -> String {
        switch mode {
        case .object: return "object"
        case .space: return "room"
        case .portrait: return "person"
        }
    }

    // MARK: Helpers

    static func rows(_ m: simd_float4x4) -> [[Float]] {
        (0..<4).map { row in (0..<4).map { column in m[column][row] } }
    }

    private static func copyDepth(_ scene: ARDepthData) -> (meters: [Float], confidence: [UInt8]?, width: Int, height: Int)? {
        let map = scene.depthMap
        guard CVPixelBufferGetPixelFormatType(map) == kCVPixelFormatType_DepthFloat32 else { return nil }
        let width = CVPixelBufferGetWidth(map), height = CVPixelBufferGetHeight(map)
        CVPixelBufferLockBaseAddress(map, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(map, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(map) else { return nil }
        let rowBytes = CVPixelBufferGetBytesPerRow(map)
        var meters = [Float](repeating: 0, count: width * height)
        for y in 0..<height {
            let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: Float32.self)
            for x in 0..<width { meters[y * width + x] = row[x] }
        }
        var confidence: [UInt8]?
        if let c = scene.confidenceMap, CVPixelBufferGetWidth(c) == width, CVPixelBufferGetHeight(c) == height,
           CVPixelBufferGetPixelFormatType(c) == kCVPixelFormatType_OneComponent8 {
            CVPixelBufferLockBaseAddress(c, .readOnly)
            if let cBase = CVPixelBufferGetBaseAddress(c) {
                let cRow = CVPixelBufferGetBytesPerRow(c)
                var values = [UInt8](repeating: 0, count: width * height)
                for y in 0..<height {
                    let row = cBase.advanced(by: y * cRow).assumingMemoryBound(to: UInt8.self)
                    for x in 0..<width { values[y * width + x] = row[x] }
                }
                confidence = values
            }
            CVPixelBufferUnlockBaseAddress(c, .readOnly)
        }
        return (meters, confidence, width, height)
    }

    /// Person mask at the full image size, in sensor orientation. Vision runs on the
    /// upright view (`.right`); a portrait-shaped result is rotated back.
    static func personMask(_ image: CVPixelBuffer, width: Int, height: Int) -> [UInt8]? {
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .balanced
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        let handler = VNImageRequestHandler(cvPixelBuffer: image, orientation: .right)
        guard (try? handler.perform([request])) != nil,
              let mask = request.results?.first?.pixelBuffer else { return nil }
        CVPixelBufferLockBaseAddress(mask, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(mask, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(mask) else { return nil }
        let mw = CVPixelBufferGetWidth(mask), mh = CVPixelBufferGetHeight(mask)
        var source = vImage_Buffer(data: base, height: vImagePixelCount(mh), width: vImagePixelCount(mw),
                                   rowBytes: CVPixelBufferGetBytesPerRow(mask))
        var rotated = [UInt8]()
        var sensorW = mw, sensorH = mh
        if mh > mw { // upright (portrait) result: rotate 90° counter-clockwise back to the sensor
            sensorW = mh; sensorH = mw
            rotated = [UInt8](repeating: 0, count: sensorW * sensorH)
            let ok = rotated.withUnsafeMutableBytes { raw -> Bool in
                var destination = vImage_Buffer(data: raw.baseAddress, height: vImagePixelCount(sensorH),
                                                width: vImagePixelCount(sensorW), rowBytes: sensorW)
                return vImageRotate90_Planar8(&source, &destination, UInt8(kRotate90DegreesCounterClockwise), 0,
                                              vImage_Flags(kvImageNoFlags)) == kvImageNoError
            }
            guard ok else { return nil }
        } else {
            rotated = [UInt8](repeating: 0, count: mw * mh)
            rotated.withUnsafeMutableBytes { raw in
                for y in 0..<mh {
                    memcpy(raw.baseAddress!.advanced(by: y * mw), base.advanced(by: y * source.rowBytes), mw)
                }
            }
        }
        var output = [UInt8](repeating: 0, count: width * height)
        let scaled = rotated.withUnsafeMutableBytes { input -> Bool in
            output.withUnsafeMutableBytes { out -> Bool in
                var from = vImage_Buffer(data: input.baseAddress, height: vImagePixelCount(sensorH),
                                         width: vImagePixelCount(sensorW), rowBytes: sensorW)
                var to = vImage_Buffer(data: out.baseAddress, height: vImagePixelCount(height),
                                       width: vImagePixelCount(width), rowBytes: width)
                return vImageScale_Planar8(&from, &to, nil, vImage_Flags(kvImageNoFlags)) == kvImageNoError
            }
        }
        guard scaled else { return nil }
        // Generous threshold: hair edges stay in; the cloud refines the mask.
        return output.map { $0 > 40 ? 255 : 0 }
    }

    @discardableResult
    static func writePNG16(_ values: [UInt16], width: Int, height: Int, to url: URL) -> Bool {
        guard values.count == width * height else { return false }
        let data = values.withUnsafeBytes { Data($0) } // little-endian
        guard let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 16, bitsPerPixel: 16,
                                  bytesPerRow: width * 2, space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue
                                                           | CGBitmapInfo.byteOrder16Little.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { return false }
        return writePNG(image, to: url)
    }

    @discardableResult
    static func writePNG8(_ values: [UInt8], width: Int, height: Int, to url: URL) -> Bool {
        guard values.count == width * height,
              let provider = CGDataProvider(data: Data(values) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8,
                                  bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { return false }
        return writePNG(image, to: url)
    }

    private static func writePNG(_ image: CGImage, to url: URL) -> Bool {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { return false }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination)
    }

    /// Binary little-endian PLY: float x, y, z and uchar red, green, blue.
    @discardableResult
    static func writePLY(_ points: [(position: SIMD3<Float>, color: SIMD3<UInt8>)], to url: URL) -> Bool {
        var data = Data("""
        ply
        format binary_little_endian 1.0
        comment phocoscan LiDAR keyframe points, ARKit world frame, meters
        element vertex \(points.count)
        property float x
        property float y
        property float z
        property uchar red
        property uchar green
        property uchar blue
        end_header

        """.utf8)
        data.reserveCapacity(data.count + points.count * 15)
        for point in points {
            var xyz = [point.position.x, point.position.y, point.position.z]
            xyz.withUnsafeBytes { data.append(contentsOf: $0) }
            data.append(contentsOf: [point.color.x, point.color.y, point.color.z])
        }
        return (try? data.write(to: url, options: .atomic)) != nil
    }

    private static func writeJSON(_ object: [String: Any], to url: URL) {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        else { return }
        try? data.write(to: url, options: .atomic)
    }

    // MARK: Export

    /// Zips the package of a saved scan for sharing (Files, AirDrop, a PC). Returns a
    /// temporary .zip; the caller shares it and may delete it afterwards.
    static func exportZip(scanFolder: URL, name: String) throws -> URL {
        let package = scanFolder.appendingPathComponent(folderName, isDirectory: true)
        guard FileManager.default.fileExists(atPath: package.appendingPathComponent("transforms.json").path) else {
            throw ExportError.missing
        }
        let exportRoot = FileManager.default.temporaryDirectory.appendingPathComponent("PackageExport", isDirectory: true)
        try? FileManager.default.removeItem(at: exportRoot) // one export at a time; old zips are dropped
        try FileManager.default.createDirectory(at: exportRoot, withIntermediateDirectories: true)
        let destination = exportRoot.appendingPathComponent(name + ".zip")
        var coordinationError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: package, options: .forUploading, error: &coordinationError) { zip in
            do { try FileManager.default.copyItem(at: zip, to: destination) } catch { copyError = error }
        }
        if let error = coordinationError ?? copyError { throw error }
        return destination
    }

    enum ExportError: LocalizedError {
        case missing
        var errorDescription: String? { "这次扫描没有训练数据包（更新前录制的扫描没有）。" }
    }
}

/// LiDAR points averaged per voxel, colored from the camera image. Caller's queue only.
struct PointCloudAccumulator {
    static let stride = 4
    static let maxCells = 400_000
    let voxel: Float
    private var cells: [SIMD3<Int32>: (sum: SIMD3<Float>, color: SIMD3<Float>, count: Float)] = [:]

    init(voxel: Float) { self.voxel = voxel }

    var count: Int { cells.count }

    mutating func add(depth: [Float], confidence: [UInt8]?, width: Int, height: Int,
                      image: CVPixelBuffer, intrinsics k: simd_float3x3, imageResolution: CGSize,
                      cameraToWorld: simd_float4x4) {
        guard cells.count < Self.maxCells, imageResolution.width > 0, imageResolution.height > 0,
              CVPixelBufferGetPlaneCount(image) == 2 else { return }
        let sx = Float(width) / Float(imageResolution.width), sy = Float(height) / Float(imageResolution.height)
        let fx = k[0][0] * sx, fy = k[1][1] * sy, cx = k[2][0] * sx, cy = k[2][1] * sy
        guard fx > 0, fy > 0 else { return }
        CVPixelBufferLockBaseAddress(image, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(image, .readOnly) }
        guard let yPlane = CVPixelBufferGetBaseAddressOfPlane(image, 0)?.assumingMemoryBound(to: UInt8.self),
              let cPlane = CVPixelBufferGetBaseAddressOfPlane(image, 1)?.assumingMemoryBound(to: UInt8.self) else { return }
        let imageWidth = CVPixelBufferGetWidthOfPlane(image, 0), imageHeight = CVPixelBufferGetHeightOfPlane(image, 0)
        let yRow = CVPixelBufferGetBytesPerRowOfPlane(image, 0), cRow = CVPixelBufferGetBytesPerRowOfPlane(image, 1)
        let chromaWidth = CVPixelBufferGetWidthOfPlane(image, 1), chromaHeight = CVPixelBufferGetHeightOfPlane(image, 1)
        for y in Swift.stride(from: 0, to: height, by: Self.stride) {
            for x in Swift.stride(from: 0, to: width, by: Self.stride) {
                let index = y * width + x
                let d = depth[index]
                guard d.isFinite, d > 0.1, d < 5 else { continue }
                if let confidence, confidence[index] < 1 { continue }
                let local = SIMD4<Float>((Float(x) + 0.5 - cx) / fx * d, -(Float(y) + 0.5 - cy) / fy * d, -d, 1)
                let world = cameraToWorld * local
                let point = SIMD3(world.x, world.y, world.z)
                let ix = min(imageWidth - 1, Int((Float(x) + 0.5) * Float(imageWidth) / Float(width)))
                let iy = min(imageHeight - 1, Int((Float(y) + 0.5) * Float(imageHeight) / Float(height)))
                let ci = min(chromaWidth - 1, ix / 2), cj = min(chromaHeight - 1, iy / 2)
                let luma = Float(yPlane[iy * yRow + ix])
                let cb = Float(cPlane[cj * cRow + ci * 2]) - 128, cr = Float(cPlane[cj * cRow + ci * 2 + 1]) - 128
                let rgb = simd_clamp(SIMD3<Float>(luma + 1.402 * cr, luma - 0.344136 * cb - 0.714136 * cr, luma + 1.772 * cb),
                                     SIMD3(repeating: 0), SIMD3(repeating: 255))
                add(point, color: rgb)
            }
        }
    }

    mutating func add(_ point: SIMD3<Float>, color: SIMD3<Float>) {
        let key = SIMD3<Int32>(Int32((point.x / voxel).rounded(.down)), Int32((point.y / voxel).rounded(.down)),
                               Int32((point.z / voxel).rounded(.down)))
        if var cell = cells[key] {
            cell.sum += point; cell.color += color; cell.count += 1
            cells[key] = cell
        } else if cells.count < Self.maxCells {
            cells[key] = (point, color, 1)
        }
    }

    func points() -> [(position: SIMD3<Float>, color: SIMD3<UInt8>)] {
        cells.values.map { cell in
            let c = simd_clamp(cell.color / cell.count, SIMD3(repeating: 0), SIMD3(repeating: 255))
            return (cell.sum / cell.count, SIMD3(UInt8(c.x.rounded()), UInt8(c.y.rounded()), UInt8(c.z.rounded())))
        }
    }
}
