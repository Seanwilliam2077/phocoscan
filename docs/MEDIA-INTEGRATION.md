# Native capture and Gaussian viewer integration

Implemented source modules are under `ios/PocketWorld/Capture/` and `ios/PocketWorld/Viewer/`.
This document records implementation and remaining device checks. Windows cannot compile or run Apple frameworks; no iPhone or GPU pass is claimed.

## Build dependency

- Package: https://github.com/scier/MetalSplatter
- Exact tag: `1.0.1`
- Exact commit: `71ff248e3016ac43c0a9271e322538421b28c360`
- Link SPM products **MetalSplatter** and **SplatIO** to the app target.
- Upstream package declares Swift tools 6.1 and iOS 18 minimum. Use Xcode 16.3 or newer with a compatible iOS SDK; app language mode can remain Swift 5.
- Do not test the upstream renderer on an Intel/x86_64 simulator: upstream explicitly does not support that architecture. An Apple Silicon simulator is useful for UI, but actual iPhone tests remain required.
- Include `NSCameraUsageDescription`. Capture never creates an audio input; no microphone usage description or microphone permission is required.
- Lock initial app orientation to portrait for consistent capture. Capture file connection and preview are set to 90-degree rotation when supported by the actual connection.

## API to app

```swift
NativeCaptureView(sessionID: persistedCaptureSessionID, onSaved: { video in
    // Associate with the already-persisted pending session ID, save draft, then dismiss.
}, onCancel: {
    // Caller dismisses. No draft/video is discarded implicitly.
})

GaussianSceneView(url: downloadedAuthenticatedLocalFile, onReady: {
    // Record result_viewed here, after the first actual Metal drawable presentation.
})
```

`CapturedVideo` is Codable, containing `url`, `previewURL`, `capturedAt`, `durationSeconds`, `width`, `height`, `fps`, and optional `sessionID`. The capture screen never dismisses itself; parent owns navigation. The callback fires after metadata and sidecar storage, not after backend submission. Pass the already-persisted exact session ID before recording; it is frozen when recording begins and written into the sidecar. Legacy sidecars without a session ID must never be automatically assigned using timestamps or the current task. Recover only a sidecar whose ID matches its pending session, or require explicit user selection.

Raw `.mov` and JPEG files live in Application Support/Captures. A `.capture.json` sidecar is written atomically before callback. `CapturedVideo.savedCaptures()` returns readable sidecars, rebasing paths against the current application container and preserving the exact `sessionID`; use it for interrupted callback recovery. Parent should associate only the exact matching session or offer an explicit recovery picker, not silently link an old movie to a new task. When deleting a local source, delete video, JPEG and sidecar together after the user's selected data deletion action.

## What capture actually records

- Wide-angle rear camera video, requested 1080p when supported, H.264 when available, no audio, no UI overlays burned into the raw file.
- Maximum 90 seconds or 450 MiB per recording. The movie output handles these stops; the callback reads actual saved duration and track metadata.
- Video stabilization is disabled to avoid an extra stabilization crop. Focus/exposure remain device controlled. This is RGB capture without calibrated pose; do not call these files calibrated or robot-ready.
- Duration, display dimensions after track transform, and nominal frame rate are read from the saved AVAsset. Nominal frame rate is **not** a guarantee of constant frame timestamps.
- The three guidance stamps are user confirmation. They are neither AR tracking nor automatic quality measurements.
- On background/session interruption, request recording stop and preserve a readable finished movie. A short iOS background task allows finalization when possible. Force termination, low storage or hardware failure can still lose an in-progress movie; do not promise recovery of an unfinalized container.
- Permission denial presents a Settings action. Returning to the foreground attempts camera setup again.

## Viewer limits and truthful result states

- Supports local `.ply` Gaussian models and 32-byte-record `.splat`. Current app/backend import does not support SPZ yet.
- Maximum **150 MiB** and **1,000,000 splats**. Apply matching backend validation so an accepted model can be loaded within the initial client limits. This is a conservative bound, not a guarantee for every phone; device profiling may require lower limits.
- PLY must be the Gaussian schema, including float32 position, scale, rotation and opacity. Server first version accepts `f_dc_0..2`; generic XYZ point clouds are rejected. The pinned reader accepts SH0 or all `f_rest_0..44` for SH3; partial SH1/SH2 exports need conversion before import.
- Actual SplatIO parser plus actual MetalSplatter renderer are used. No substitute sample city/model is displayed when loading fails.
- `onReady` fires once for each loaded result only after Metal's drawable presented handler reports a nonzero presentation time. A successful download or parse does not fire it. Dismissed, superseded, failed or never-presented render requests do not count as `result_viewed`.
- The viewer computes source bounds, fits an orbit camera, supports drag rotation, optional drag panning, pinch zoom, up-axis flip and reset. Flip is display orientation only, not a conversion of authoritative source coordinates.
- It does not invent scale, collision geometry, camera tracks or dual-use quality status. A model opening successfully proves only renderer compatibility.
- The view drops GPU frames instead of indefinitely blocking the main thread. Loading is cancellable; dismissal detaches delegate, stops rendering, clears chunks and releases drawable resources after outstanding GPU work completes.
- A file being parsed or rendered must not be marked `quality accepted`, `lineage verified`, or `dualUse accepted` automatically.

## Device checklist still required

1. Build and resolve packages on Mac; record Xcode version and resolved dependency commit.
2. Install to signed iPhone with iOS 18+; record model and OS version.
3. Test permission denial → Settings → return; no microphone prompt should appear.
4. Record a short indoor clip; confirm raw playback is upright, silent and without guidance overlays. Compare actual reported dimensions/duration against the file.
5. Test auto-stop at 90 seconds, manual stop, rapid repeated taps, app backgrounding, camera interruption and low-storage failure.
6. Terminate after save before upload; recover existing session plus local movie without duplicating reward. Confirm old unassociated files never silently attach to another task.
7. Import one real Gaussian PLY and one real `.splat`; test malformed/generic point cloud errors and size/count bounds.
8. Rotate, pan, zoom, flip, reset; repeatedly open/close the same model. Check memory growth, GPU errors, heat and frame rate.
9. Test an actual source-linked indoor and outdoor scan returned by the operator. Fixtures never count as this result.

Primary references: [MetalSplatter tag](https://github.com/scier/MetalSplatter/tree/1.0.1), [Apple capture setup](https://developer.apple.com/documentation/avfoundation/capture-setup), [Scaniverse workflow](https://www.nianticspatial.com/docs/scaniverse/quickstart/). Scaniverse is a manual external capture/export workflow in this MVP; no generic video-import API or automatic app-to-app transfer is assumed.
