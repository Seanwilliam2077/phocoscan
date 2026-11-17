import Foundation
import Metal
import simd

/// A separate, reversible subject derivative. Full-scene trained parameters are never changed.
/// Only training views vote: held-out masks cannot be used to improve their own evaluation.
enum TrainingSubjectSurface {
    static let version = 4
    struct Selection {
        let indices: [Int]
        let views: Int
        let unsupportedCenters: Int
        let unsupportedExtents: Int
        var unsupportedAppearance: Int = 0
        var scaleFactors: [SIMD3<Float>] = []
        var narrowed: Int = 0
        var harmfulTails: Int = 0
    }
    struct Camera { var r0, r1, r2, t, intr: SIMD4<Float> }

    static func select(device: MTLDevice, library: MTLLibrary, dataset: TrainingDataset,
                       means: [SIMD4<Float>], logScales: [SIMD4<Float>], quats: [SIMD4<Float>],
                       control: TrainingRunControl, trainer: GaussianTrainer? = nil) throws -> Selection {
        guard !means.isEmpty, means.count == logScales.count, means.count == quats.count else {
            throw GaussianTrainerError.invalidInput
        }
        let eligible = TrainingQualityPlan.splitViews(count: dataset.cameras.count).train
        let chosen = TrainingFrameSelection.select(count: eligible.count, moving: Array(repeating: false, count: eligible.count), limit: 32).map { eligible[$0] }
        // Keep the conservative shape candidate, then test its actual visible contribution.
        // Tightening this mask alone would erase thin hair and specular strap details.
        let w = max(16, dataset.width / 4), h = max(16, dataset.height / 4)
        var masks = Data(), cameras: [Camera] = [], validIndices: [Int] = []
        for index in chosen {
            try control.check()
            var mask = Data(count: w * h)
            dataset.targets.withUnsafeBytes { source in
                let bytes = source.bindMemory(to: UInt8.self)
                let offset = dataset.cameras[index].imageIndex * dataset.width * dataset.height * 4
                for y in 0..<h { for x in 0..<w {
                    // Conservative 2x2 support; GPU additionally allows a one-cell border.
                    let sx = min(dataset.width-2, x * dataset.width / w)
                    let sy = min(dataset.height-2, y * dataset.height / h)
                    mask[y*w+x] = max(bytes[offset+(sy*dataset.width+sx)*4+3], bytes[offset+(sy*dataset.width+sx+1)*4+3],
                        bytes[offset+((sy+1)*dataset.width+sx)*4+3], bytes[offset+((sy+1)*dataset.width+sx+1)*4+3])
                } }
            }
            let mass = mask.reduce(0.0) { $0 + Double($1)/255 } / Double(mask.count)
            guard mass > 0.001, mass < 0.85 else { continue }
            masks.append(mask); validIndices.append(index)
            let c = dataset.cameras[index], sx = Float(w)/Float(dataset.width), sy = Float(h)/Float(dataset.height)
            cameras.append(Camera(r0: SIMD4(c.r0,0),r1:SIMD4(c.r1,0),r2:SIMD4(c.r2,0),t:SIMD4(c.t,0),
                intr:SIMD4(c.fx*sx,c.fy*sy,(c.cx+0.5)*sx-0.5,(c.cy+0.5)*sy-0.5)))
        }
        // Lack of consistent views is not evidence that the completed full scene is invalid.
        guard cameras.count >= 8 else { return Selection(indices:[],views:cameras.count,unsupportedCenters:0,unsupportedExtents:0) }
        guard let function = library.makeFunction(name:"subjectSupport"),
              let queue = device.makeCommandQueue(), let command = queue.makeCommandBuffer(),
              let encoder = command.makeComputeCommandEncoder() else { throw GaussianTrainerError.invalidInput }
        let pipeline = try device.makeComputePipelineState(function:function)
        func buffer<T>(_ values: [T]) throws -> MTLBuffer {
            try values.withUnsafeBytes { raw in
                guard let buffer = device.makeBuffer(bytes:raw.baseAddress!,length:raw.count,options:.storageModeShared) else {
                    throw GaussianTrainerError.memoryBudget
                }; return buffer
            }
        }
        let inputs = try [buffer(means),buffer(logScales),buffer(quats),buffer(cameras),buffer([UInt8](masks))]
        guard let votes = device.makeBuffer(length:means.count*16,options:.storageModeShared) else { throw GaussianTrainerError.memoryBudget }
        encoder.setComputePipelineState(pipeline)
        for (index, buffer) in inputs.enumerated() { encoder.setBuffer(buffer,offset:0,index:index) }
        encoder.setBuffer(votes,offset:0,index:5)
        var info = SIMD4(UInt32(means.count),UInt32(cameras.count),UInt32(w),UInt32(h))
        encoder.setBytes(&info,length:16,index:6)
        encoder.dispatchThreads(MTLSize(width:means.count,height:1,depth:1),threadsPerThreadgroup:MTLSize(width:128,height:1,depth:1))
        encoder.endEncoding(); try control.commit(command); command.waitUntilCompleted()
        if let error = command.error { throw error }
        try control.check()
        let result = votes.contents().bindMemory(to:SIMD4<Float>.self,capacity:means.count)
        var kept:[Int] = [], centers=0, extents=0, appearance=0
        for i in means.indices {
            let v=result[i]
            guard v.x >= 4, v.y >= max(3,v.x*0.65) else { centers += 1; continue }
            guard min(v.z,v.w) >= max(2,v.x*0.35) else { extents += 1; continue }
            kept.append(i)
        }
        var factors:[SIMD3<Float>]=[], narrowed=0, harmful=0
        if let trainer {
            guard trainer.count == means.count else { throw GaussianTrainerError.invalidInput }
            let evidence=try trainer.subjectBoundaryEvidence(cameraIndices:validIndices)
            let oldCount=kept.count
            kept=kept.filter {
                let e=evidence[$0], total=e.foreground+e.background
                // Soft silhouettes/anti-aliased hair can be mostly translucent. Require
                // only one-quarter foreground evidence; unseen splats are not proven bad.
                return total<0.5 || e.foreground>=total*0.25
            }
            appearance += oldCount-kept.count
            let supportedCount=kept.count
            kept=kept.filter {
                let e=evidence[$0],total=e.foreground+e.background
                // Only visibly spilling points whose individual removal improves
                // observed foreground colour. No white/yellow/brightness rule.
                return !(e.foreground>=2 && e.background>=2 && e.background>total*0.4
                    && e.removalCost < -0.001*e.foreground)
            }
            harmful=supportedCount-kept.count
            factors=kept.map { axisFactors(evidence[$0]) }
            narrowed=factors.filter { min($0.x,$0.y,$0.z)<1 }.count
        }
        return Selection(indices:kept,views:cameras.count,unsupportedCenters:centers,unsupportedExtents:extents,
            unsupportedAppearance:appearance,scaleFactors:factors,narrowed:narrowed,harmfulTails:harmful)
    }

