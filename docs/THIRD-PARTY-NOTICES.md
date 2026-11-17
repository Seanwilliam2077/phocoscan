# Third-party notices

## MetalSplatter

Source: https://github.com/scier/MetalSplatter/tree/1.0.1  
Pinned revision: `71ff248e3016ac43c0a9271e322538421b28c360`

The app links the MetalSplatter and SplatIO Swift package products. The renderer integration in `ios/PocketWorld/Viewer/PocketSplatRenderer.swift` is adapted from upstream SampleApp's MetalKit rendering flow. All game content, capture flow and interactions are project-specific. Preserve this notice with source distributions; include license text in the app acknowledgments before distribution.

```text
MIT License

Copyright (c) 2026 Sean Cier

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## Transitive packages

The pinned MetalSplatter manifest references [scier/spz-swift](https://github.com/scier/spz-swift) from 2.1.0 and [Apple swift-argument-parser](https://github.com/apple/swift-argument-parser) from 1.0.0. The prepared `Package.resolved` pins spz-swift 2.1.0 (`e2410c91bceba2539c11157ad92e488ef6e16416`) and swift-argument-parser 1.6.2 (`cdd0ef3755280949551dc26dee5de9ddeda89f54`), checked against upstream tag hashes and package manifests. Actual SwiftPM resolution still requires the build Mac. Retain the resolved versions and matching licenses if they change. The app does not expose the converter executable or SPZ import in this MVP. Copies of the source licenses and spz notice are in `docs/licenses/` and are included in the app acknowledgments.

## Visual assets

The media screens use native SwiftUI shapes and system symbols. No downloaded model or photo is bundled in these modules. A third-party splat must only be used with rights appropriate to the test and be clearly labeled as a fixture if it is not the user's own capture.

## Server-side SPZ conversion (2026-11-10)

The dedicated PocketWorld Python runtime uses the official Niantic SPZ implementation, revision `affd0ecea7fbb4c265ee119475af7ee5b2997482` (Python package 1.1.0), for v3 derivatives; preserve its Apache-2.0 license/NOTICE in installed distributions. This is separate from the pinned iOS spz-swift reader. Source PLY is preserved and SPZ is labeled lossy. Existing SPZ/MetalSplatter acknowledgments remain in the app.

The single-image integration calls the already-deployed AgeScan TripoSplat service through a new PocketWorld adapter. It does not embed the colleague's application, model weights or service implementation into the iOS bundle. Model/service usage terms remain those of that deployment; no additional training rights are inferred from a generated result.
