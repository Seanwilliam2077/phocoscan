// Draws the phocoscan app icon (1024×1024, opaque) with CoreGraphics.
// Usage: swift scripts/generate-app-icon.swift ios/PocketWorld/Assets.xcassets/AppIcon.appiconset/AppIcon.png
// Deliberately minimal: one flat accent background, one ring and one dot, the same
// anchor point and guide ring the capture screen draws around an object.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size = 1024
let output = CommandLine.arguments.dropFirst().first ?? "AppIcon.png"
let space = CGColorSpace(name: CGColorSpace.sRGB)!
guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                          space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
    fatalError("context")
}

func rgb(_ hex: UInt32) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}

let center = CGPoint(x: 512, y: 512)
ctx.setFillColor(rgb(0x7C3AED))                       // Theme.accentStart
ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
ctx.setStrokeColor(rgb(0xFFFFFF))
ctx.setLineWidth(56)
ctx.strokeEllipse(in: CGRect(x: center.x - 300, y: center.y - 300, width: 600, height: 600))
ctx.setFillColor(rgb(0xFFFFFF))
ctx.fillEllipse(in: CGRect(x: center.x - 62, y: center.y - 62, width: 124, height: 124))

guard let image = ctx.makeImage(),
      let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: output) as CFURL,
                                                        UTType.png.identifier as CFString, 1, nil) else {
    fatalError("output")
}
CGImageDestinationAddImage(destination, image, nil)
guard CGImageDestinationFinalize(destination) else { fatalError("write") }
print("Wrote \(output)")
