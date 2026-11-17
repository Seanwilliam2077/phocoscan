import CoreImage
import XCTest
@testable import PocketWorld

final class PhotoSubjectSelectionTests: XCTestCase {
    func testOnlyTheTappedInstanceDefinesTheCrop() throws {
        let labels:[UInt8] = [0,0,0,0,0,0, 0,1,1,0,2,0, 0,1,1,0,2,0, 0,0,0,0,0,0]
        let bounds=try XCTUnwrap(PhotoSubjectSelection.bounds(width:6,height:4,subject:1) { labels[$1*6+$0] })
        XCTAssertEqual(bounds,CGRect(x:1,y:1,width:2,height:2))
        XCTAssertNil(PhotoSubjectSelection.bounds(width:6,height:4,subject:0) { labels[$1*6+$0] })
        XCTAssertNil(PhotoSubjectSelection.bounds(width:6,height:4,subject:3) { labels[$1*6+$0] })
    }
    func testPhotoTapIgnoresLetterboxAndMapsToOriginalPixels() throws {
        let image=CGSize(width:400,height:800),view=CGSize(width:400,height:400)
        XCTAssertNil(PhotoSubjectSelection.pointInPhoto(tap:CGPoint(x:30,y:200),viewSize:view,imageSize:image))
        let p=try XCTUnwrap(PhotoSubjectSelection.pointInPhoto(tap:CGPoint(x:150,y:100),viewSize:view,imageSize:image))
        XCTAssertEqual(p.x,0.25,accuracy:1e-6);XCTAssertEqual(p.y,0.25,accuracy:1e-6)
        XCTAssertNil(PhotoSubjectSelection.pixel(CGPoint(x:CGFloat.nan,y:0),width:100,height:100))
    }
    func testCropKeepsMarginAndStaysInsideThePhoto() {
        let size=CGSize(width:1000,height:800)
        let crop=PhotoSubjectSelection.paddedCrop(CGRect(x:0.2,y:0.25,width:0.3,height:0.5),imageSize:size)
        XCTAssertEqual(crop,CGRect(x:160,y:160,width:380,height:480))
        let edge=PhotoSubjectSelection.paddedCrop(CGRect(x:0,y:0,width:0.5,height:0.5),imageSize:size)
        XCTAssertEqual(edge.minX,0);XCTAssertEqual(edge.minY,0)
        XCTAssertTrue(CGRect(origin:.zero,size:size).contains(edge))
    }
    func testCameraRotationAndSelectedPixelStayAligned() throws {
        let bytes: [UInt8] = [255,0,0,255, 0,255,0,255, 0,0,255,255, 255,255,0,255, 0,255,255,255, 255,0,255,255]
        let provider=CGDataProvider(data:Data(bytes) as CFData)!
        let original=CGImage(width:3,height:2,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:12,
            space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedLast.rawValue),provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent)!
        let transforms:[CGAffineTransform] = [.identity,
            CGAffineTransform(a:0,b:1,c:-1,d:0,tx:1,ty:0),CGAffineTransform(a:0,b:-1,c:1,d:0,tx:0,ty:1),
            CGAffineTransform(a:-1,b:0,c:0,d:-1,tx:1,ty:1)]
        for transform in transforms {
            let orientation=try XCTUnwrap(PhotoSubjectSelection.orientation(for:transform))
            let ci=CIImage(cgImage:original).oriented(orientation)
            let rotated=try XCTUnwrap(CIContext().createCGImage(ci,from:ci.extent))
            let point=CGPoint(x:1.0/6,y:0.25).applying(transform)
            let pixel=try XCTUnwrap(PhotoSubjectSelection.pixel(point,width:rotated.width,height:rotated.height))
            let patch=try XCTUnwrap(rotated.cropping(to:CGRect(x:pixel.x,y:pixel.y,width:1,height:1)))
            var color=[UInt8](repeating:0,count:4)
            color.withUnsafeMutableBytes { p in
                let context=CGContext(data:p.baseAddress,width:1,height:1,bitsPerComponent:8,bytesPerRow:4,
                    space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
                context.draw(patch,in:CGRect(x:0,y:0,width:1,height:1))
            }
            XCTAssertGreaterThan(color[0],240);XCTAssertLessThan(color[1],15);XCTAssertLessThan(color[2],15)
        }
        XCTAssertNil(PhotoSubjectSelection.orientation(for:CGAffineTransform(scaleX:2,y:1)))
    }
}
