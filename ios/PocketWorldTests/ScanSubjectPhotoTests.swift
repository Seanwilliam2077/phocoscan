import AVFoundation
import CoreImage
import Security
import XCTest
@testable import PocketWorld

final class ScanSubjectPhotoTests: XCTestCase {
    private let rows: [[Float]] = [[1,0,0,0],[0,1,0,0],[0,0,1,0],[0,0,0,1]]
    private func folder() throws -> URL {
        let url=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".scan")
        try FileManager.default.createDirectory(at:url.appendingPathComponent("capture/images"),withIntermediateDirectories:true)
        return url
    }
    private func frame(_ file:String, sharpness:Double=100) -> [String:Any] {
        ["file_path":file,"transform_matrix":rows,"w":640,"h":480,"fl_x":500,"fl_y":500,"cx":320,"cy":240,"timestamp":1.0,"sharpness":sharpness]
    }
    private func write(_ frames:[[String:Any]], to folder:URL) throws {
        try JSONSerialization.data(withJSONObject:["frames":frames]).write(to:folder.appendingPathComponent("capture/transforms.json"))
    }
    func testSelectionFiltersMovingInvalidAndOutsideFrames() throws {
        let dir=try folder();defer{try? FileManager.default.removeItem(at:dir)}
        var moving=frame("images/moving.jpg",sharpness:99999);moving["subject_moving"]=true
        try write([frame("images/good.jpg"),moving,frame("images/../../other.jpg")],to:dir)
        let frames=try ScanSubjectPhoto.candidates(folder:dir,video:false)
        XCTAssertEqual(frames.map(\.file),["images/good.jpg"])
        let object=ScanTargetBox(center:SIMD3(0,0,-2),size:SIMD3(0.8,0.8,0.4),yawRadians:0,source:"lidar")
        let framing=try XCTUnwrap(ScanSubjectPhoto.framing(frames[0],target:object))
        XCTAssertEqual(framing.point.x,0.5,accuracy:1e-5);XCTAssertEqual(framing.point.y,0.5,accuracy:1e-5)
        XCTAssertGreaterThan(framing.box.width,0.3);XCTAssertLessThan(framing.box.width,0.4)
        var outside=object;outside.center=[3,0,-2];XCTAssertNil(ScanSubjectPhoto.framing(frames[0],target:outside))
        outside.center=[0,0,2];XCTAssertNil(ScanSubjectPhoto.framing(frames[0],target:outside))
        outside.center=[0,0,-0.3];XCTAssertNil(ScanSubjectPhoto.framing(frames[0],target:outside))
    }
    func testJSONDecimalPosesDoNotDropValidKeyframes() throws {
        let dir = try folder(); defer { try? FileManager.default.removeItem(at: dir) }
        var row = frame("images/decimal.jpg")
        let c = cos(0.3), s = sin(0.3)
        row["transform_matrix"] = [[c,-s,0,0],[s,c,0,0],[0,0,1,0],[0,0,0,1]]
        row["fl_x"] = 500.123456789
        try write([row], to: dir)
        let frames = try ScanSubjectPhoto.candidates(folder: dir, video: false)
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(try XCTUnwrap(frames.first).intrinsics[0][0], Float(500.123456789), accuracy: 1e-4)
    }
    func testTrainingSeedAllowsCloseDetailsButNotOffscreenAnchor() throws {
        let dir = try folder(); defer { try? FileManager.default.removeItem(at: dir) }
        try write([frame("images/detail.jpg")], to: dir)
        let candidate = try XCTUnwrap(ScanSubjectPhoto.candidates(folder: dir, video: false).first)
        var target = ScanTargetBox(center: SIMD3(0,0,-0.3), size: SIMD3(0.8,0.8,0.2), yawRadians: 0, source: "lidar")
        XCTAssertNil(ScanSubjectPhoto.framing(candidate, target: target))
        XCTAssertEqual(KeyframePack.subjectPoint(candidate, target: target), CGPoint(x: 0.5, y: 0.5))
        target.center = [3,0,-0.3]
        XCTAssertNil(KeyframePack.subjectPoint(candidate, target: target))
    }

    func testRecordedRollKeepsSubjectCoordinatesWithUprightImage() throws {
        for angle:Float in [0,.pi/2,Float.pi,-Float.pi/2] {
            let pose=simd_float4x4(simd_quatf(angle:angle,axis:SIMD3(0,0,1)))
            let (_,transform)=ScanSubjectPhoto.upright(pose)
            let up=pose.inverse*SIMD4<Float>(0,1,0,0)
            let center=CGPoint(x:0.5,y:0.5).applying(transform)
            let top=CGPoint(x:0.5+CGFloat(up.x)*0.1,y:0.5-CGFloat(up.y)*0.1).applying(transform)
            XCTAssertLessThan(top.y,center.y);XCTAssertEqual(top.x,center.x,accuracy:1e-5)
        }
    }
    func testActualKeyframeSelectedWithoutRewritingTheScan() async throws {
        let dir=try folder();defer{try? FileManager.default.removeItem(at:dir)}
        try write([frame("images/missing.jpg",sharpness:9999),frame("images/actual.jpg")],to:dir)
        let source=CIImage(color:CIColor(red:0.8,green:0.2,blue:0.1)).cropped(to:CGRect(x:0,y:0,width:640,height:480))
        try CIContext().writeJPEGRepresentation(of:source,to:dir.appendingPathComponent("capture/images/actual.jpg"),colorSpace:CGColorSpaceCreateDeviceRGB())
        let metadata=try Data(contentsOf:dir.appendingPathComponent("capture/transforms.json"))
        let target=ScanTargetBox(center:SIMD3(0,0,-2),size:SIMD3(0.8,0.8,0.4),yawRadians:0,source:"lidar")
        let result=try await ScanSubjectPhoto.prepare(folder:dir,target:target)
        XCTAssertEqual(result.source.file,"images/actual.jpg")
        XCTAssertEqual(result.source.captureID,dir.deletingPathExtension().lastPathComponent)
        XCTAssertTrue(["projected_anchor","foreground_at_anchor"].contains(result.source.selection))
        XCTAssertGreaterThan(result.image.width,200);XCTAssertLessThan(result.image.width,640)
        XCTAssertEqual(try Data(contentsOf:dir.appendingPathComponent("capture/transforms.json")),metadata)
    }
    func testLegacyVideoUsesRecordedPTSAndRejectsUntrackedFrame() async throws {
        let dir=try folder();defer{try? FileManager.default.removeItem(at:dir)}
        let writer=try AVAssetWriter(outputURL:dir.appendingPathComponent("video.mov"),fileType:.mov)
        let input=AVAssetWriterInput(mediaType:.video,outputSettings:[AVVideoCodecKey:AVVideoCodecType.h264,AVVideoWidthKey:640,AVVideoHeightKey:480])
        let adaptor=AVAssetWriterInputPixelBufferAdaptor(assetWriterInput:input,sourcePixelBufferAttributes:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA,kCVPixelBufferWidthKey as String:640,kCVPixelBufferHeightKey as String:480,kCVPixelBufferIOSurfacePropertiesKey as String:[:]])
        writer.add(input);XCTAssertTrue(writer.startWriting());writer.startSession(atSourceTime:.zero)
        let context=CIContext()
        for i in 0..<3 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for:.milliseconds(10)) }
            var buffer:CVPixelBuffer?;CVPixelBufferPoolCreatePixelBuffer(nil,try XCTUnwrap(adaptor.pixelBufferPool),&buffer)
            context.render(CIImage(color:CIColor(red:Double(i)/2,green:0.3,blue:0.2)),to:try XCTUnwrap(buffer))
            XCTAssertTrue(adaptor.append(try XCTUnwrap(buffer),withPresentationTime:CMTime(value:Int64(i),timescale:2)))
        }
        input.markAsFinished();await writer.finishWriting();XCTAssertEqual(writer.status,.completed)
        let lines=try (0..<3).map { i -> Data in
            try JSONSerialization.data(withJSONObject:["cameraToWorldARKit":rows,"intrinsicsPixels":[[500,0,320],[0,500,240],[0,0,1]],"cameraImageWidth":640,"cameraImageHeight":480,"videoPTSSeconds":Double(i)/2,"trackingState":i==1 ? "normal":"limited"])
        }
        try lines.reduce(into:Data()) { $0.append($1);$0.append(10) }.write(to:dir.appendingPathComponent("frames.jsonl"))
        let result=try await ScanSubjectPhoto.prepare(folder:dir,target:nil)
        XCTAssertEqual(result.source.file,"video.mov");XCTAssertEqual(result.source.timestamp,0.5,accuracy:0.001)
        XCTAssertEqual(result.image.width,640)
    }
    @MainActor func testScanDraftIsReusedAfterRelaunchAndOldEntriesDecode() throws {
        let base=try APIClient.normalized("https://scan-photo-test-"+UUID().uuidString.lowercased()+".invalid")
        let identity=APIConnectionIdentity(base:base,userID:UUID().uuidString)
        try CredentialStore.write(AuthResponse(userId:identity.userID,token:"synthetic-test-only"),for:base)
        defer {
            SecItemDelete([kSecClass:kSecClassGenericPassword,kSecAttrService:"com.pocketworld.player",kSecAttrAccount:CredentialStore.account(base)] as CFDictionary)
            if let dir=try? ImageGenerationStore.directory(identity:identity) { try? FileManager.default.removeItem(at:dir) }
        }
        let api=APIClient();api.restore(base:base)
        let store=ImageGenerationStore(api:api)
        let ui=UIGraphicsImageRenderer(size:CGSize(width:20,height:20)).image { ctx in UIColor.red.setFill();ctx.fill(CGRect(x:0,y:0,width:20,height:20)) }
        let source=ScanSubjectPhoto.Source(captureID:UUID().uuidString,file:"images/a.jpg",timestamp:1,selection:"projected_anchor")
        let id=try store.add(image:ui,scanSource:source)
        let reopened=ImageGenerationStore(api:api)
        XCTAssertEqual(try reopened.add(image:ui,scanSource:source),id)
        XCTAssertEqual(reopened.entries.count,1);XCTAssertEqual(reopened.entries[0].scanSource,source)
        XCTAssertNil(reopened.entries[0].requestedAttempt);XCTAssertFalse(reopened.entries[0].submitted)
        XCTAssertEqual(reopened.entries[0].image.sourceKind,"ai_single_image")
        let old=try JSONSerialization.jsonObject(with:JSONEncoder().encode(reopened.entries[0])) as! [String:Any]
        var withoutLink=old;withoutLink.removeValue(forKey:"scanSource")
        XCTAssertNil(try JSONDecoder().decode(ImageGenerationStore.Entry.self,from:JSONSerialization.data(withJSONObject:withoutLink)).scanSource)
    }
}
