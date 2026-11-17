import CoreGraphics
import ImageIO
import Metal
import UniformTypeIdentifiers
import XCTest
import simd
@testable import PocketWorld

/// On-device training: loading a keyframe package, writing the result, and (where the GPU
/// supports it) a short training run that must improve the fit. Synthetic data only; the full
/// gradient checks and convergence runs live in the Mac harness noted in AGENTS.md.
final class OnDeviceTrainingTests: XCTestCase {
    private func gpu() throws -> (MTLDevice, MTLLibrary) {
        guard let device = MTLCreateSystemDefaultDevice(), device.supportsFamily(.apple7) else {
            throw XCTSkip("Requires an Apple7+ GPU")
        }
        return (device, try XCTUnwrap(device.makeDefaultLibrary()))
    }

    func testNeedleConstraintPreservesPlanarSplatsAndLegacyConfiguration() throws {
        let (device,library)=try gpu()
        let camera=TrainingCamera(cameraToWorld:matrix_identity_float4x4,fx:30,fy:30,cx:15.5,cy:15.5,imageIndex:0)
        for limit:Float? in [nil,12] {
            var config=GaussianTrainer.Config();config.lineAspectLimit=limit;config.lrScale=0;config.noiseLR=0
            let trainer=try GaussianTrainer(device:device,library:library,
                seeds:Array(repeating:GaussianSeed(position:SIMD3(0,0,-1),size:0.03,color:SIMD3(repeating:0.5)),count:2),
                cameras:[camera],targets:Data(repeating:127,count:32*32*4),width:32,height:32,config:config)
            let ptr=trainer.logScales.contents().bindMemory(to:SIMD4<Float>.self,capacity:2)
            ptr[0]=SIMD4(log(0.1),log(0.001),log(0.001),0)
            ptr[1]=SIMD4(log(0.1),log(0.1),log(0.001),0)
            try trainer.trainStep(cameraIndex:0)
            XCTAssertEqual(exp(ptr[0].x-ptr[0].y),limit ?? 100,accuracy:0.001)
            XCTAssertEqual(exp(ptr[1].x-ptr[1].z),100,accuracy:0.001,"thin surfaces are not needles")
        }
    }

    func testCachedSubjectStatisticsLeaveLossAndGradientsUnchangedAcrossViews() throws {
        let (device,library)=try gpu(), w=16, h=16
        var bytes=[UInt8](repeating:120,count:2*w*h*4)
        for f in 0..<2 { for i in 0..<(w*h) { bytes[(f*w*h+i)*4+3]=i%w < (f == 0 ? 4:10) ? 255:0 } }
        let cameras=(0..<2).map { TrainingCamera(cameraToWorld:matrix_identity_float4x4,fx:20,fy:20,cx:7.5,cy:7.5,imageIndex:$0) }
        var config=GaussianTrainer.Config();config.subjectWeighting=true
        func make() throws -> GaussianTrainer { try GaussianTrainer(device:device,library:library,
            seeds:[GaussianSeed(position:SIMD3(0,0,-1),size:0.02,color:SIMD3(repeating:0.5))],
            cameras:cameras,targets:Data(bytes),width:w,height:h,config:config) }
        let cached=try make(), original=try make();original.cachesTargetStatistics=false
        let pixels=(0..<(w*h)).map { SIMD4<Float>(Float($0%13)/13,0.2,0.7,0) }
        for index in [0,1,0,1] {
            let a=try cached.pixelLoss(rendered:pixels,cameraIndex:index), b=try original.pixelLoss(rendered:pixels,cameraIndex:index)
            XCTAssertEqual(a.value,b.value)
            XCTAssertEqual(a.gradient,b.gradient)
        }
    }

    func testSubjectSurfaceUsesTrainingViewsAndRejectsUnsupportedFloorAndExtents() throws {
        let (device,library)=try gpu(), n=16, w=64, h=64
        var bytes=[UInt8](repeating:120,count:n*w*h*4)
        for frame in 0..<n { for y in 0..<h { for x in 0..<w {
            bytes[(frame*w*h+y*w+x)*4+3]=(20...44).contains(x) && (20...44).contains(y) ? 255:0
        } } }
        // Held-out frames deliberately disagree: they must not vote in the extraction.
        for frame in [7,15] { for pixel in 0..<(w*h) { bytes[(frame*w*h+pixel)*4+3]=255-bytes[(frame*w*h+pixel)*4+3] } }
        let cameras=(0..<n).map { TrainingCamera(cameraToWorld:matrix_identity_float4x4,fx:40,fy:40,cx:31.5,cy:31.5,imageIndex:$0) }
        let data=TrainingDataset(cameras:cameras,targets:Data(bytes),width:w,height:h,seeds:[],frames:[])
        let selection=try TrainingSubjectSurface.select(device:device,library:library,dataset:data,
            means:[SIMD4(0,0,-1,0),SIMD4(0,-0.6,-1,0),SIMD4(0,0,-1,0),SIMD4(0,0,-2,0)],
            logScales:[SIMD4(repeating:log(0.02)),SIMD4(repeating:log(0.02)),SIMD4(log(0.8),log(0.001),log(0.001),0),
                       SIMD4(log(0.65),log(0.01),log(0.8),0)],
            quats:Array(repeating:SIMD4(1,0,0,0),count:4),control:TrainingRunControl())
        XCTAssertEqual(selection.views,14)
        XCTAssertEqual(selection.indices,[0]);XCTAssertEqual(selection.unsupportedCenters,1);XCTAssertEqual(selection.unsupportedExtents,2)
    }

