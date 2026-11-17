import Foundation
import Metal
import simd
let device = MTLCreateSystemDefaultDevice()!
let library = try device.makeLibrary(URL: URL(fileURLWithPath: CommandLine.arguments[1]))
func checkEqual<T: BinaryFloatingPoint>(_ a:T,_ b:T,accuracy:T) { precondition(abs(a-b)<=accuracy,"Mismatch: \(a) vs \(b)") }
func checkEqual(_ a:Int,_ b:Int) { precondition(a==b) }
func checkLess(_ a:Int,_ b:Int,_ message:String) { precondition(a<b,message) }
func structuralLoss(_ pixels: [SIMD4<Float>], target: Data, w: Int, h: Int, lambda: Double) -> Double {
        let bytes = [UInt8](target)
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
            result += (1-lambda)*abs(Double(pixels[y*w+x][c])-Double(bytes[(y*w+x)*4+c])/255)+lambda*(1-score)
        } } }
        return result/Double(w*h*3)
    }


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
        checkEqual(Double(analytic.value), structuralLoss(pixels,target:target,w:w,h:h,lambda:0.2),accuracy:2e-6)
        for i in [0,8,31,54,62] { for c in 0..<3 {
            var plus=pixels,minus=pixels
            plus[i][c]+=0.001; minus[i][c]-=0.001
            let numeric=(structuralLoss(plus,target:target,w:w,h:h,lambda:0.2)-structuralLoss(minus,target:target,w:w,h:h,lambda:0.2))/0.002
            checkEqual(Double(analytic.gradient[i][c]),numeric,accuracy:2e-5)
        } }
        checkEqual(trainer.targetBufferBytes,w*h*8)
        checkLess(trainer.sortingCapacity,1000,"no 96 MB eager sorting allocation")

print("5. SSIM CPU value + edge/interior finite-difference gradients: OK")
