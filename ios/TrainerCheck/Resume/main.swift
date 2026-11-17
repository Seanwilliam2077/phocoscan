import Foundation
import Metal
import simd
let device = MTLCreateSystemDefaultDevice()!
let library = try device.makeLibrary(URL: URL(fileURLWithPath: CommandLine.arguments[1]))
let folder = FileManager.default.temporaryDirectory.appendingPathComponent("trainer-resume-\(UUID())")
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: folder) }
var config = GaussianTrainer.Config()
config.iterations = 80; config.noiseLR = 100; config.relocateEvery = 4; config.relocateFrom = 8
let cameras = (0..<3).map { i in
    var m = matrix_identity_float4x4; m.columns.3.x = Float(i) * 0.01
    return TrainingCamera(cameraToWorld: m, fx: 30, fy: 30, cx: 15.5, cy: 15.5, imageIndex: i)
}
let seeds = (0..<16).map { i in GaussianSeed(position: SIMD3(Float(i%4)*0.07-0.1,Float(i/4)*0.07-0.1,-1-Float(i)*0.01), size: 0.04, color: SIMD3(0.8,0.3,0.1)) }
func trainer() throws -> GaussianTrainer {
    try GaussianTrainer(device: device, library: library, seeds: seeds, cameras: cameras,
                        targets: Data(repeating: 100, count: 32*32*4*3), width: 32, height: 32, config: config)
}
let uninterrupted = try trainer()
try uninterrupted.setTrainingViews([0,1,2]); uninterrupted.setResolution(divisor: 2)
for _ in 0..<7 { try uninterrupted.trainStep() }
// Force relocation on the next step to exercise the saved random donor stream.
var opacity = uninterrupted.value(uninterrupted.colorOp, index: 0); opacity.w = -9
uninterrupted.setParameter(uninterrupted.colorOp, index: 0, value: opacity)
let session = TrainingCheckpoint.Session(id: UUID(), plan: .init(limits: .init(maxFrames: 8,longSide: 32,maxGaussians: 100),metalBudget:config.memoryBudgetBytes,pairLimit:config.pairLimit), config: config,sourceDigest:"synthetic")
try TrainingCheckpoint.save(folder, session: session, trainer: uninterrupted, control: TrainingRunControl())
let header = try TrainingCheckpoint.read(folder)!
let resumed = try trainer()
try TrainingCheckpoint.restore(folder, header: header, trainer: resumed)
precondition(resumed.step == 7 && resumed.width == 16)
for (a,b) in zip(uninterrupted.checkpointBuffers,resumed.checkpointBuffers) {
    precondition(Data(bytes:a.contents(),count:a.length)==Data(bytes:b.contents(),count:b.length))
}
var largest:Float = 0
for i in 8...50 {
    if i == 20 { uninterrupted.setResolution(divisor:1); resumed.setResolution(divisor:1) }
    let a=try uninterrupted.trainStep(), b=try resumed.trainStep()
    precondition(a.iteration==b.iteration && a.relocated==b.relocated)
    precondition(uninterrupted.lastCameraIndex==resumed.lastCameraIndex)
    for (a,b) in zip(uninterrupted.checkpointBuffers,resumed.checkpointBuffers) {
        let x=a.contents().bindMemory(to:Float.self,capacity:a.length/4),y=b.contents().bindMemory(to:Float.self,capacity:b.length/4)
        for j in 0..<(a.length/4) { largest=max(largest,abs(x[j]-y[j]));precondition(abs(x[j]-y[j])<0.0002,"Continuation drift \(x[j]) \(y[j])") }
    }
}
print("Resume: parameters + Adam + camera epoch + MCMC RNG + resolution, max drift=\(largest), step=\(resumed.step)")
let control=TrainingRunControl();control.pause();resumed.control=control
let state=try JSONEncoder().encode(resumed.checkpointState)
do { try resumed.trainStep();fatalError("Inactive GPU submission accepted") } catch is TrainingPaused {}
let pausedState = try JSONEncoder().encode(resumed.checkpointState)
precondition(pausedState.count == state.count)
precondition(resumed.step==50)
let cancelled=TrainingRunControl();cancelled.cancel()
do { try TrainingCheckpoint.save(folder,session:session,trainer:resumed,control:cancelled);fatalError("Cancelled checkpoint accepted") } catch is CancellationError {}
let retained = try TrainingCheckpoint.read(folder)!
precondition(retained.generation==header.generation)
let bytes=TrainingCheckpoint.root(folder).appendingPathComponent(header.generation.uuidString+"/0.bin")
try Data([1,2,3]).write(to:bytes)
do { try TrainingCheckpoint.restore(folder,header:header,trainer:try trainer());fatalError("Corrupt buffer accepted") } catch {}
print("Resume: inactive gate, cancelled save preserves previous generation, corrupt buffer rejection OK")

// v2 buffers carry growing count, all Adam groups, and accumulated absolute gradients.
try TrainingCheckpoint.remove(folder)
config.refinement = .init(capacity: 64, every: 4, start: 4, stopFraction: 0.7, gradientThreshold: 0, fraction: 0.25, splitLarge: true)
config.lineAspectLimit = 12
config.randomSeed = 12345
let growing = try trainer()
try growing.setTrainingViews([0,1,2])
for _ in 0..<7 { try growing.trainStep() }
precondition(growing.count > seeds.count)
let growthSession = TrainingCheckpoint.Session(id: UUID(), plan: session.plan, config: config, sourceDigest: "synthetic")
try TrainingCheckpoint.save(folder, session: growthSession, trainer: growing, control: TrainingRunControl())
let growthHeader = try TrainingCheckpoint.read(folder)!
precondition(growthHeader.version == 2 && growthHeader.files.count == 7)
let grownResume = try trainer()
try TrainingCheckpoint.restore(folder, header: growthHeader, trainer: grownResume)
precondition(growing.count == grownResume.count)
var drift: Float = 0
for i in 8...45 {
    if i == 20 { growing.setResolution(divisor: 2); grownResume.setResolution(divisor: 2) }
    if i == 30 { growing.setResolution(divisor: 1); grownResume.setResolution(divisor: 1) }
    try growing.trainStep(); try grownResume.trainStep()
    precondition(growing.count == grownResume.count && growing.count <= 64)
    precondition(growing.lastCameraIndex == grownResume.lastCameraIndex)
    for (a,b) in zip(growing.checkpointBuffers,grownResume.checkpointBuffers) {
        let x=a.contents().bindMemory(to:Float.self,capacity:a.length/4), y=b.contents().bindMemory(to:Float.self,capacity:b.length/4)
        for j in 0..<(a.length/4) { drift=max(drift,abs(x[j]-y[j]));precondition(abs(x[j]-y[j])<0.0002) }
    }
}
print("Growth resume: old=16 saved=\(growthHeader.state.count) final=\(grownResume.count) capacity=64 parameter/Adam/density drift=\(drift) OK")