    func testVisibleBoundaryPreservesSoftOnePixelStrandsWithoutBroadBackgroundHalo() throws {
        let (device,library)=try gpu(),n=16,w=128,h=128
        var bytes=[UInt8](repeating:255,count:n*w*h*4)
        for frame in 0..<n { for y in 0..<h { for x in 0..<w {
            bytes[(frame*w*h+y*w+x)*4+3]=(30...100).contains(y)
                ? ((40...70).contains(x) ? 255 : (x == 80 ? 160:0)) : 0
        } } }
        let cameras=(0..<n).map { TrainingCamera(cameraToWorld:matrix_identity_float4x4,fx:100,fy:100,cx:63.5,cy:63.5,imageIndex:$0) }
        let data=TrainingDataset(cameras:cameras,targets:Data(bytes),width:w,height:h,seeds:[],frames:[])
        let means:[SIMD4<Float>]=[50,80,74].map { SIMD4((Float($0)-63.5)/100,(63.5-50)/100,-1,0) }
        let scales=Array(repeating:SIMD4<Float>(repeating:log(0.0045)),count:3),quats=Array(repeating:SIMD4<Float>(1,0,0,0),count:3)
        let trainer=try GaussianTrainer(device:device,library:library,seeds:means.map { GaussianSeed(position:SIMD3($0.x,$0.y,$0.z),size:0.0045,color:SIMD3(repeating:1)) },cameras:cameras,targets:Data(bytes),width:w,height:h)
        let fine=try TrainingSubjectSurface.select(device:device,library:library,dataset:data,means:means,logScales:scales,quats:quats,control:TrainingRunControl(),trainer:trainer)
        let coarse=try TrainingSubjectSurface.select(device:device,library:library,dataset:data,means:means,logScales:scales,quats:quats,control:TrainingRunControl())
        XCTAssertEqual(fine.indices,[0,1],"Keep soft thin detail and white surfaces; reject the empty gap without a colour rule")
        XCTAssertTrue(coarse.indices.contains(2),"Fixture reproduces the original padded-mask halo")
        let paused=TrainingRunControl();paused.pause()
        XCTAssertThrowsError(try TrainingSubjectSurface.select(device:device,library:library,dataset:data,means:means,logScales:scales,quats:quats,control:paused))
    }

    func testVisibleSubjectEvidenceRespectsOcclusionConservesAlphaAndPreservesCheckpoint() throws {
        let (device,library)=try gpu(),w=32,h=32
        var bytes=[UInt8](repeating:120,count:w*h*4)
        for y in 0..<h { for x in 0..<w { bytes[(y*w+x)*4+3]=(12...19).contains(x) && (12...19).contains(y) ? 255:0 } }
        let camera=TrainingCamera(cameraToWorld:matrix_identity_float4x4,fx:30,fy:30,cx:15.5,cy:15.5,imageIndex:0)
        let trainer=try GaussianTrainer(device:device,library:library,seeds:[
            GaussianSeed(position:SIMD3(0,0,-1),size:0.07,color:SIMD3(repeating:0.5)),
            GaussianSeed(position:SIMD3(0,0,-1.2),size:0.25,color:SIMD3(repeating:0.5))],
            cameras:[camera],targets:Data(bytes),width:w,height:h)
        let color=trainer.colorOp.contents().bindMemory(to:SIMD4<Float>.self,capacity:2)
        color[0].w=log(0.99/0.01);color[1].w=log(0.7/0.3)
        let before=trainer.checkpointBuffers.map { Data(bytes:$0.contents(),count:$0.length) }
        let image=try trainer.render(cameraIndex:0)
        trainer.setResolution(divisor:2)
        let evidence=try trainer.subjectEvidence(cameraIndices:[0])
        XCTAssertEqual(trainer.width,16);XCTAssertEqual(trainer.height,16)
        var expected=SIMD2<Float>(repeating:0)
        for y in 0..<h { for x in 0..<w {
            let mask=(11...20).contains(x) && (11...20).contains(y)
            expected[mask ? 0:1] += 1-image[y*w+x].w
        } }
        let total=evidence[0]+evidence[1]
        XCTAssertEqual(total.x,expected.x,accuracy:0.01);XCTAssertEqual(total.y,expected.y,accuracy:0.01)
        XCTAssertGreaterThan(evidence[0].x/(evidence[0].x+evidence[0].y),0.9)
        XCTAssertLessThan(evidence[1].x/(evidence[1].x+evidence[1].y),0.5,"A background splat's centre is behind the foreground; visible outskirts are background")
        XCTAssertEqual(trainer.checkpointBuffers.map { Data(bytes:$0.contents(),count:$0.length) },before)
        XCTAssertEqual(trainer.checkpointState.step,0)
        // Independent counterfactual: actually hide each point and render again.
        // Compare with the read-only reverse compositing estimate, then restore bytes.
        let boundary=try trainer.subjectBoundaryEvidence(cameraIndices:[0])
        trainer.setResolution(divisor:1)
        for gaussian in 0..<2 {
            let saved=color[gaussian];color[gaussian].w = -100
            let removed=try trainer.render(cameraIndex:0)
            color[gaussian]=saved
            var cost:Float=0
            for y in 11...20 { for x in 11...20 {
                let i=y*w+x,reference=Float(120)/255
                for channel in 0..<3 { cost += (abs(removed[i][channel]-reference)-abs(image[i][channel]-reference))/3 }
            } }
            XCTAssertEqual(boundary[gaussian].removalCost,cost,accuracy:0.002)
        }
        XCTAssertEqual(trainer.checkpointBuffers.map { Data(bytes:$0.contents(),count:$0.length) },before)
        XCTAssertThrowsError(try trainer.subjectEvidence(cameraIndices:[0,0]))
    }

    func testSubjectBoundaryMomentsMatchCPUAndPreserveSupportedStrandAxis() throws {
        let (device,library)=try gpu(),w=64,h=64
        var bytes=[UInt8](repeating:180,count:w*h*4)
        for y in 0..<h { for x in 0..<w { bytes[(y*w+x)*4+3]=(31...32).contains(y) ? 255:0 } }
        let camera=TrainingCamera(cameraToWorld:matrix_identity_float4x4,fx:40,fy:40,cx:31.5,cy:31.5,imageIndex:0)
        let trainer=try GaussianTrainer(device:device,library:library,seeds:[GaussianSeed(position:SIMD3(0,0,-1),size:0.1,color:SIMD3(repeating:0.8))],
            cameras:[camera],targets:Data(bytes),width:w,height:h)
        trainer.setParameter(trainer.logScales,index:0,value:SIMD4(log(0.2),log(0.08),log(0.01),0))
        let snapshot=trainer.checkpointBuffers.map { Data(bytes:$0.contents(),count:$0.length) }
        let image=try trainer.render(cameraIndex:0), e=try XCTUnwrap(trainer.subjectBoundaryEvidence(cameraIndices:[0]).first)
        var fg=SIMD3<Float>(repeating:0),bg=fg
        for y in 0..<h { for x in 0..<w {
            let a=SIMD2<Float>(8,3.2),c=a*a+SIMD2<Float>(repeating:0.3),d=SIMD2(Float(x)-31.5,Float(y)-31.5)
            let xy=SIMD2<Float>(repeating:1)-a*a/c+(a*d/c)*(a*d/c)
            let m=SIMD3(xy.x,xy.y,1)*(1-image[y*w+x].w)
            if (30...33).contains(y) { fg+=m } else { bg+=m }
        } }
        for axis in 0..<3 {
            XCTAssertEqual(e.foregroundMoment[axis],fg[axis],accuracy:0.002)
            XCTAssertEqual(e.backgroundMoment[axis],bg[axis],accuracy:0.002)
        }
        let factors=TrainingSubjectSurface.axisFactors(e)
        XCTAssertEqual(factors.x,1,"Keep the supported long direction of a strand")
        XCTAssertLessThan(factors.y,1,"Narrow only visible unsupported transverse tails")
        XCTAssertGreaterThanOrEqual(factors.y,0.85)
        XCTAssertEqual(factors.z,1,"Depth is unobserved in this view, not evidence for shrinkage")
        XCTAssertEqual(trainer.checkpointBuffers.map { Data(bytes:$0.contents(),count:$0.length) },snapshot)
        let unknown=GaussianTrainer.SubjectBoundaryEvidence(foreground:0.2,background:0.3,foregroundMoment:.zero,backgroundMoment:SIMD3(repeating:10))
        XCTAssertEqual(TrainingSubjectSurface.axisFactors(unknown),SIMD3(repeating:1))
    }

