import ARKit
import CoreImage
import SwiftUI

/// One real camera frame, explicitly anchored and reviewed. No recording, upload,
/// Photos write or cloud generation occurs here; save only creates a local draft.
@MainActor struct SingleImageCamera: View {
    let save: (UIImage) throws -> Void
    let close: () -> Void
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var recorder = ARScanRecorder()
    @StateObject private var anchor = ScanAnchorController()
    @State private var photo: UIImage?
    @State private var selected: UIImage?
    @State private var message: String?
    @State private var saveError: String?
    @State private var selecting = false
    @State private var selectionID = UUID()
    @State private var worker: Task<CGImage,Error>?
    @State private var previousIdleTimer: Bool?
    private var canShoot: Bool { recorder.cameraReadiness.ready && anchor.target != nil && photo == nil }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let photo {
                GeometryReader { proxy in
                    Image(uiImage:selected ?? photo).resizable().scaledToFit()
                        .frame(width:proxy.size.width,height:proxy.size.height)
                        .contentShape(Rectangle())
                        .onTapGesture { tap in
                            guard selected == nil,!selecting,
                                  let point=PhotoSubjectSelection.pointInPhoto(tap:tap,viewSize:proxy.size,imageSize:photo.size) else { return }
                            selectSubject(in:photo,at:point)
                        }
                }.padding(.top,60).padding(.bottom,132)
            } else {
                ARScanPreview(session:recorder.session,anchor:anchor,recorder:recorder).ignoresSafeArea()
                    .onTapGesture { point in
                        guard recorder.cameraReadiness.ready else { return }
                        let found=anchor.place(at:point)
                        message=found ? nil : "靠近一点，再点选主体"
                        UIImpactFeedbackGenerator(style:.light).impactOccurred()
                    }
                CaptureCameraOverlay(recording:false,ready:recorder.cameraReadiness.ready,
                                     framing:CaptureFraming(),usesAnchor:true,showAim:anchor.target == nil).ignoresSafeArea()
            }
            LinearGradient(colors:[.black.opacity(0.4),.clear,.clear,.black.opacity(0.7)],startPoint:.top,endPoint:.bottom)
                .ignoresSafeArea().allowsHitTesting(false)
            VStack {
                HStack {
                    GlassIconButton(symbol:"xmark",label:"关闭拍摄",size:40) { close() }
                    Spacer()
                    if photo != nil {
                        Menu {
                            Button("使用整张照片",systemImage:"photo") {
                                cancelSelection();selected=photo;message=nil
                            }
                        } label: { Image(systemName:"ellipsis").frame(width:44,height:44).background(.ultraThinMaterial,in:Circle()) }
                        .accessibilityLabel("照片选项")
                    }
                }
                Spacer()
                if selecting { ProgressView().tint(.white).padding(.bottom,12) }
                else if let hint { Text(hint).font(.subheadline).multilineTextAlignment(.center).padding(.horizontal,14).padding(.vertical,9)
                    .background(.black.opacity(0.35),in:Capsule()).padding(.bottom,14) }
                if photo != nil {
                    HStack {
                        GlassIconButton(symbol:"arrow.counterclockwise",label:"重拍",size:48) { retake() }
                        Spacer()
                        GlassIconButton(symbol:"scope",label:"重新选择主体",size:48) { cancelSelection();selected=nil;message=nil }
                        Spacer()
                        Button { savePhoto() } label: {
                            Image(systemName:"checkmark").font(.system(size:26,weight:.semibold))
                                .frame(width:72,height:72).background(selected == nil ? Color.white.opacity(0.15) : Theme.accent,in:Circle())
                        }.disabled(selected == nil || selecting).accessibilityLabel("确认主体并保存照片")
                    }
                } else {
                    Button { shoot() } label: {
                        Circle().fill(canShoot ? .white : .white.opacity(0.25)).frame(width:64,height:64).padding(8)
                            .overlay(Circle().stroke(.white.opacity(0.85),lineWidth:3))
                    }.disabled(!canShoot).accessibilityLabel("拍摄已选主体")
                }
            }.padding(.horizontal,24).padding(.top,6).padding(.bottom,18)
        }
        .foregroundStyle(.white)
        .onAppear {
            previousIdleTimer=UIApplication.shared.isIdleTimerDisabled
            UIApplication.shared.isIdleTimerDisabled=true
            recorder.startPreview()
        }
        .onDisappear {
            cancelSelection();recorder.pausePreview()
            if let previousIdleTimer { UIApplication.shared.isIdleTimerDisabled=previousIdleTimer }
        }
        .onChange(of:recorder.cameraReadiness.ready) { wasReady,ready in
            if wasReady && !ready && photo == nil { anchor.clear() }
        }
        .onChange(of:scenePhase) { _,phase in
            if phase == .background { recorder.pausePreview();anchor.clear() }
            if phase == .active && photo == nil { recorder.startPreview();anchor.clear() }
        }
        .alert("照片未保存",isPresented:Binding(get:{saveError != nil},set:{if !$0 {saveError=nil}})) {
            Button("重试保存") { savePhoto() }
            Button("返回",role:.cancel) {}
        } message: { Text(saveError ?? "") }
    }
    private var hint:String? {
        if let message { return message }
        if photo != nil { return selected == nil ? "点选照片里的主体" : "确认主体" }
        if case .failed(let error)=recorder.state { return error }
        if !recorder.cameraReadiness.ready { return recorder.cameraReadiness.hint }
        return anchor.target == nil ? "点一下要拍的主体" : nil
    }
    private func shoot() {
        guard canShoot,let target=anchor.target,let frame=recorder.session.currentFrame,
              case .normal=frame.camera.trackingState,
              abs(ProcessInfo.processInfo.systemUptime-frame.timestamp)<0.5,
              let point=CaptureFraming.project(target.simdCenter,cameraToWorld:frame.camera.transform,
                  intrinsics:frame.camera.intrinsics,resolution:frame.camera.imageResolution,display:.identity),
              PhotoSubjectSelection.pixel(point,width:1,height:1) != nil else {
            message="对准已选主体，再拍摄";return
        }
        let resolution=frame.camera.imageResolution
        let display=frame.displayTransform(for:.portrait,viewportSize:CGSize(width:resolution.height,height:resolution.width))
        guard let orientation=PhotoSubjectSelection.orientation(for:display) else { message="相机方向变化，请重新对准";return }
        let input=CIImage(cvPixelBuffer:frame.capturedImage).oriented(orientation)
        guard let cg=CIContext().createCGImage(input,from:input.extent) else { message="拍摄未完成，请重试";return }
        let image=UIImage(cgImage:cg)
        photo=image;selected=nil;message=nil
        recorder.pausePreview()
        UIImpactFeedbackGenerator(style:.medium).impactOccurred()
        selectSubject(in:image,at:point.applying(display))
    }
    private func selectSubject(in image:UIImage,at point:CGPoint) {
        guard let cg=image.cgImage else { return }
        cancelSelection();selecting=true;selected=nil;message=nil
        let id=UUID();selectionID=id
        let job=Task.detached(priority:.userInitiated) { try PhotoSubjectSelection.crop(cg,at:point) }
        worker=job
        Task {
            do {
                let crop=try await job.value
                guard selectionID==id else { return }
                selected=UIImage(cgImage:crop);selecting=false;worker=nil
                UISelectionFeedbackGenerator().selectionChanged()
            } catch {
                guard selectionID==id else { return }
                selecting=false;worker=nil
                message="未选中主体，请在照片上重新点选"
            }
        }
    }
    private func cancelSelection() { selectionID=UUID();worker?.cancel();worker=nil;selecting=false }
    private func retake() {
        cancelSelection();photo=nil;selected=nil;message=nil;anchor.clear();recorder.startPreview()
    }
    private func savePhoto() {
        guard let selected,!selecting else { return }
        do { try save(selected);close() }
        catch { saveError=error.localizedDescription }
    }
}
