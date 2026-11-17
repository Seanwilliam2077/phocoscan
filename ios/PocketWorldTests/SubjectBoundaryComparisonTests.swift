import XCTest
import UIKit
import Metal
import simd
import ImageIO
import UniformTypeIdentifiers
@testable import PocketWorld

/// Attended, explicit real-scan check. Changes only independent derived files until the
/// separately gated, reviewed publication. Never starts training, uploads, or edits inputs.
@MainActor final class SubjectBoundaryComparisonTests: XCTestCase {
    func testExistingSubjectBoundaryComparison() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let id = env["PHOCOSCAN_BOUNDARY_SCAN"], UUID(uuidString:id) != nil else { throw XCTSkip("Opt-in real subject comparison") }
        let store=OnDeviceTrainingStore.shared
        guard !store.isTraining, !store.hasProgress(id) else { throw XCTSkip("Do not disturb a real training job") }
        let scan=try XCTUnwrap(OnDeviceTrainingStore.scanFolder(id)), current=try XCTUnwrap(store.result(captureID:id))
        let control=TrainingRunControl(), idle=UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled=true
        let observer=NotificationCenter.default.addObserver(forName:UIApplication.willResignActiveNotification,object:nil,queue:nil) { _ in control.pause() }
        defer { UIApplication.shared.isIdleTimerDisabled=idle; NotificationCenter.default.removeObserver(observer) }
        let output=try await Task.detached(priority:.userInitiated) {
            let fm=FileManager.default, temp=fm.temporaryDirectory.appendingPathComponent("Boundary-"+UUID().uuidString)
            try fm.createDirectory(at:temp,withIntermediateDirectories:true)
            defer { try? fm.removeItem(at:temp) }
            try fm.createSymbolicLink(at:temp.appendingPathComponent("capture"),withDestinationURL:scan.appendingPathComponent("capture"))
            try fm.copyItem(at:scan.appendingPathComponent("analysis.json"),to:temp.appendingPathComponent("analysis.json"))
            let output=scan.appendingPathComponent("ondevice.boundary."+UUID().uuidString)
            try fm.createDirectory(at:output,withIntermediateDirectories:true)
            let sourceHashes=try Self.hashes(current.model.deletingLastPathComponent())
            let raw=try TrainingDataset.load(scanFolder:temp,limits:.init(maxFrames:113,longSide:768,maxGaussians:250_000))
            let source=try TrainingCheckpoint.sourceDigest(scan:temp,dataset:raw,control:control)
            let prepared=try XCTUnwrap(TrainingSubject.prepare(raw,scan:temp,sourceDigest:source,control:control))
            let data=prepared.dataset, held=TrainingQualityPlan.splitViews(count:data.cameras.count).validation
            let device=try XCTUnwrap(MTLCreateSystemDefaultDevice()), library=try XCTUnwrap(device.makeDefaultLibrary())
            let p=try Self.read(current.model)
            let full=try GaussianTrainer(device:device,library:library,seeds:p[0].map { GaussianSeed(position:SIMD3($0.x,$0.y,$0.z),size:0.01,color:SIMD3(repeating:0.5)) },cameras:data.cameras,targets:data.targets,width:data.width,height:data.height)
            full.control=control
            for (i,b) in [full.means,full.logScales,full.quats,full.colorOp].enumerated() {
                p[i].withUnsafeBytes { b.contents().copyMemory(from:$0.baseAddress!,byteCount:$0.count) }
            }
            let started=Date()
            let selection=try TrainingSubjectSurface.select(device:device,library:library,dataset:data,
                means:p[0],logScales:p[1],quats:p[2],control:control,trainer:full)
            let count=try TrainingSubjectSurface.write(selection,means:p[0],logScales:p[1],quats:p[2],colorOp:p[3],to:output.appendingPathComponent("subject.ply"))
            let extractionSeconds=Date().timeIntervalSince(started)
            let target=try XCTUnwrap(ScanAnalysis.load(from:scan)?.targetBox)
            let crop=SplatCrop(region:SplatCrop.region(for:target),rotation:matrix_identity_float3x3,scale:1,translation:.zero,fitError:0,matchedCameras:data.frames.count)
            var reports:[[String:Any]]=[]
            for (name,url) in [("before",try XCTUnwrap(current.subjectModel)),("after",output.appendingPathComponent("subject.ply"))] {
                let values=try Self.read(url)
                let seeds=values[0].map { GaussianSeed(position:SIMD3($0.x,$0.y,$0.z),size:0.01,color:SIMD3(repeating:0.5)) }
                let trainer=try GaussianTrainer(device:device,library:library,seeds:seeds,cameras:data.cameras,targets:data.targets,width:data.width,height:data.height)
                trainer.control=control
                for (i,b) in [trainer.means,trainer.logScales,trainer.quats,trainer.colorOp].enumerated() {
                    values[i].withUnsafeBytes { b.contents().copyMemory(from:$0.baseAddress!,byteCount:$0.count) }
                }
                for i in seeds.indices {
                    let c=values[3][i]
                    if !crop.keeps(position:seeds[i].position,opacity:1/(1+exp(-c.w))) {
                        trainer.setParameter(trainer.colorOp,index:i,value:SIMD4(c.x,c.y,c.z,-100))
                    }
                }
                var tp=0.0,fp=0.0,fn=0.0,mae=0.0,mse=0.0,n=0.0
                var hairN=0.0,hairCovered=0.0,hairError=0.0,edgeN=0.0,edgeCovered=0.0
                var perView:[[String:Any]]=[]
                for index in held {
                    try control.check()
                    let image=try trainer.render(cameraIndex:index)
                    var viewHair=0.0,viewHairCovered=0.0,viewFP=0.0
                    data.targets.withUnsafeBytes { buffer in
                        let bytes=buffer.bindMemory(to:UInt8.self), offset=data.cameras[index].imageIndex*data.width*data.height*4
                        for i in image.indices {
                            let truth=bytes[offset+i*4+3]>=128, predicted=(1-image[i].w)>0.2
                            if truth && predicted { tp+=1 }; if !truth && predicted { fp+=1;viewFP+=1 }; if truth && !predicted { fn+=1 }
                            let rgb=SIMD3(Float(bytes[offset+i*4])/255,Float(bytes[offset+i*4+1])/255,Float(bytes[offset+i*4+2])/255)
                            if truth {
                                for c in 0..<3 { let d=Double(image[i][c]-rgb[c]);mae+=abs(d);mse+=d*d;n+=1 }
                            }
                            // Scan15-only evaluation region: yellow fur in reference photos.
                            // NEVER used by extraction, and includes fine contrast edges separately.
                            if truth && rgb.x>0.45 && rgb.y>0.3 && rgb.z<rgb.y*0.75 && rgb.x>rgb.z*1.4 {
                                hairN+=1;viewHair+=1;if predicted { hairCovered+=1;viewHairCovered+=1 }
                                for c in 0..<3 { hairError+=abs(Double(image[i][c]-rgb[c]))/3 }
                                if i%data.width>0 && i%data.width<data.width-1 && i>=data.width && i<data.width*(data.height-1) {
                                    let neighbors=[i-1,i+1,i-data.width,i+data.width]
                                    var contrast:Float=0
                                    for j in neighbors {
                                        var difference:Float=0
                                        for c in 0..<3 { difference += abs(Float(bytes[offset+j*4+c])/255-rgb[c]) }
                                        contrast=max(contrast,difference/3)
                                    }
                                    if contrast>0.06 { edgeN+=1;if predicted { edgeCovered+=1 } }
                                }
                            }
                        }
                    }
                    perView.append(["index":index,"hairRecall":viewHairCovered/max(1,viewHair),"outsidePixels":viewFP])
                    if [held.first!,held[min(2,held.count-1)],held.last!].contains(index) {
                        let rgba=image.flatMap { p in (0..<3).map { UInt8(min(255,max(0,Int((p[$0]*255).rounded())))) }+[255] }
                        try Self.png(Data(rgba),width:data.width,height:data.height,to:output.appendingPathComponent("\(name)-\(index).png"))
                    }
                }
                let report:[String:Any]=["arm":name,"points":seeds.count,"modelSHA":TrainingCheckpoint.digest(try Data(contentsOf:url)),
                    "outsidePixels":fp,"recall":tp/max(1,tp+fn),"iou":tp/max(1,tp+fp+fn),"subjectMAE":mae/max(1,n),
                    "subjectPSNR": -10*log10(max(1e-12,mse/max(1,n))),"hairRecall":hairCovered/max(1,hairN),
                    "hairMAE":hairError/max(1,hairN),"hairEdgeRecall":edgeCovered/max(1,edgeN),"hairPixels":hairN,"hairEdgePixels":edgeN,"perView":perView]
                reports.append(report)
                print("BOUNDARY_REPORT "+String(decoding:try JSONSerialization.data(withJSONObject:report,options:[.sortedKeys]),as:UTF8.self))
            }
            let report:[String:Any]=["version":TrainingSubjectSurface.version,"sourceDigest":source,"subjectDigest":prepared.digest,
                "originalHashes":sourceHashes,"heldOut":held,"selectionViews":selection.views,"points":count,
                "narrowed":selection.narrowed,"harmfulTails":selection.harmfulTails,"extractionSeconds":extractionSeconds,"arms":reports]
            try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("report.json"),options:.atomic)
            XCTAssertEqual(try Self.hashes(current.model.deletingLastPathComponent()),sourceHashes)
            XCTAssertEqual(try TrainingCheckpoint.sourceDigest(scan:temp,dataset:raw,control:control),source)
            print("BOUNDARY_INPUT_UNCHANGED true source=\(source) mask=\(prepared.digest) extraction=\(extractionSeconds)")
            return output
        }.value
        print("BOUNDARY_OUTPUT "+output.lastPathComponent)
        // An attended review can read the renders while this test keeps the phone
        // awake. The signal is inside this independent experiment only, never a scan
        // input/result. Bounded, opt-in, and released on app resignation as well.
        if env["PHOCOSCAN_BOUNDARY_ATTENDED_WAIT"] == "1" {
            let signal=output.appendingPathComponent(".review-complete")
            print("BOUNDARY_AWAITING_REVIEW "+output.lastPathComponent)
            for _ in 0..<300 {
                if FileManager.default.fileExists(atPath:signal.path) { try? FileManager.default.removeItem(at:signal);break }
                do { try control.check() } catch { break }
                try await Task.sleep(nanoseconds:1_000_000_000)
            }
        }
    }

    func testPublishReviewedSubjectKeepingFullModelAndPrevious() throws {
        let env=ProcessInfo.processInfo.environment
        guard let id=env["PHOCOSCAN_BOUNDARY_SCAN"],UUID(uuidString:id) != nil,
              let name=env["PHOCOSCAN_BOUNDARY_PUBLISH"],name.hasPrefix("ondevice.boundary."),
              UUID(uuidString:String(name.dropFirst("ondevice.boundary.".count))) != nil else { throw XCTSkip("Reviewed explicit publication only") }
        let store=OnDeviceTrainingStore.shared
        guard !store.isTraining,!store.hasProgress(id) else { throw XCTSkip("Real job pending") }
        let scan=try XCTUnwrap(OnDeviceTrainingStore.scanFolder(id)),old=try XCTUnwrap(store.result(captureID:id)),folder=scan.appendingPathComponent(name)
        let report=try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:folder.appendingPathComponent("report.json"))) as? [String:Any])
        let hashes=try XCTUnwrap(report["originalHashes"] as? [String:String])
        let arms=try XCTUnwrap(report["arms"] as? [[String:Any]])
        let before=try XCTUnwrap(arms.first { $0["arm"] as? String == "before" }),after=try XCTUnwrap(arms.first { $0["arm"] as? String == "after" })
        func value(_ r:[String:Any],_ key:String) throws -> Double { try XCTUnwrap((r[key] as? NSNumber)?.doubleValue) }
        guard try Self.hashes(old.model.deletingLastPathComponent()) == hashes,
              report["version"] as? Int == TrainingSubjectSurface.version,
              try value(after,"outsidePixels") < value(before,"outsidePixels")*0.9,
              try value(after,"recall") >= value(before,"recall")-0.02,
              try value(after,"hairRecall") >= value(before,"hairRecall")-0.005,
              try value(after,"hairEdgeRecall") >= value(before,"hairEdgeRecall")-0.005,
              try value(after,"hairMAE") <= value(before,"hairMAE")*1.03,
              try value(after,"subjectMAE") <= value(before,"subjectMAE")*1.03,
              after["modelSHA"] as? String == TrainingCheckpoint.digest(try Data(contentsOf:folder.appendingPathComponent("subject.ply")))
        else { XCTFail("Reviewed subject did not pass preservation, quality and source gates");return }
        let data=try TrainingDataset.load(scanFolder:scan,limits:.init(maxFrames:113,longSide:768,maxGaussians:250_000))
        guard try TrainingCheckpoint.sourceDigest(scan:scan,dataset:data,control:TrainingRunControl()) == report["sourceDigest"] as? String else {
            XCTFail("Source changed");return
        }
        let fm=FileManager.default,staging=scan.appendingPathComponent("ondevice.reviewed."+UUID().uuidString)
        try fm.createDirectory(at:staging,withIntermediateDirectories:true)
        defer { try? fm.removeItem(at:staging) }
        for file in ["scene.ply","cameras.json"] { try fm.copyItem(at:old.model.deletingLastPathComponent().appendingPathComponent(file),to:staging.appendingPathComponent(file)) }
        try fm.copyItem(at:folder.appendingPathComponent("subject.ply"),to:staging.appendingPathComponent("subject.ply"))
        var meta=try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:old.model.deletingLastPathComponent().appendingPathComponent("meta.json"))) as? [String:Any])
        meta["surfaceVersion"]=TrainingSubjectSurface.version;meta["subjectGaussians"]=report["points"]
        var surface=meta["subjectSurface"] as? [String:Any] ?? [:]
        surface["version"]=TrainingSubjectSurface.version;surface["gaussians"]=report["points"]
        surface["trainingViews"]=report["selectionViews"];surface["narrowed"]=report["narrowed"]
        surface["harmfulTails"]=report["harmfulTails"];surface["minimumAxisScale"]=0.85
        surface["minimumBackgroundMass"]=0.4;surface["minimumRemovalImprovement"]=0.001
        meta["subjectSurface"]=surface
        meta["boundaryEvaluation"]=report;meta["createdAt"]=Date().ISO8601Format()
        try JSONSerialization.data(withJSONObject:meta,options:[.prettyPrinted,.sortedKeys]).write(to:staging.appendingPathComponent("meta.json"),options:.atomic)
        try OnDeviceTrainingStore.publish(staging:staging,final:scan.appendingPathComponent("ondevice"))
        let current=try XCTUnwrap(store.result(captureID:id)),previous=try XCTUnwrap(store.previousResult(captureID:id))
        XCTAssertEqual(try Self.hashes(previous.model.deletingLastPathComponent()),hashes)
        XCTAssertEqual(TrainingCheckpoint.digest(try Data(contentsOf:current.model)),hashes["scene.ply"])
        XCTAssertEqual(TrainingCheckpoint.digest(try Data(contentsOf:current.cameras)),hashes["cameras.json"])
        XCTAssertEqual(TrainingCheckpoint.digest(try Data(contentsOf:XCTUnwrap(current.subjectModel))),after["modelSHA"] as? String)
        // Explicitly named rejected derivatives from this attended experiment only. Never
        // delete any current/previous result, resume job, original photo or unrelated scan.
        if let rejected=env["PHOCOSCAN_BOUNDARY_REJECT"] {
            for item in rejected.split(separator:",").map(String.init) where item != name {
                guard item.hasPrefix("ondevice.boundary."),UUID(uuidString:String(item.dropFirst("ondevice.boundary.".count))) != nil else {
                    XCTFail("Invalid experiment cleanup name");continue
                }
                let url=scan.appendingPathComponent(item)
                if fm.fileExists(atPath:url.path) { try fm.removeItem(at:url) }
            }
        }
        // A crashed attended comparison may leave its own mask cache. Remove only
        // UUID-named test temporaries whose analysis bytes match this exact scan.
        let analysis=try Data(contentsOf:scan.appendingPathComponent("analysis.json"))
        for temp in (try? fm.contentsOfDirectory(at:fm.temporaryDirectory,includingPropertiesForKeys:nil)) ?? [] {
            let name=temp.lastPathComponent
            if name.hasPrefix("Boundary-"),UUID(uuidString:String(name.dropFirst(9))) != nil,
               (try? Data(contentsOf:temp.appendingPathComponent("analysis.json"))) == analysis {
                try fm.removeItem(at:temp)
            }
        }
        print("BOUNDARY_PUBLISHED full_model_unchanged=true previous_all_files_unchanged=true archive=\(previous.model.deletingLastPathComponent().lastPathComponent)")
    }

    nonisolated private static func hashes(_ folder:URL) throws -> [String:String] {
        try Dictionary(uniqueKeysWithValues:["scene.ply","subject.ply","cameras.json","meta.json"].map {
            ($0,TrainingCheckpoint.digest(try Data(contentsOf:folder.appendingPathComponent($0))))
        })
    }
    nonisolated private static func read(_ url:URL) throws -> [[SIMD4<Float>]] {
        let bytes=try Data(contentsOf:url),end=try XCTUnwrap(bytes.range(of:Data("end_header\n".utf8)))
        let header=String(decoding:bytes[..<end.lowerBound],as:UTF8.self)
        guard header.contains("format binary_little_endian 1.0"),header.split(separator:"\n").filter({$0.hasPrefix("property float ")}).count == 17,
              (bytes.count-end.upperBound)%68 == 0 else { throw GaussianTrainerError.invalidInput }
        let count=(bytes.count-end.upperBound)/68
        guard (100...250_000).contains(count) else { throw GaussianTrainerError.invalidInput }
        var values:[[SIMD4<Float>]]=[[],[],[],[]]
        bytes.withUnsafeBytes { raw in
            for i in 0..<count {
                let p=raw.baseAddress!.advanced(by:end.upperBound+i*68)
                func v(_ j:Int)->Float { p.loadUnaligned(fromByteOffset:j*4,as:Float.self) }
                values[0].append(SIMD4(v(0),v(1),v(2),0));values[1].append(SIMD4(v(10),v(11),v(12),0))
                values[2].append(SIMD4(v(13),v(14),v(15),v(16)));values[3].append(SIMD4(v(6),v(7),v(8),v(9)))
            }
        }
        return values
    }
    nonisolated private static func png(_ data:Data,width:Int,height:Int,to url:URL) throws {
        let provider=try XCTUnwrap(CGDataProvider(data:data as CFData))
        let image=try XCTUnwrap(CGImage(width:width,height:height,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:width*4,
            space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.last.rawValue),provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent))
        let dest=try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL,UTType.png.identifier as CFString,1,nil))
        CGImageDestinationAddImage(dest,image,nil);XCTAssertTrue(CGImageDestinationFinalize(dest))
    }
}