    /// Only trim a direction whose visible foreground is concentrated near its centre
    /// while its tails visibly spill outside. Fine strands keep their supported long axis;
    /// unobserved axes, uncertain evidence and entirely foreground splats stay unchanged.
    static func axisFactors(_ e:GaussianTrainer.SubjectBoundaryEvidence) -> SIMD3<Float> {
        var result=SIMD3<Float>(repeating:1)
        guard e.foreground>=2,e.background>=2 else { return result }
        for axis in 0..<3 {
            let fg=e.foregroundMoment[axis]/e.foreground,bg=e.backgroundMoment[axis]/e.background
            if fg.isFinite,bg.isFinite,fg>=0,fg<0.8,bg>1.1,bg-fg>0.4 {
                result[axis]=max(0.85,sqrt(fg))
            }
        }
        return result
    }

    static func write(_ selection: Selection, means: [SIMD4<Float>], logScales: [SIMD4<Float>],
                      quats: [SIMD4<Float>], colorOp: [SIMD4<Float>], to url: URL) throws -> Int {
        guard selection.indices.count >= 100 else { throw TrainingSubject.Failure.insufficientMasks }
        let ids=selection.indices
        guard selection.scaleFactors.isEmpty || selection.scaleFactors.count == ids.count else { throw GaussianTrainerError.invalidInput }
        let scales=ids.enumerated().map { index,id -> SIMD4<Float> in
            var s=logScales[id]
            if !selection.scaleFactors.isEmpty { for axis in 0..<3 { s[axis] += log(selection.scaleFactors[index][axis]) } }
            return s
        }
        return try TrainingOutput.writePLY(means:ids.map { means[$0] },logScales:scales,
            quats:ids.map { quats[$0] },colorOp:ids.map { colorOp[$0] },to:url,dropBelowOpacity:0.02)
    }
}
