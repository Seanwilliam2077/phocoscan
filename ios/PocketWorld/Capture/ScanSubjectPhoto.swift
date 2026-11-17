import AVFoundation
import CoreImage
import ImageIO
import simd

/// Selects only real, locally recorded pixels. The source link is local metadata;
/// the generated result remains ai_single_image, never measured scan geometry.
enum ScanSubjectPhoto {
    struct Source: Codable, Equatable {
        let captureID: String
        let file: String
        let timestamp: Double
        let selection: String
    }
    struct Prepared {
        let image: CGImage
        let source: Source
    }
    struct Candidate {
        let file: String
        let timestamp: Double
        let videoTime: Double?
        let pose: simd_float4x4
        let intrinsics: simd_float3x3
        let size: CGSize
        let sharpness: Double?
    }
    struct Framing {
        let point: CGPoint
        let box: CGRect
        let score: Double
    }
    enum Failure: LocalizedError {
        case noFrame, missingSubject
        var errorDescription: String? {
            switch self {
            case .noFrame: return "这次扫描没有可用的清晰画面，请补拍后再试"
            case .missingSubject: return "没有找到完整拍到主体的画面，请补拍主体后再试"
            }
        }
    }
    static func prepare(folder: URL, target: ScanTargetBox?) async throws -> Prepared {
        let captureID = folder.deletingPathExtension().lastPathComponent
        let context = CIContext(options: [.cacheIntermediates: false])
        // Read the video frame table only when keyframes could not supply a photo.
        for video in [false, true] {
            try Task.checkCancellation()
            let frames = (try? candidates(folder: folder, video: video)) ?? []
            let eligible = frames.compactMap { frame -> (Candidate, Framing)? in
                guard let framing = framing(frame, target: target) else { return nil }
                return (frame, framing)
            }
            // Spread legacy-video candidates across the recording, not just its first seconds.
            let sampled = video && eligible.count > 48
                ? (0..<48).map { eligible[$0 * (eligible.count - 1) / 47] } : eligible
            let ranked = sampled.sorted { ranking($0.0, $0.1) > ranking($1.0, $1.1) }
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: folder.appendingPathComponent("video.mov")))
            generator.appliesPreferredTrackTransform = false // intrinsics describe unrotated sensor pixels
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            generator.maximumSize = CGSize(width: 2048, height: 2048)
            var best: (CGImage, Candidate, Framing, Double)?
            for (frame, framing) in ranked.prefix(12) {
                try Task.checkCancellation()
                let image: CGImage
                if let time = frame.videoTime {
                    guard let extracted = try? await generator.image(at: CMTime(seconds: time, preferredTimescale: 60000)),
                          abs(extracted.actualTime.seconds - time) < 0.004 else { continue }
                    image = extracted.image
                } else {
                    let url = folder.appendingPathComponent("capture").appendingPathComponent(frame.file)
                    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                          let decoded = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                            kCGImageSourceCreateThumbnailFromImageAlways: true,
                            kCGImageSourceThumbnailMaxPixelSize: 2048,
                            kCGImageSourceCreateThumbnailWithTransform: false] as CFDictionary) else { continue }
                    image = decoded
                }
                // Sensor geometry must correspond to this exact frame; never guess a crop.
                guard abs(Double(image.width) / Double(image.height) - frame.size.width / frame.size.height) < 0.02 else { continue }
                let clarity = sharpness(image, region: framing.box)
                let score = framing.score + log1p(clarity) * 0.25
                if best == nil || score > best!.3 { best = (image, frame, framing, score) }
            }
            guard let (raw, frame, framing, _) = best else { continue }
            let (rotation, display) = upright(frame.pose)
            let oriented = CIImage(cgImage: raw).oriented(rotation)
            guard let image = context.createCGImage(oriented, from: oriented.extent) else { continue }
            var selection = "whole_frame", selected = image
            if target != nil {
                let point = framing.point.applying(display)
                do {
                    selected = try PhotoSubjectSelection.crop(image, at: point)
                    selection = "foreground_at_anchor"
                } catch is CancellationError { throw CancellationError() }
                catch {
                    // Vision may miss textureless/occluded foreground. Use the recorded
                    // anchor's projected bounds, never the largest unrelated foreground.
                    let box = framing.box.applying(display)
                    guard let cropped = image.cropping(to: PhotoSubjectSelection.paddedCrop(box, imageSize: CGSize(width: image.width, height: image.height))) else { throw Failure.missingSubject }
                    selected = cropped; selection = "projected_anchor"
                }
            }
            try Task.checkCancellation()
            return Prepared(image: selected, source: Source(captureID: captureID, file: frame.file,
                                                           timestamp: frame.timestamp, selection: selection))
        }
        throw target == nil ? Failure.noFrame : Failure.missingSubject
    }
    static func candidates(folder: URL, video: Bool) throws -> [Candidate] {
        let url = folder.appendingPathComponent(video ? "frames.jsonl" : "capture/transforms.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let rows: [[String: Any]]
        if video {
            rows = data.split(separator: 10).compactMap { (try? JSONSerialization.jsonObject(with: Data($0))) as? [String: Any] }
        } else {
            rows = ((try JSONSerialization.jsonObject(with: data)) as? [String: Any])?["frames"] as? [[String: Any]] ?? []
        }
        var lastTime = -Double.infinity
        return rows.compactMap { row in
            if video, row["trackingState"] as? String != "normal" { return nil }
            if row["subject_moving"] as? Bool == true { return nil }
            // JSON numbers are Doubles. Conditional bridging to [[Float]] rejects valid
            // decimal poses that are not exactly representable (44/107 real scan frames).
            // Decode numbers first, then explicitly round to Float for SIMD calculations.
            guard let matrix = row[video ? "cameraToWorldARKit" : "transform_matrix"] as? [[Double]],
                  matrix.count == 4, matrix.allSatisfy({ $0.count == 4 && $0.allSatisfy(\.isFinite) }),
                  let w = row[video ? "cameraImageWidth" : "w"] as? Double,
                  let h = row[video ? "cameraImageHeight" : "h"] as? Double, w > 0, h > 0,
                  let time = row[video ? "videoPTSSeconds" : "timestamp"] as? Double, time.isFinite, time >= 0 else { return nil }
            if video, time - lastTime < 0.4 { return nil }; lastTime = time
            let pose = simd_float4x4(rows: matrix.map { SIMD4($0.map(Float.init)) })
            guard abs(simd_determinant(pose) - 1) < 0.02 else { return nil }
            let fx: Float, fy: Float, cx: Float, cy: Float
            if video {
                guard let k = row["intrinsicsPixels"] as? [[Double]], k.count == 3, k.allSatisfy({ $0.count == 3 }) else { return nil }
                fx=Float(k[0][0]); fy=Float(k[1][1]); cx=Float(k[0][2]); cy=Float(k[1][2])
            } else {
                guard let x=row["fl_x"] as? Double, let y=row["fl_y"] as? Double,
                      let a=row["cx"] as? Double, let b=row["cy"] as? Double else { return nil }
                fx=Float(x); fy=Float(y); cx=Float(a); cy=Float(b)
            }
            guard [fx,fy,cx,cy].allSatisfy(\.isFinite), fx>0, fy>0 else { return nil }
            let file = video ? "video.mov" : (row["file_path"] as? String ?? "")
            if !video {
                guard file.hasPrefix("images/"), !file.split(separator: "/").contains(".."),
                      !file.contains("\\"), ["jpg","jpeg","png"].contains(URL(fileURLWithPath:file).pathExtension.lowercased()) else { return nil }
                let root = folder.appendingPathComponent("capture").resolvingSymlinksInPath().path + "/"
                guard folder.appendingPathComponent("capture").appendingPathComponent(file).resolvingSymlinksInPath().path.hasPrefix(root) else { return nil }
            }
            return Candidate(file:file,timestamp:time,videoTime:video ? time : nil,pose:pose,
                intrinsics:simd_float3x3(SIMD3(fx,0,0),SIMD3(0,fy,0),SIMD3(cx,cy,1)),size:CGSize(width:w,height:h),sharpness:row["sharpness"] as? Double)
        }
    }
    static func framing(_ frame: Candidate, target: ScanTargetBox?) -> Framing? {
        guard let target else { return Framing(point:CGPoint(x:0.5,y:0.5),box:CGRect(x:0,y:0,width:1,height:1),score:0) }
        guard target.center.count == 3, target.size.count == 3,
              (target.center + target.size + [target.yawRadians]).allSatisfy(\.isFinite), target.size.allSatisfy({ $0 > 0 }) else { return nil }
        func project(_ p: SIMD3<Float>) -> CGPoint? {
            CaptureFraming.project(p,cameraToWorld:frame.pose,intrinsics:frame.intrinsics,resolution:frame.size,display:.identity)
        }
        guard let point = project(target.simdCenter), CGRect(x:0.03,y:0.03,width:0.94,height:0.94).contains(point) else { return nil }
        let rotation = simd_float3x3(simd_quatf(angle:target.yawRadians,axis:SIMD3(0,1,0)))
        var corners: [CGPoint] = []
        for x: Float in [-0.5,0.5] { for y: Float in [-0.5,0.5] { for z: Float in [-0.5,0.5] {
            guard let p = project(target.simdCenter + rotation * (target.simdSize * SIMD3(x,y,z))) else { return nil }; corners.append(p)
        } } }
        let xs=corners.map(\.x), ys=corners.map(\.y)
        let box=CGRect(x:xs.min()!,y:ys.min()!,width:xs.max()!-xs.min()!,height:ys.max()!-ys.min()!)
        let visible=box.intersection(CGRect(x:0,y:0,width:1,height:1))
        guard box.width>0,box.height>0,!visible.isNull, visible.width*visible.height/(box.width*box.height)>0.92,
              min(box.width*frame.size.width,box.height*frame.size.height)>40 else { return nil }
        let offset=hypot(point.x-0.5,point.y-0.5)
        return Framing(point:point,box:visible,score:1-Double(offset)+min(0.5,Double(visible.width*visible.height)))
    }
    static func ranking(_ frame: Candidate, _ framing: Framing) -> Double {
        framing.score + log1p(max(0,frame.sharpness?.isFinite == true ? frame.sharpness! : 0)) * 0.15
    }
    /// Align recorded world-up with the top of the selected image. Near-vertical
    /// views have no gravity-defined roll, so preserve their sensor orientation.
    static func upright(_ pose: simd_float4x4) -> (CGImagePropertyOrientation, CGAffineTransform) {
        let up = pose.inverse * SIMD4<Float>(0,1,0,0)
        guard hypot(up.x,up.y)>0.2 else { return (.up,.identity) }
        if abs(up.x)>abs(up.y) {
            return up.x>0 ? (.left,CGAffineTransform(a:0,b:-1,c:1,d:0,tx:0,ty:1)) : (.right,CGAffineTransform(a:0,b:1,c:-1,d:0,tx:1,ty:0))
        }
        return up.y>0 ? (.up,.identity) : (.down,CGAffineTransform(a:-1,b:0,c:0,d:-1,tx:1,ty:1))
    }
    static func sharpness(_ image: CGImage, region: CGRect) -> Double {
        let size=CGSize(width:image.width,height:image.height)
        guard let crop=image.cropping(to:PhotoSubjectSelection.paddedCrop(region,imageSize:size)) else { return 0 }
        let n=128; var gray=[UInt8](repeating:0,count:n*n)
        let score: Double = gray.withUnsafeMutableBytes { bytes in
            guard let ctx=CGContext(data:bytes.baseAddress,width:n,height:n,bitsPerComponent:8,bytesPerRow:n,space:CGColorSpaceCreateDeviceGray(),bitmapInfo:CGImageAlphaInfo.none.rawValue) else { return 0 }
            ctx.draw(crop,in:CGRect(x:0,y:0,width:n,height:n))
            let pixels=bytes.bindMemory(to:UInt8.self);var sum=0.0,sum2=0.0
            for y in 1..<(n-1) { for x in 1..<(n-1) {
                let i=y*n+x,v=Double(Int(pixels[i-1])+Int(pixels[i+1])+Int(pixels[i-n])+Int(pixels[i+n])-4*Int(pixels[i]))
                sum+=v;sum2+=v*v
            } }
            let count=Double((n-2)*(n-2)); return max(0,sum2/count-pow(sum/count,2))
        }
        return score
    }
}