    func testMemoryPolicyAndHeldOutViews() throws {
        let mib = 1024 * 1024
        let high = try TrainingQualityPlan.make(physicalMemory: 8 * 1024 * 1024 * 1024, availableMemory: 2048 * mib)
        let low = try TrainingQualityPlan.make(physicalMemory: 6 * 1024 * 1024 * 1024, availableMemory: 512 * mib)
        XCTAssertEqual(high.limits.longSide, 768)
        XCTAssertEqual(low.limits.longSide, 384)
        XCTAssertLessThan(low.metalBudget, high.metalBudget)
        XCTAssertLessThanOrEqual(high.limits.maxFrames * 768 * 768 * 4, 256 * mib)
        XCTAssertThrowsError(try TrainingQualityPlan.make(physicalMemory: 8 * 1024 * 1024 * 1024, availableMemory: 200 * mib))
        let split = TrainingQualityPlan.splitViews(count: 32)
        XCTAssertEqual(split.validation, [7, 15, 23, 31])
        XCTAssertTrue(Set(split.train).isDisjoint(with: split.validation))
        XCTAssertEqual(split.train.count + split.validation.count, 32)
        XCTAssertEqual(TrainingQualityPlan.resolutionDivisor(iteration: 899, total: 3000), 2)
        XCTAssertEqual(TrainingQualityPlan.resolutionDivisor(iteration: 900, total: 3000), 1)
    }

    func testRelocationPreservesCentreAndProfileMass() {
        for old: Float in [0.01, 0.3, 0.9] { for copies in [2, 8, 10000] {
            let split = GaussianTrainer.relocation(opacity: old, copies: copies)
            let center = -expm1(Double(copies) * log1p(-Double(split.opacity)))
            XCTAssertEqual(center, Double(old), accuracy: 1e-6)
            XCTAssertGreaterThan(split.scale, 0)
            XCTAssertLessThan(split.scale, 1)
            // Independent midpoint quadrature in the scaled spatial coordinate.
            let h = 0.002
            var integral = 0.0
            for i in 0..<4000 {
                let x = (Double(i) + 0.5) * h
                integral += -expm1(Double(copies) * log1p(-Double(split.opacity) * exp(-x*x/(2*Double(split.scale*split.scale)))))
            }
            integral *= 2*h/sqrt(2*Double.pi)
            XCTAssertEqual(integral, Double(old), accuracy: 1e-5)
        } }
    }

    /// Independent Double reference: local moments, no analytic-gradient formula reuse.
    private func structuralLoss(_ pixels: [SIMD4<Float>], target: Data, w: Int, h: Int, lambda: Double, subject: Bool = false) -> Double {
        let bytes = [UInt8](target)
        let fraction = (0..<(w*h)).reduce(0.0) { $0 + Double(bytes[$1*4+3])/255 } / Double(w*h)
        var result = 0.0
        for y in 0..<h { for x in 0..<w { for c in 0..<3 {
            var a=0.0,b=0.0,aa=0.0,bb=0.0,ab=0.0,n=0.0
            for qy in max(0,y-2)...min(h-1,y+2) { for qx in max(0,x-2)...min(w-1,x+2) {
                let weight=exp(-Double((qx-x)*(qx-x)+(qy-y)*(qy-y))/2)
                let p=Double(pixels[qy*w+qx][c]), t=Double(bytes[(qy*w+qx)*4+c])/255
                a+=weight*p;b+=weight*t;aa+=weight*p*p;bb+=weight*t*t;ab+=weight*p*t;n+=weight
            } }
            a/=n;b/=n;aa/=n;bb/=n;ab/=n
            let score=(2*a*b+0.0001)*(2*(ab-a*b)+0.0009)/((a*a+b*b+0.0001)*(aa-a*a+bb-b*b+0.0009))
            let mask = Double(bytes[(y*w+x)*4+3])/255
            let weight = subject ? 0.85*mask/fraction + 0.15*(1-mask)/(1-fraction) : 1
            result += weight*((1-lambda)*abs(Double(pixels[y*w+x][c])-Double(bytes[(y*w+x)*4+c])/255)+lambda*(1-score))
        } } }
        return result/Double(w*h*3)
    }

