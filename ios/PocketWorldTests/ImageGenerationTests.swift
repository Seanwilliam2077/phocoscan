import XCTest
import SplatIO
import UIKit
import ImageIO
import UniformTypeIdentifiers
@testable import PocketWorld

final class ImageGenerationTests: XCTestCase {
    func testFailedDeliveryIsRecoverableWithoutOfferingAnotherGeneration() {
        var image = ImageGeneration(id: UUID().uuidString, sha256: String(repeating: "a", count: 64),
                                    byteSize: 64, status: "failed", sourceKind: "ai_single_image", createdAt: "2026-11-10")
        image.errorCode = "invalid_result"
        XCTAssertTrue(image.needsDeliveryRecovery)
        XCTAssertFalse(image.statusLabel.contains("重新生成"))
        image.status = "processing"; image.phase = "exporting"; image.progress = 99
        XCTAssertEqual(image.statusLabel, "生成完成 · 正在准备结果")
        image.status = "failed"; image.errorCode = "server_busy"
        XCTAssertFalse(image.needsDeliveryRecovery)
    }

    @MainActor
    func testCameraPhotoRotatesIntoUprightPixelsAndBoundsResolution() throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let raw = UIGraphicsImageRenderer(size: CGSize(width: 3000, height: 1500), format: format).image { context in
            UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: 3000, height: 1500))
        }
        for orientation: UIImage.Orientation in [.right, .left, .rightMirrored, .leftMirrored] {
            let photo = UIImage(cgImage: try XCTUnwrap(raw.cgImage), scale: 2, orientation: orientation)
            let jpeg = try ImageGenerationStore.normalizedJPEG(photo)
            let decoded = try XCTUnwrap(UIImage(data: jpeg))
            XCTAssertEqual(decoded.imageOrientation, .up)
            XCTAssertEqual(decoded.cgImage?.width, 1024)
            XCTAssertEqual(decoded.cgImage?.height, 2048)
        }
        XCTAssertThrowsError(try ImageGenerationStore.normalizedJPEG(UIImage()))
    }

    @MainActor
    func testPhotoImportStripsLocationAndCameraMetadata() throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let raw = UIGraphicsImageRenderer(size: CGSize(width: 80, height: 60), format: format).image { context in
            UIColor.blue.setFill(); context.fill(CGRect(x: 0, y: 0, width: 80, height: 60))
        }
        let bytes = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(bytes, UTType.jpeg.identifier as CFString, 1, nil))
        let metadata: [String: Any] = [
            kCGImagePropertyGPSDictionary as String: [kCGImagePropertyGPSLatitude as String: 0, kCGImagePropertyGPSLatitudeRef as String: "N",
                                                     kCGImagePropertyGPSLongitude as String: 0, kCGImagePropertyGPSLongitudeRef as String: "E"],
            kCGImagePropertyExifDictionary as String: [kCGImagePropertyExifDateTimeOriginal as String: "2000:01:01 00:00:00"],
            kCGImagePropertyTIFFDictionary as String: [kCGImagePropertyTIFFMake as String: "Synthetic camera"]
        ]
        CGImageDestinationAddImage(destination, try XCTUnwrap(raw.cgImage), metadata as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        func properties(_ data: Data) throws -> [String: Any] {
            let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
            return try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
        }
        XCTAssertNotNil(try properties(bytes as Data)[kCGImagePropertyGPSDictionary as String])
        let sanitized = try ImageGenerationStore.normalizedJPEG(XCTUnwrap(UIImage(data: bytes as Data)))
        let output = try properties(sanitized)
        XCTAssertNil(output[kCGImagePropertyGPSDictionary as String])
        XCTAssertNil((output[kCGImagePropertyExifDictionary as String] as? [String: Any])?[kCGImagePropertyExifDateTimeOriginal as String])
        XCTAssertNil((output[kCGImagePropertyTIFFDictionary as String] as? [String: Any])?[kCGImagePropertyTIFFMake as String])
    }

    /// Four synthetic SH3 Gaussians encoded by the deployed Linux converter.
    /// This exercises the real iOS reader, including its RUB -> RDF conversion.
    func testServerSPZPreservesCoordinatesAndAllSHBandsInTheMobileReader() async throws {
        let bytes = try XCTUnwrap(Data(base64Encoded: "H4sIAAAAAAAAA/NzDw5gZmBgYAFiZh4GBmNmBuPf/xkEGDxYGQp//p8lyBDDzrDu+39jYYZCToY3X/+fFWF4CATN7d1wVIAEgMYcQMYN9bX1tTXNLa011VWtbR1tHQ0VDfUNjc1wweqqCrjgIFEMALlkRoIUAQAA"))
        let points = try await SPZSceneReader(bytes).readAll()
        XCTAssertEqual(points.count, 4)
        for (i, point) in points.enumerated() {
            XCTAssertEqual(point.position.x, 0.2 + Float(i) * 0.13, accuracy: 0.002)
            XCTAssertEqual(point.position.y, 0.3 + Float(i) * 0.11, accuracy: 0.002)
            XCTAssertEqual(point.position.z, -1 - Float(i) * 0.1, accuracy: 0.002)
            XCTAssertEqual(point.color.shDegree, .sh3)
            let sh = point.color.asSphericalHarmonicFloat
            XCTAssertEqual(sh.count, 16)
            for channel in 0..<3 {
                XCTAssertEqual(sh[0][channel], Float(channel + 1) * 0.1, accuracy: 0.02)
                for band in 1..<16 {
                    XCTAssertEqual(sh[band][channel], Float((channel * 15 + band - 1) % 7) * 0.01, accuracy: 0.01)
                }
            }
            XCTAssertEqual(point.opacity.asLogitFloat, 2, accuracy: 0.04)
            XCTAssertEqual(abs(point.rotation.real), 1, accuracy: 0.001)
        }
    }
    func testSingleImageNeverClaimsMeasuredSourceAndRejectsForeignResultPaths() throws {
        let id=UUID().uuidString.lowercased(), hash=String(repeating:"a",count:64)
        var json:[String:Any] = ["id":id,"sha256":hash,"byteSize":64,"status":"ready","sourceKind":"ai_single_image","createdAt":"2026-11-10T00:00:00Z"]
        func file(_ kind:String)->[String:Any]{["path":"/v2/image-generations/\(id)/result/\(kind)","sha256":hash,"byteSize":128]}
        var result:[String:Any] = ["ply":file("ply"),"spz":file("spz"),"pointCount":100,"sourceImageSha256":hash,"algorithm":"triposplat","provenance":"ai_single_image","metricScaleVerified":false]
        func decode() throws -> ImageGeneration { try JSONDecoder().decode(ImageGeneration.self,from:JSONSerialization.data(withJSONObject:json)) }
        json["result"]=result; XCTAssertNoThrow(try decode().validate())
        result["metricScaleVerified"]=true;json["result"]=result;XCTAssertThrowsError(try decode().validate())
        result["metricScaleVerified"]=false;result["spz"]=["path":"https://example.invalid/model.spz","sha256":hash,"byteSize":128];json["result"]=result;XCTAssertThrowsError(try decode().validate())
    }
    func testPredictionHintIsOnlyABoundedPresentationPose() {
        let hint=ImageGeneration.Hint(center:[0,0,0],first_camera_to_world:[[1,0,0,1],[0,1,0,0],[0,0,1,0],[0,0,0,1]])
        XCTAssertEqual(hint.presentation!.yaw,-Float.pi/2,accuracy:1e-6)
        XCTAssertNil(ImageGeneration.Hint(center:[],first_camera_to_world:[]).presentation)
    }
}
