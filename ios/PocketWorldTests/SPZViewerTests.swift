import CryptoKit
import MetalKit
import SplatIO
import XCTest
import zlib
@testable import PocketWorld

@MainActor final class SPZViewerTests: XCTestCase {
    private let fixture = Data(base64Encoded:"H4sIAAAAAAAAA/NzDw5gZmBgYAFiZh4GBmNmBuPf/xkEGDxYGQp//p8lyBDDzrDu+39jYYZCToY3X/+fFWF4CATN7d1wVIAEgMYcQMYN9bX1tTXNLa011VWtbR1tHQ0VDfUNjc1wweqqCrjgIFEMALlkRoIUAQAA")!
    private func file(_ bytes: Data) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        addTeardownBlock { try? FileManager.default.removeItem(at:directory) }
        let url=directory.appendingPathComponent("scene.spz");try bytes.write(to:url);return url
    }
    func testRendererLoadsSPZThroughTheProductionEntryAndRendersPixels() async throws {
        let url = try file(fixture)
        let info = try SPZFilePreflight.inspect(url)
        XCTAssertEqual(info.pointCount,4);XCTAssertEqual(info.shDegree,3)
        let visible = try await render(url, count:4)
        XCTAssertGreaterThan(visible,0)
    }
    func testSPZRejectsCorruptTruncatedAndUnknownFiles() throws {
        XCTAssertThrowsError(try SPZFilePreflight.inspect(file(fixture.dropLast(4))))
        var corrupt=fixture;corrupt[corrupt.count-8] ^= 0xff
        XCTAssertThrowsError(try SPZFilePreflight.inspect(file(corrupt)))
        XCTAssertThrowsError(try SPZFilePreflight.inspect(file(Data("not an SPZ".utf8))))
        var trailing=fixture;trailing.append(0)
        XCTAssertThrowsError(try SPZFilePreflight.inspect(file(trailing)))
    }
    func testSPZBoundsCountsAndExpandedPayloadBeforeAllocation() throws {
        func packed(count: UInt32, version:UInt32=3, payload:Int=0) -> Data {
            var data=Data()
            for var value in [UInt32(0x5053474e),version,count] { withUnsafeBytes(of:&value) { data.append(contentsOf:$0) } }
            data.append(contentsOf:[0,12,0,0]);data.append(Data(repeating:0,count:payload));return data
        }
        XCTAssertThrowsError(try SPZFilePreflight.inspect(file(gzip(packed(count:1_000_001))))) { error in
            XCTAssertEqual(error as? SPZFilePreflight.Failure,.tooManyPoints)
        }
        XCTAssertThrowsError(try SPZFilePreflight.inspect(file(gzip(packed(count:1,version:4))))) { error in
            XCTAssertEqual(error as? SPZFilePreflight.Failure,.unsupportedVersion)
        }
        XCTAssertThrowsError(try SPZFilePreflight.inspect(file(gzip(packed(count:1,payload:1_000_000)))))
        XCTAssertThrowsError(try SPZFilePreflight.inspect(file(gzip(packed(count:1,payload:19)))))
        for version in UInt32(1)...3 {
            let stride = version == 1 ? 16 : (version == 2 ? 19 : 20)
            let info = try SPZFilePreflight.inspect(file(gzip(packed(count:10_000,version:version,payload:stride*10_000))))
            XCTAssertEqual(info.pointCount,10_000)
            XCTAssertEqual(info.expandedSize,16+stride*10_000)
        }
    }

    /// Uses only existing, hash-checked, on-phone results; no source photos, network,
    /// disk screenshots or new GPU reconstruction. Explicit opt-in for private data.
    func testExistingSingleImageResultsRenderOnThisPhone() async throws {
        guard ProcessInfo.processInfo.environment["POCKETWORLD_IMAGE_RENDER_CHECK"] == "1" else {
            throw XCTSkip("Opt in to render existing private single-image cache on its device.")
        }
        let support = try FileManager.default.url(for:.applicationSupportDirectory,in:.userDomainMask,appropriateFor:nil,create:false)
        let root = support.appendingPathComponent("ImageGenerations")
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at:root,includingPropertiesForKeys:nil))
        let libraries = enumerator.compactMap { $0 as? URL }.filter { $0.lastPathComponent == "library.json" }
        var checked = 0
        for library in libraries {
            let entries = try JSONDecoder().decode([ImageGenerationStore.Entry].self,from:Data(contentsOf:library))
            for entry in entries {
                guard let result = entry.image.result, entry.image.status == "ready" else { continue }
                try entry.image.validate()
                let url = library.deletingLastPathComponent().appendingPathComponent(entry.id).appendingPathComponent(result.spz.sha256+".spz")
                guard FileManager.default.fileExists(atPath:url.path) else { continue }
                let bytes=try Data(contentsOf:url,options:.mappedIfSafe)
                XCTAssertEqual(bytes.count,result.spz.byteSize)
                XCTAssertEqual(SHA256.hash(data:bytes).map { String(format:"%02x",$0) }.joined(),result.spz.sha256)
                let visible = try await render(url,count:result.pointCount,hint:result.viewHint)
                XCTAssertGreaterThan(visible,100,"Existing result must produce visible pixels at its actual initial view")
                checked += 1
                print("SPZ_DEVICE verified_points=\(result.pointCount) visible_pixels=\(visible)")
            }
        }
        XCTAssertGreaterThan(checked,0,"No downloaded single-image result was found")
        print("SPZ_DEVICE cached_results_rendered=\(checked)")
    }

    private func render(_ url:URL, count:Int, hint:ImageGeneration.Hint?=nil) async throws -> Int {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let view=MTKView(frame:CGRect(x:0,y:0,width:192,height:256),device:device)
        view.colorPixelFormat = .bgra8Unorm_srgb
        view.depthStencilPixelFormat = .depth32Float
        view.isPaused = true
        let status=GaussianViewerStatus()
        let renderer=try PocketSplatRenderer(view:view,status:status,screenScale:1)
        defer { renderer.invalidate() }
        if let p=hint?.presentation {
            renderer.orbitTarget=p.target;renderer.orbitDistance=p.distance;renderer.yaw=p.yaw;renderer.pitch=p.pitch
        }
        await renderer.load(url:url)
        XCTAssertNil(status.error)
        XCTAssertEqual(status.loadedPoints,count)
        guard status.error == nil, status.loadedPoints == count else { throw TestFailure.load }
        var visible=0
        try await renderer.renderClip(poses:[renderer.orbitPose],width:192,height:256,progress:{ _ in },deliver:{ texture,_ in
            var bytes=[UInt8](repeating:0,count:192*256*4)
            texture.getBytes(&bytes,bytesPerRow:192*4,from:MTLRegionMake2D(0,0,192,256),mipmapLevel:0)
            visible=stride(from:0,to:bytes.count,by:4).filter { bytes[$0]>3 || bytes[$0+1]>3 || bytes[$0+2]>3 }.count
        })
        return visible
    }
    private enum TestFailure: Error { case load, compression }
    private func gzip(_ data:Data) throws -> Data {
        var stream=z_stream()
        guard deflateInit2_(&stream,Z_DEFAULT_COMPRESSION,Z_DEFLATED,15+16,8,Z_DEFAULT_STRATEGY,ZLIB_VERSION,Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw TestFailure.compression }
        defer { deflateEnd(&stream) }
        var output=Data(count:Int(compressBound(uLong(data.count)))+32)
        let code=data.withUnsafeBytes { source in
            stream.next_in=UnsafeMutablePointer(mutating:source.bindMemory(to:UInt8.self).baseAddress);stream.avail_in=uInt(data.count)
            return output.withUnsafeMutableBytes { destination in
                stream.next_out=destination.bindMemory(to:UInt8.self).baseAddress;stream.avail_out=uInt(destination.count)
                return deflate(&stream,Z_FINISH)
            }
        }
        guard code == Z_STREAM_END else { throw TestFailure.compression }
        return output.prefix(Int(stream.total_out))
    }
}
