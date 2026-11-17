import SwiftUI

/// Display-only overlay. The centre is the actual AR preview centre, not the
/// remaining space above the controls (which would aim at the wrong image pixel).
struct CaptureCameraOverlay: View {
    let recording: Bool
    let ready: Bool
    let framing: CaptureFraming
    let usesAnchor: Bool
    let showAim: Bool
    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            if !recording && !ready {
                VStack(spacing: 16) {
                    CalibrationGlyph().frame(width: 90, height: 110)
                    Text("视角校准").font(.caption.weight(.medium)).foregroundStyle(.white.opacity(0.8))
                }
                .position(x: size.width/2, y: size.height * 0.43)
            } else if !recording && showAim {
                AlignmentReticle().frame(width: 204, height: 204)
                    .position(x: size.width/2, y: size.height/2)
            } else if recording && usesAnchor {
                if !framing.needsRecovery, let p = framing.marker,
                   (0...1).contains(p.x), (0...1).contains(p.y) {
                    Circle().stroke(.white.opacity(0.95), lineWidth: 2)
                        .frame(width: 18, height: 18)
                        .shadow(color: .black.opacity(0.4), radius: 3)
                        .position(x: p.x*size.width, y: p.y*size.height)
                }
                if let direction = framing.correction {
                    Image(systemName: symbol(direction))
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(framing.needsRecovery ? Theme.warning : .white)
                        .shadow(color: .black.opacity(0.45), radius: 5)
                        .position(position(direction, size: size))
                }
            }
        }
        .allowsHitTesting(false).accessibilityHidden(true)
    }
    private func symbol(_ direction: AimCorrection) -> String {
        switch direction { case .left: return "arrow.left"; case .right: return "arrow.right"; case .up: return "arrow.up"; case .down: return "arrow.down" }
    }
    private func position(_ direction: AimCorrection, size: CGSize) -> CGPoint {
        switch direction {
        case .left: return CGPoint(x: 28, y: size.height*0.43)
        case .right: return CGPoint(x: size.width-28, y: size.height*0.43)
        case .up: return CGPoint(x: size.width/2, y: size.height*0.22)
        case .down: return CGPoint(x: size.width/2, y: size.height*0.64)
        }
    }
}

struct AlignmentReticle: View {
    var body: some View {
        GeometryReader { proxy in
            let w = proxy.size.width, h = proxy.size.height, arm: CGFloat = 14
            Path { p in
                for (x,y,sx,sy) in [(0.0,0.0,1.0,1.0),(w,0,-1,1),(0,h,1,-1),(w,h,-1,-1)] {
                    p.move(to: CGPoint(x:x,y:y+sy*arm));p.addLine(to:CGPoint(x:x,y:y));p.addLine(to:CGPoint(x:x+sx*arm,y:y))
                }
            }.stroke(.white.opacity(0.5), style:StrokeStyle(lineWidth:1.5,lineCap:.round,lineJoin:.round))
            Circle().stroke(.white,lineWidth:2).frame(width:20,height:20).position(x:w/2,y:h/2)
        }
        .shadow(color:.black.opacity(0.3),radius:4)
    }
}

struct CalibrationGlyph: View {
    var body: some View {
        ZStack {
            Canvas { context, size in
                for row in 0..<7 { for column in 0..<5 {
                    let p = CGRect(x:CGFloat(column)*16+11,y:CGFloat(row)*14+9,width:2,height:2)
                    context.fill(Path(ellipseIn:p),with:.color(.white.opacity(0.28)))
                } }
            }
            RoundedRectangle(cornerRadius:12).stroke(.white.opacity(0.9),lineWidth:1.5)
                .frame(width:48,height:82)
                .overlay(alignment:.bottom) { Capsule().fill(.white.opacity(0.8)).frame(width:16,height:2).padding(.bottom,7) }
                .phaseAnimator([false,true]) { content, phase in
                    content.rotationEffect(.degrees(phase ? 8 : -8)).offset(x:phase ? 7 : -7)
                } animation: { _ in .easeInOut(duration:1.4) }
        }
    }
}
