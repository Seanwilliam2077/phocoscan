import CoreImage
import UniformTypeIdentifiers
import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import Vision

/// A tap chooses one foreground instance; it never silently chooses all objects
/// or the nearest unrelated object when the tapped pixel is background.
enum PhotoSubjectSelection {
    enum Failure: LocalizedError { case noSubject, invalidImage
        var errorDescription: String? {
            switch self {
            case .noSubject: return "未选中主体，请在照片上重新点选"
            case .invalidImage: return "无法读取这张照片，请重拍"
            }
        }
    }
    static func crop(_ image: CGImage, at point: CGPoint) throws -> CGImage {
        try Task.checkCancellation()
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage:image,orientation:.up)
        try handler.perform([request])
        try Task.checkCancellation()
        guard let observation=request.results?.first else { throw Failure.noSubject }
        let mask=observation.instanceMask
        CVPixelBufferLockBaseAddress(mask,.readOnly)
        defer { CVPixelBufferUnlockBaseAddress(mask,.readOnly) }
        guard let base=CVPixelBufferGetBaseAddress(mask) else { throw Failure.invalidImage }
        let w=CVPixelBufferGetWidth(mask),h=CVPixelBufferGetHeight(mask),stride=CVPixelBufferGetBytesPerRow(mask)
        guard let seed=pixel(point,width:w,height:h), CVPixelBufferGetPixelFormatType(mask) == kCVPixelFormatType_OneComponent8 else { throw Failure.noSubject }
        func label(_ x:Int,_ y:Int) -> UInt8 { base.advanced(by:y*stride).assumingMemoryBound(to:UInt8.self)[x] }
        let subject=label(seed.x,seed.y)
        guard subject != 0, observation.allInstances.contains(Int(subject)),
              let bounds=bounds(width:w,height:h,subject:subject,label:label) else { throw Failure.noSubject }
        let box=CGRect(x:bounds.minX/CGFloat(w),y:bounds.minY/CGFloat(h),width:bounds.width/CGFloat(w),height:bounds.height/CGFloat(h))
        let rectangle=paddedCrop(box,imageSize:CGSize(width:image.width,height:image.height))
        guard let cropped=image.cropping(to:rectangle) else { throw Failure.invalidImage }
        return cropped
    }
    /// Full sensor-sized mask: segmentation changes the loss region, never calibration/crop.
    static func maskPNG(_ image: CGImage, at point: CGPoint) throws -> Data {
        try Task.checkCancellation()
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image, orientation: .up)
        try handler.perform([request])
        guard let observation = request.results?.first else { throw Failure.noSubject }
        let labels = observation.instanceMask
        CVPixelBufferLockBaseAddress(labels, .readOnly)
        let subject: UInt8
        do {
            defer { CVPixelBufferUnlockBaseAddress(labels, .readOnly) }
            guard CVPixelBufferGetPixelFormatType(labels) == kCVPixelFormatType_OneComponent8,
                  let base = CVPixelBufferGetBaseAddress(labels),
                  let seed = pixel(point, width: CVPixelBufferGetWidth(labels), height: CVPixelBufferGetHeight(labels)) else { throw Failure.noSubject }
            subject = base.advanced(by: seed.y * CVPixelBufferGetBytesPerRow(labels) + seed.x).load(as: UInt8.self)
        }
        guard subject > 0, observation.allInstances.contains(Int(subject)) else { throw Failure.noSubject }
        let buffer = try observation.generateScaledMaskForImage(forInstances: IndexSet(integer: Int(subject)), from: handler)
        try Task.checkCancellation()
        let ci = CIImage(cvPixelBuffer: buffer)
        guard let cg = CIContext(options: [.cacheIntermediates: false]).createCGImage(ci, from: ci.extent, format: .L8, colorSpace: CGColorSpaceCreateDeviceGray()),
              cg.width == image.width, cg.height == image.height else { throw Failure.invalidImage }
        let bytes = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(bytes, UTType.png.identifier as CFString, 1, nil) else { throw Failure.invalidImage }
        CGImageDestinationAddImage(destination, cg, nil)
        guard CGImageDestinationFinalize(destination) else { throw Failure.invalidImage }
        return bytes as Data
    }

    static func pixel(_ point:CGPoint,width:Int,height:Int) -> (x:Int,y:Int)? {
        guard width>0,height>0,point.x.isFinite,point.y.isFinite,
              (0...1).contains(point.x),(0...1).contains(point.y) else { return nil }
        return (min(width-1,Int(point.x*CGFloat(width))),min(height-1,Int(point.y*CGFloat(height))))
    }
    static func bounds(width:Int,height:Int,subject:UInt8,label:(Int,Int)->UInt8) -> CGRect? {
        guard subject != 0 else { return nil }
        var x0=width,y0=height,x1 = -1,y1 = -1
        for y in 0..<height { for x in 0..<width where label(x,y)==subject {
            x0=min(x0,x);y0=min(y0,y);x1=max(x1,x);y1=max(y1,y)
        } }
        return x1>=x0 && y1>=y0 ? CGRect(x:x0,y:y0,width:x1-x0+1,height:y1-y0+1) : nil
    }
    static func paddedCrop(_ normalized: CGRect,imageSize:CGSize) -> CGRect {
        let box=CGRect(x:normalized.minX*imageSize.width,y:normalized.minY*imageSize.height,
                       width:normalized.width*imageSize.width,height:normalized.height*imageSize.height)
        let margin=max(12,max(box.width,box.height)*0.10)
        return box.insetBy(dx:-margin,dy:-margin).integral.intersection(CGRect(origin:.zero,size:imageSize))
    }
    /// Infer the uncropped image orientation from ARKit's actual display transform,
    /// rather than assuming a sensor rotation on every iPhone/video format.
    static func orientation(for display:CGAffineTransform) -> CGImagePropertyOrientation? {
        let candidates:[(CGAffineTransform,CGImagePropertyOrientation)] = [
            (.identity,.up),
            (CGAffineTransform(a:0,b:1,c:-1,d:0,tx:1,ty:0),.right),
            (CGAffineTransform(a:0,b:-1,c:1,d:0,tx:0,ty:1),.left),
            (CGAffineTransform(a:-1,b:0,c:0,d:-1,tx:1,ty:1),.down)]
        return candidates.first { t,_ in
            zip([t.a,t.b,t.c,t.d,t.tx,t.ty],[display.a,display.b,display.c,display.d,display.tx,display.ty]).allSatisfy { abs($0-$1)<0.001 }
        }?.1
    }
    static func pointInPhoto(tap:CGPoint,viewSize:CGSize,imageSize:CGSize) -> CGPoint? {
        guard viewSize.width>0,viewSize.height>0,imageSize.width>0,imageSize.height>0 else { return nil }
        let scale=min(viewSize.width/imageSize.width,viewSize.height/imageSize.height)
        let w=imageSize.width*scale,h=imageSize.height*scale
        let point=CGPoint(x:(tap.x-(viewSize.width-w)/2)/w,y:(tap.y-(viewSize.height-h)/2)/h)
        return pixel(point,width:1,height:1) == nil ? nil : point
    }
}