    func testStructuralLossMatchesCPUAndFiniteDifferencesIncludingEdges() throws {
        let (device, library) = try gpu()
        let w=9,h=7
        var bytes=[UInt8](repeating:255,count:w*h*4)
        var pixels=[SIMD4<Float>]()
        for i in 0..<(w*h) {
            pixels.append(SIMD4(0.1+Float(i%9)*0.07,0.8-Float(i%7)*0.08,0.4+Float(i%3)*0.1,0))
            for c in 0..<3 { bytes[i*4+c]=UInt8((i*31+c*57)%200+20) }
        }
        let target=Data(bytes)
        let camera=TrainingCamera(cameraToWorld: matrix_identity_float4x4,fx:10,fy:10,cx:4,cy:3,imageIndex:0)
        let trainer=try GaussianTrainer(device:device,library:library,
            seeds:[GaussianSeed(position:SIMD3(0,0,-1),size:0.03,color:SIMD3(repeating:0.5))],cameras:[camera],
            targets:target,width:w,height:h)
        let analytic=try trainer.pixelLoss(rendered:pixels,cameraIndex:0)
        XCTAssertEqual(Double(analytic.value), structuralLoss(pixels,target:target,w:w,h:h,lambda:0.2),accuracy:2e-6)
        for i in [0,8,31,54,62] { for c in 0..<3 {
            var plus=pixels,minus=pixels
            plus[i][c]+=0.001; minus[i][c]-=0.001
            let numeric=(structuralLoss(plus,target:target,w:w,h:h,lambda:0.2)-structuralLoss(minus,target:target,w:w,h:h,lambda:0.2))/0.002
            XCTAssertEqual(Double(analytic.gradient[i][c]),numeric,accuracy:2e-5)
        } }
        XCTAssertEqual(trainer.targetBufferBytes,w*h*8)
        XCTAssertLessThan(trainer.sortingCapacity,1000,"no 96 MB eager sorting allocation")
    }

    func testSubjectWeightedLossMatchesIndependentCPUAndGradients() throws {
        let (device, library) = try gpu()
        let w = 9, h = 7
        var bytes = [UInt8](repeating: 255, count: w*h*4)
        var pixels: [SIMD4<Float>] = []
        for i in 0..<(w*h) {
            pixels.append(SIMD4(0.1+Float(i%9)*0.07,0.8-Float(i%7)*0.08,0.4+Float(i%3)*0.1,0))
            for c in 0..<3 { bytes[i*4+c] = UInt8((i*31+c*57)%200+20) }
            bytes[i*4+3] = i%9 < 3 ? 255 : (i%9 == 3 ? 128 : 0)
        }
        let target = Data(bytes)
        let camera = TrainingCamera(cameraToWorld: matrix_identity_float4x4,fx:10,fy:10,cx:4,cy:3,imageIndex:0)
        for lambda: Float in [0,0.2] {
            var config = GaussianTrainer.Config();config.subjectWeighting = true;config.structuralWeight = lambda
            let trainer = try GaussianTrainer(device: device,library: library,
                seeds:[GaussianSeed(position:SIMD3(0,0,-1),size:0.03,color:SIMD3(repeating:0.5))],
                cameras:[camera],targets:target,width:w,height:h,config:config)
            let analytic = try trainer.pixelLoss(rendered:pixels,cameraIndex:0)
            XCTAssertEqual(Double(analytic.value),structuralLoss(pixels,target:target,w:w,h:h,lambda:Double(lambda),subject:true),accuracy:3e-6)
            for i in [0,3,8,31,54,62] { for c in 0..<3 {
                var plus=pixels,minus=pixels;plus[i][c]+=0.001;minus[i][c]-=0.001
                let numeric=(structuralLoss(plus,target:target,w:w,h:h,lambda:Double(lambda),subject:true)-structuralLoss(minus,target:target,w:w,h:h,lambda:Double(lambda),subject:true))/0.002
                XCTAssertEqual(Double(analytic.gradient[i][c]),numeric,accuracy:3e-5)
            } }
        }
    }

    func testProgressiveResolutionKeepsCalibrationAndOptimizerStep() throws {
        let (device, library) = try gpu()
        let w=32,h=24
        let cameras=(0..<4).map { TrainingCamera(cameraToWorld:matrix_identity_float4x4,fx:30,fy:31,cx:15.5,cy:11.5,imageIndex:$0) }
        let trainer=try GaussianTrainer(device:device,library:library,
            seeds:[GaussianSeed(position:SIMD3(0,0,-1),size:0.03,color:SIMD3(repeating:0.5))],cameras:cameras,
            targets:Data(repeating:100,count:w*h*4*4),width:w,height:h)
        try trainer.setTrainingViews([0,2,3])
        trainer.setResolution(divisor:2)
        let camera=trainer.scaledCamera(cameras[0])
        XCTAssertEqual(camera.fx,15);XCTAssertEqual(camera.cx,7.5);XCTAssertEqual(camera.cy,5.5)
        let matching=Array(repeating:SIMD4<Float>(100/255,100/255,100/255,0),count:16*12)
        XCTAssertEqual(try trainer.pixelLoss(rendered:matching,cameraIndex:0).value,0,accuracy:2e-5)
        var seen=Set<Int>()
        for _ in 0..<3 { try trainer.trainStep(); seen.insert(try XCTUnwrap(trainer.lastCameraIndex)) }
        XCTAssertEqual(seen,[0,2,3])
        trainer.setResolution(divisor:1)
        XCTAssertEqual(trainer.step,3)
        XCTAssertEqual(try trainer.render(cameraIndex:0).count,w*h)
        XCTAssertEqual(trainer.targetBufferBytes,w*h*8,"GPU target memory is independent of frame count")
        var tiny=GaussianTrainer.Config();tiny.memoryBudgetBytes=64
        XCTAssertThrowsError(try GaussianTrainer(device:device,library:library,
            seeds:[GaussianSeed(position:SIMD3(0,0,-1),size:0.03,color:.zero)],cameras:cameras,
            targets:Data(count:w*h*4*4),width:w,height:h,config:tiny))
    }

    func testOneKeyframeCannotOfferLocalTraining() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let capture = folder.appendingPathComponent("capture")
        try FileManager.default.createDirectory(at:capture,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:folder) }
        try Data("placeholder".utf8).write(to:capture.appendingPathComponent("points3d.ply"))
        try JSONSerialization.data(withJSONObject:["frames":[["file_path":"image.jpg"]]])
            .write(to:capture.appendingPathComponent("transforms.json"))
        XCTAssertFalse(TrainingDataset.available(scanFolder:folder))
        XCTAssertEqual(TrainingDataset.unavailableReason(scanFolder:folder),"只有 1 张关键帧，至少需要 8 张")
    }

    /// Opt-in private-data acceptance. Reads an existing package on the phone, trains only in
    /// memory, exports no images/models and never modifies the user's scan or existing result.
    func testExistingScanHeldOutViews() throws {
        guard let id = ProcessInfo.processInfo.environment["POCKETWORLD_LOCAL_TRAINING_SCAN"],
              UUID(uuidString: id) != nil else { throw XCTSkip("Opt-in real scan acceptance") }
        let (device, library) = try gpu()
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let folder = root.appendingPathComponent("ScanPackages/\(id).scan")
        let dataset = try TrainingDataset.load(scanFolder: folder,
            limits: .init(maxFrames: 32, longSide: 384, maxGaussians: 40_000))
        let split = TrainingQualityPlan.splitViews(count: dataset.cameras.count)
        XCTAssertFalse(split.validation.isEmpty)
        var config = GaussianTrainer.Config(); config.iterations = 600
        let trainer = try GaussianTrainer(device: device, library: library, seeds: dataset.seeds, cameras: dataset.cameras,
            targets: dataset.targets, width: dataset.width, height: dataset.height, config: config)
        try trainer.setTrainingViews(split.train)
        let before = try TrainingViewMetrics.evaluate(trainer: trainer, dataset: dataset, indices: split.validation)
        let start = Date()
        var peak = trainer.workingSetBytes
        for i in 1...config.iterations {
            trainer.setResolution(divisor: TrainingQualityPlan.resolutionDivisor(iteration: i, total: config.iterations))
            try autoreleasepool { try trainer.trainStep(cameraIndex: split.train[(i - 1) % split.train.count]) }
            peak = max(peak, trainer.workingSetBytes)
        }
        let after = try TrainingViewMetrics.evaluate(trainer: trainer, dataset: dataset, indices: split.validation)
        print(String(format: "LOCAL_REAL_CHECK views=%d held=%d seeds=%d PSNR=%.2f->%.2f MAE=%.4f->%.4f seconds=%.1f metalMiB=%.1f",
            dataset.cameras.count, after.views, dataset.seeds.count, before.psnr, after.psnr, before.mae, after.mae,
            Date().timeIntervalSince(start), Double(peak)/1048576))
        XCTAssertLessThan(after.mae, before.mae, "Real held-out views should improve over LiDAR initialisation")
        XCTAssertGreaterThan(after.psnr, before.psnr)
    }

    func testMCMCDisplacementScalesWithCovarianceNotStandardDeviation() throws {
        guard let device = MTLCreateSystemDefaultDevice(), device.supportsFamily(.apple7),
              let library = device.makeDefaultLibrary() else { throw XCTSkip("Requires an Apple GPU") }
        let pipeline = try device.makeComputePipelineState(function: XCTUnwrap(library.makeFunction(name: "adam")))
        func perturb(_ size: Float) throws -> SIMD3<Float> {
            let buffers = (0..<10).map { _ in device.makeBuffer(length: 64, options: .storageModeShared)! }
            for buffer in buffers { memset(buffer.contents(), 0, 64) }
            buffers[1].contents().storeBytes(of: SIMD4<Float>(repeating: log(size)), as: SIMD4<Float>.self)
            buffers[2].contents().storeBytes(of: SIMD4<Float>(1,0,0,0), as: SIMD4<Float>.self)
            buffers[3].contents().storeBytes(of: SIMD4<Float>(0,0,0,-10), as: SIMD4<Float>.self)
            var p = AdamUniform(lrMean: .zero, lrScale: .zero, lrQuat: .zero, lrColorOp: .zero,
                                beta1: 0.9, beta2: 0.999, epsilon: 1e-8, bc1: 0.1, bc2: 0.001, noiseScale: 1, step: 1, pad: 0)
            var count: UInt32 = 1
            let command = try XCTUnwrap(device.makeCommandQueue()?.makeCommandBuffer())
            let encoder = try XCTUnwrap(command.makeComputeCommandEncoder())
            encoder.setComputePipelineState(pipeline)
            for (i,b) in buffers.enumerated() { encoder.setBuffer(b, offset: 0, index: i) }
            encoder.setBytes(&p, length: MemoryLayout<AdamUniform>.stride, index: 10)
            encoder.setBytes(&count, length: 4, index: 11)
            encoder.dispatchThreads(MTLSize(width: 1, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
            encoder.endEncoding(); command.commit(); command.waitUntilCompleted()
            XCTAssertEqual(command.status, .completed)
            let result = buffers[0].contents().load(as: SIMD4<Float>.self)
            return SIMD3(result.x, result.y, result.z)
        }
        let small = try perturb(0.01), large = try perturb(0.02)
        XCTAssertGreaterThan(simd_length(small), 0)
        XCTAssertLessThan(simd_length(large - small * 4), 1e-7, "doubling sigma quadruples covariance-weighted noise")
        XCTAssertLessThan(simd_length(small), 0.001, "centimetre splats must not jump centimetres")
    }

    private func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("OnDeviceTrainingTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func lookAt(_ eye: SIMD3<Float>, _ target: SIMD3<Float>) -> simd_float4x4 {
        let back = simd_normalize(eye - target), right = simd_normalize(simd_cross(SIMD3(0, 1, 0), back))
        return simd_float4x4(columns: (SIMD4(right, 0), SIMD4(simd_cross(back, right), 0), SIMD4(back, 0), SIMD4(eye, 1)))
    }

    /// A `<scan>/capture/` folder with 12 solid-colour 640×480 keyframes and a small point cloud.
    private func package(frames: Int = 12, points: Int = 500) throws -> URL {
        let scan = try scratch().appendingPathComponent("scan.scan")
        let capture = scan.appendingPathComponent("capture")
        try FileManager.default.createDirectory(at: capture.appendingPathComponent("images"), withIntermediateDirectories: true)
        var entries: [[String: Any]] = []
        for k in 0..<frames {
            let name = String(format: "images/frame_%05d.jpg", k + 1)
            // Raw sRGB bytes (204, 51, k·10), as a keyframe JPEG would hold them.
            let context = CGContext(data: nil, width: 640, height: 480, bitsPerComponent: 8, bytesPerRow: 640 * 4,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            let pixels = context.data!.bindMemory(to: UInt8.self, capacity: 640 * 480 * 4)
            for i in 0..<(640 * 480) { pixels[i * 4] = 204; pixels[i * 4 + 1] = 51; pixels[i * 4 + 2] = UInt8(k * 10) }
            let destination = CGImageDestinationCreateWithURL(capture.appendingPathComponent(name) as CFURL,
                                                              UTType.jpeg.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(destination, context.makeImage()!, nil)
            XCTAssertTrue(CGImageDestinationFinalize(destination))
            let a = Float(k) / Float(frames) * 2 * .pi
            let m = lookAt(SIMD3(sin(a), 0.5, cos(a)), .zero)
            entries.append(["file_path": name, "transform_matrix": (0..<4).map { r in (0..<4).map { c in Double(m[c][r]) } },
                            "fl_x": 500.0, "fl_y": 500.0, "cx": 319.5, "cy": 239.5, "w": 640, "h": 480,
                            "timestamp": 50 + Double(k) * 0.2, "subject_moving": k == 3])
        }
        try JSONSerialization.data(withJSONObject: ["frames": entries]).write(to: capture.appendingPathComponent("transforms.json"))
        try JSONSerialization.data(withJSONObject: ["points3d": ["voxel_m": 0.02]]).write(to: capture.appendingPathComponent("meta.json"))
        let cloud = (0..<points).map { i in
            (position: SIMD3<Float>(Float(i % 10) * 0.02, Float(i / 10 % 10) * 0.02, Float(i / 100) * 0.02), color: SIMD3<UInt8>(200, 50, 100))
        }
        XCTAssertTrue(TrainingPackageWriter.writePLY(cloud, to: capture.appendingPathComponent("points3d.ply")))
        return scan
    }

    func testPublicationReplacesCompleteResultAndCancellationKeepsPrevious() async throws {
        let folder = try scratch(), final = folder.appendingPathComponent("ondevice")
        func staged(_ name: String, _ contents: String) throws -> URL {
            let dir = folder.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data(contents.utf8).write(to: dir.appendingPathComponent("scene.ply"))
            return dir
        }
        try OnDeviceTrainingStore.publish(staging: staged("first", "old"), final: final)
        try OnDeviceTrainingStore.publish(staging: staged("second", "new"), final: final)
        XCTAssertEqual(try String(contentsOf: final.appendingPathComponent("scene.ply"), encoding: .utf8), "new")
        let history = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix("ondevice.previous.") }
        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(try String(contentsOf: history[0].appendingPathComponent("scene.ply"), encoding: .utf8), "old")
        let cancelled = try staged("cancelled", "incomplete")
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try OnDeviceTrainingStore.publish(staging: cancelled, final: final)
        }
        do { try await task.value; XCTFail("Cancelled training must not replace the result") }
        catch is CancellationError {} 
        XCTAssertEqual(try String(contentsOf: final.appendingPathComponent("scene.ply"), encoding: .utf8), "new")
    }

    func testDatasetLoadsKeyframesPosesAndPoints() throws {
        let scan = try package(frames: 20)
        XCTAssertTrue(TrainingDataset.available(scanFolder: scan))
        let dataset = try TrainingDataset.load(scanFolder: scan, limits: .init(maxFrames: 160, longSide: 320, maxGaussians: 300))
        XCTAssertEqual(dataset.width, 320)
        XCTAssertEqual(dataset.height, 240)
        XCTAssertEqual(dataset.cameras.count, 19, "the frame where the person moved is skipped")
        XCTAssertEqual(dataset.targets.count, 320 * 240 * 4 * 19)
        XCTAssertEqual(dataset.cameras[0].fx, 250, accuracy: 1e-4)
        XCTAssertEqual(dataset.cameras[0].cx, 159.5, accuracy: 1e-4, "pixel centres stay at integers")
        // Camera 0 sits at (0, 0.5, 1) looking at the origin.
        XCTAssertLessThan(simd_length(dataset.cameras[0].center - SIMD3(0, 0.5, 1)), 1e-4)
        XCTAssertEqual(dataset.seeds.count, 250, "subsampled to at most 300")
        XCTAssertEqual(dataset.seeds[0].color.x, 200 / 255, accuracy: 1e-5)
        // The first pixel of the first keyframe keeps its colour (no flips or channel swaps).
        dataset.targets.withUnsafeBytes { raw in
            let b = raw.bindMemory(to: UInt8.self)
            XCTAssertEqual(Int(b[0]), 204, accuracy: 3)
            XCTAssertEqual(Int(b[1]), 51, accuracy: 3)
        }
        XCTAssertThrowsError(try TrainingDataset.load(scanFolder: try scratch()))
    }

    func testOutputIsAStandardPLYAndAValidCameraPath() throws {
        let folder = try scratch()
        let means = [SIMD4<Float>(0, 0, 0, 0), SIMD4(1, 2, 3, 0), SIMD4(0.5, 0.5, 0.5, 0)]
        let colorOp = [SIMD4<Float>(0.1, 0.2, 0.3, 2), SIMD4(0, 0, 0, -9), SIMD4(0, 0, 0, 0)]
        let kept = try TrainingOutput.writePLY(means: means, logScales: Array(repeating: SIMD4(-4, -4, -4, 0), count: 3),
                                               quats: Array(repeating: SIMD4(2, 0, 0, 0), count: 3), colorOp: colorOp,
                                               to: folder.appendingPathComponent("scene.ply"))
        XCTAssertEqual(kept, 2, "the nearly transparent splat is dropped")
        let data = try Data(contentsOf: folder.appendingPathComponent("scene.ply"))
        let end = try XCTUnwrap(data.range(of: Data("end_header\n".utf8)))
        let header = String(decoding: data[..<end.lowerBound], as: UTF8.self)
        XCTAssertTrue(header.contains("element vertex 2"))
        for name in ["f_dc_0", "opacity", "scale_2", "rot_3"] { XCTAssertTrue(header.contains("property float \(name)")) }
        XCTAssertEqual(data.count - end.upperBound, 2 * 17 * 4)
        let rot0 = data[(end.upperBound + 13 * 4)..<(end.upperBound + 14 * 4)].withUnsafeBytes { $0.loadUnaligned(as: Float.self) }
        XCTAssertEqual(rot0, 1, accuracy: 1e-6, "quaternions are written normalised")

        let scan = try package(frames: 9)
        let dataset = try TrainingDataset.load(scanFolder: scan, limits: .init(maxFrames: 160, longSide: 160, maxGaussians: 1000))
        try TrainingOutput.writeCameras(dataset.frames, to: folder.appendingPathComponent("cameras.json"))
        let path = try JSONDecoder().decode(SceneCameraPath.self, from: Data(contentsOf: folder.appendingPathComponent("cameras.json"))).validated()
        XCTAssertEqual(path.frames.count, 9, "with few still frames every keyframe is kept")
        XCTAssertEqual(path.frames[0].timeSeconds, 0)
    }

    /// Runs only where the GPU supports float atomics (Apple7+); the simulator may not.
    func testShortTrainingImprovesTheFit() throws {
        guard let device = MTLCreateSystemDefaultDevice(), device.supportsFamily(.apple7),
              let library = device.makeDefaultLibrary(), library.makeFunction(name: "rasterizeBackward") != nil else {
            throw XCTSkip("This GPU cannot run the training kernels.")
        }
        let W = 64, H = 48
        var truth: [GaussianSeed] = []
        for i in 0..<400 {
            let a = Float(i) * 0.37
            truth.append(GaussianSeed(position: SIMD3(0.3 * sin(a), Float(i % 20) * 0.02 - 0.2, 0.3 * cos(a)), size: 0.03,
                                      color: SIMD3(0.5 + 0.5 * sin(a), 0.4, 0.6)))
        }
        let cameras = (0..<8).map { k -> TrainingCamera in
            let a = Float(k) / 8 * 2 * .pi
            return TrainingCamera(cameraToWorld: lookAt(SIMD3(1.4 * sin(a), 0.3, 1.4 * cos(a)), .zero), fx: 60, fy: 60, cx: 31.5, cy: 23.5, imageIndex: k)
        }
        let gt: GaussianTrainer
        do {
            gt = try GaussianTrainer(device: device, library: library, seeds: truth, cameras: cameras,
                                     targets: Data(count: W * H * 4 * 8), width: W, height: H)
        } catch { throw XCTSkip("Training pipelines are unavailable here: \(error)") }
        var targets = Data(count: W * H * 4 * 8)
        for k in 0..<8 {
            let image = try gt.render(cameraIndex: k)
            targets.withUnsafeMutableBytes { raw in
                let b = raw.bindMemory(to: UInt8.self)
                for i in 0..<(W * H) { for c in 0..<3 { b[(k * W * H + i) * 4 + c] = UInt8(max(0, min(255, (image[i][c] * 255).rounded()))) } }
            }
        }
        let start = truth.map { GaussianSeed(position: $0.position + SIMD3(0.02, -0.02, 0.01), size: 0.03, color: SIMD3(repeating: 0.5)) }
        var config = GaussianTrainer.Config(); config.iterations = 300
        let trainer = try GaussianTrainer(device: device, library: library, seeds: start, cameras: cameras, targets: targets,
                                          width: W, height: H, config: config)
        let before = try trainer.trainStep(cameraIndex: 0, measure: true).meanAbsError ?? 1
        for i in 0..<config.iterations { try trainer.trainStep(cameraIndex: i % 8) }
        let after = try trainer.trainStep(cameraIndex: 0, measure: true).meanAbsError ?? 1
        XCTAssertLessThan(after, before * 0.5, "mean absolute error \(before) → \(after)")
    }
}

extension OnDeviceTrainingTests {
    @MainActor
    private func waitFor(_ store: OnDeviceTrainingStore, until condition: () -> Bool, seconds: Double = 40) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            if Date() > deadline { XCTFail("Timeout: \(store.phases)"); throw GaussianTrainerError.invalidInput }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @MainActor
    func testBackgroundCheckpointRelaunchContinueAndDiscardPreserveOldResult() async throws {
        _ = try gpu()
        let scan = try package(frames: 8, points: 300)
        let final = scan.appendingPathComponent("ondevice")
        try FileManager.default.createDirectory(at: final, withIntermediateDirectories: true)
        let original = Data("completed result remains untouched".utf8)
        try original.write(to: final.appendingPathComponent("scene.ply"))
        let suite = "resume-tests-\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let plan = TrainingQualityPlan(limits: .init(maxFrames: 8, longSide: 64, maxGaussians: 300), metalBudget: 64*1024*1024, pairLimit: 200_000)
        func store() -> OnDeviceTrainingStore {
            OnDeviceTrainingStore(defaults: defaults, folderResolver: { _ in scan }, plan: plan, iterations: 3000, managesApplication: false)
        }
        let first = store()
        first.start(captureID: "test")
        try await waitFor(first, until: { if case .training = first.phases["test"] { true } else { false } })
        first.appWillResignActive()
        try await waitFor(first, until: { !first.isTraining })
        let saved = try XCTUnwrap(TrainingCheckpoint.read(scan))
        XCTAssertGreaterThan(saved.state.step, 0); XCTAssertLessThan(saved.state.step, 3000)
        XCTAssertEqual(try Data(contentsOf: final.appendingPathComponent("scene.ply")), original)
        // A newly created store represents process relaunch. It must use the same session/Adam.
        let second = store()
        XCTAssertTrue(second.hasProgress("test"))
        second.appDidBecomeActive()
        try await waitFor(second, until: {
            if case .training(let progress, _, _) = second.phases["test"] { return progress > Double(saved.state.step)/3000 }
            return false
        })
        second.pause()
        try await waitFor(second, until: { !second.isTraining })
        let resumed = try XCTUnwrap(TrainingCheckpoint.read(scan))
        XCTAssertEqual(resumed.session.id, saved.session.id)
        XCTAssertGreaterThan(resumed.state.step, saved.state.step)
        XCTAssertEqual(try Data(contentsOf: final.appendingPathComponent("scene.ply")), original)
        // Manual pause remains paused after reactivation; it is not a second hidden worker.
        second.appDidBecomeActive()
        XCTAssertFalse(second.isTraining)
        await second.cancelIfTraining(captureID: "test")
        second.appDidBecomeActive()
        XCTAssertFalse(second.isTraining); XCTAssertFalse(TrainingCheckpoint.exists(scan))
        XCTAssertFalse(store().hasProgress("test"))
        XCTAssertEqual(try Data(contentsOf: final.appendingPathComponent("scene.ply")), original)
        print("RESUME_STORE originalStep=\(saved.state.step) resumedStep=\(resumed.state.step) oldResult=unchanged")
    }

    @MainActor
    func testRapidForegroundReturnAndChangedSourceAreSafe() async throws {
        _ = try gpu()
        let scan = try package(frames: 8, points: 300)
        let suite = "resume-rapid-\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let plan = TrainingQualityPlan(limits: .init(maxFrames:8,longSide:64,maxGaussians:300),metalBudget:64*1024*1024,pairLimit:200_000)
        let store = OnDeviceTrainingStore(defaults:defaults,folderResolver:{ _ in scan },plan:plan,iterations:2000,managesApplication:false)
        store.start(captureID:"test")
        try await waitFor(store,until:{ if case .training = store.phases["test"] { true } else { false } })
        store.appWillResignActive(); store.appDidBecomeActive()
        try await Task.sleep(for:.milliseconds(100))
        store.pause()
        try await waitFor(store,until:{ !store.isTraining })
        let saved = try XCTUnwrap(TrainingCheckpoint.read(scan))
        // Adding trailing JPEG bytes leaves decoding intact, but exact source lineage changes.
        let url=scan.appendingPathComponent("capture/images/frame_00001.jpg")
        var image=try Data(contentsOf:url); image.append(0); try image.write(to:url)
        store.start(captureID:"test")
        try await waitFor(store,until:{ !store.isTraining })
        guard case .failed(let message) = store.phases["test"] else { return XCTFail("Changed input must not silently restart") }
        XCTAssertTrue(message.contains("素材已变化"))
        XCTAssertEqual(try TrainingCheckpoint.read(scan)?.generation,saved.generation)
        await store.cancelIfTraining(captureID:"test")
    }
}

extension OnDeviceTrainingTests {
    @MainActor
    func testResumedTrainingFinishesOnceAndArchivesPreviousResult() async throws {
        _ = try gpu()
        let scan = try package(frames:8,points:300)
        let final=scan.appendingPathComponent("ondevice")
        try FileManager.default.createDirectory(at:final,withIntermediateDirectories:true)
        let old=Data("old completed model".utf8)
        try old.write(to:final.appendingPathComponent("scene.ply"))
        let suite="resume-publish-\(UUID())",defaults=UserDefaults(suiteName:suite)!
        defer { defaults.removePersistentDomain(forName:suite) }
        let plan=TrainingQualityPlan(limits:.init(maxFrames:8,longSide:64,maxGaussians:300),metalBudget:64*1024*1024,pairLimit:200_000)
        let store=OnDeviceTrainingStore(defaults:defaults,folderResolver:{ _ in scan },plan:plan,iterations:800,managesApplication:false)
        store.start(captureID:"test")
        try await waitFor(store,until:{ if case .training = store.phases["test"] { true } else { false } })
        store.appWillResignActive()
        try await waitFor(store,until:{ !store.isTraining })
        let snapshot=try XCTUnwrap(TrainingCheckpoint.read(scan))
        XCTAssertGreaterThan(snapshot.state.step,0)
        XCTAssertEqual(try Data(contentsOf:final.appendingPathComponent("scene.ply")),old)
        store.appDidBecomeActive()
        try await waitFor(store,until:{ !store.isTraining })
        XCTAssertNil(store.phases["test"])
        XCTAssertEqual(store.result(captureID:"test")?.iterations,800)
        XCTAssertFalse(store.hasProgress("test")); XCTAssertFalse(TrainingCheckpoint.exists(scan))
        let meta=try Data(contentsOf:final.appendingPathComponent("meta.json"))
        let object=try XCTUnwrap(JSONSerialization.jsonObject(with:meta) as? [String:Any])
        XCTAssertEqual(object["trainingSessionID"] as? String,snapshot.session.id.uuidString)
        let backups=try FileManager.default.contentsOfDirectory(at:scan,includingPropertiesForKeys:nil).filter { $0.lastPathComponent.hasPrefix("ondevice.previous.") }
        XCTAssertEqual(backups.count,1)
        XCTAssertEqual(try Data(contentsOf:backups[0].appendingPathComponent("scene.ply")),old)
        store.appDidBecomeActive()
        XCTAssertFalse(store.isTraining)
        XCTAssertEqual(try Data(contentsOf:final.appendingPathComponent("meta.json")),meta)
        print("RESUME_FINISH resumedFrom=\(snapshot.state.step) final=800 session=unchanged previous=preserved")
    }
}

extension OnDeviceTrainingTests {
    @MainActor
    func testExplicitRetrainCreatesFreshSessionAndKeepsCompletedModel() async throws {
        _ = try gpu()
        let scan = try package(frames:8,points:300)
        let final=scan.appendingPathComponent("ondevice")
        try FileManager.default.createDirectory(at:final,withIntermediateDirectories:true)
        let old=Data("previous completed result".utf8)
        try old.write(to:final.appendingPathComponent("scene.ply"))
        try Data("{}".utf8).write(to:final.appendingPathComponent("cameras.json"))
        try Data("{\"iterations\":3000,\"gaussians\":42}".utf8).write(to:final.appendingPathComponent("meta.json"))
        let suite="retrain-tests-\(UUID())", defaults=UserDefaults(suiteName:suite)!
        defer { defaults.removePersistentDomain(forName:suite) }
        let plan=TrainingQualityPlan(limits:.init(maxFrames:8,longSide:64,maxGaussians:300),metalBudget:64*1024*1024,pairLimit:200_000)
        let store=OnDeviceTrainingStore(defaults:defaults,folderResolver:{ _ in scan },plan:plan,iterations:800,managesApplication:false)
        XCTAssertNotNil(store.result(captureID:"test"))
        await store.restart(captureID:"test")
        try await waitFor(store,until:{ if case .training = store.phases["test"] { true } else { false } })
        store.pause()
        try await waitFor(store,until:{ !store.isTraining })
        let previousJob=try XCTUnwrap(TrainingCheckpoint.read(scan))
        XCTAssertEqual(try Data(contentsOf:final.appendingPathComponent("scene.ply")),old)
        await store.restart(captureID:"test") // Explicit restart must not replay the paused job.
        try await waitFor(store,until:{ if case .training = store.phases["test"] { true } else { false } })
        let newJob=try XCTUnwrap(TrainingCheckpoint.read(scan))
        XCTAssertNotEqual(newJob.session.id,previousJob.session.id)
        XCTAssertEqual(store.result(captureID:"test")?.gaussians,42)
        try await waitFor(store,until:{ !store.isTraining })
        XCTAssertNil(store.phases["test"])
        XCTAssertEqual(store.result(captureID:"test")?.iterations,800)
        let archived=try XCTUnwrap(store.previousResult(captureID:"test"))
        XCTAssertEqual(try Data(contentsOf:archived.model),old)
        XCTAssertNotEqual(archived.id,store.result(captureID:"test")?.id)
        XCTAssertFalse(store.hasProgress("test"))
        print("LOCAL_RETRAIN fresh_session=true published_old_preserved=true")
    }
}
