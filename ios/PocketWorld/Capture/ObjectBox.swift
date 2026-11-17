import ARKit
import Combine
import SceneKit
import simd
import UIKit

/// The anchored scan target: an upright box in ARKit world coordinates (meters,
/// gravity-aligned, same frame as `frames.jsonl` poses), rotated about +Y only.
/// The capture screen shows it as an anchor point with a guide ring at its base;
/// the box itself only sizes that ring and fixes the coverage pivot.
struct ScanTargetBox: Codable, Equatable {
    /// Box center in world coordinates (the anchor point).
    var center: [Float]
    /// Width (box X), height (Y), depth (box Z) in meters.
    var size: [Float]
    /// Rotation about world +Y; the box's -Z faces away from the user who framed it.
    var yawRadians: Float
    /// How the target was obtained: "lidar", "plane" (no depth; raycast hit) or "adjusted".
    var source: String
    /// What was anchored: nil for an object, "person" for portrait mode. Optional so
    /// older `analysis.json` files decode unchanged.
    var subject: String? = nil

    var simdCenter: SIMD3<Float> { SIMD3(center[0], center[1], center[2]) }
    var simdSize: SIMD3<Float> { SIMD3(size[0], size[1], size[2]) }
    var isPerson: Bool { subject == "person" }

    init(center: SIMD3<Float>, size: SIMD3<Float>, yawRadians: Float, source: String, subject: String? = nil) {
        self.center = [center.x, center.y, center.z]
        self.size = [size.x, size.y, size.z]
        self.yawRadians = yawRadians
        self.source = source
        self.subject = subject
    }

    /// Where the object meets its support surface, directly below the anchor.
    var baseCenter: SIMD3<Float> { SIMD3(center[0], center[1] - size[1] / 2, center[2]) }

    /// Where the guide ring lies: on the floor around an object, but at waist height
    /// around a person, where it stays in frame while the phone points at the body.
    var ringCenter: SIMD3<Float> { isPerson ? simdCenter : baseCenter }

    /// Radius of the guide ring: just outside the object's footprint; a fixed 50 cm
    /// hoop around a person.
    var ringRadius: Float {
        if isPerson { return 0.5 }
        let footprint = max(size[0], size[2]) / 2
        return min(1.2, max(0.12, footprint * 1.25 + 0.05))
    }

    /// For a person: the standing body as a vertical segment (world Y), used to judge
    /// whether the phone points at any part of it rather than only at its center.
    var bodyAxis: ClosedRange<Float>? {
        guard isPerson else { return nil }
        let bottom = baseCenter.y
        return (bottom + 0.15)...(bottom + max(0.3, simdSize.y - 0.05))
    }

    func scaled(by factor: Float) -> ScanTargetBox {
        let bottom = simdCenter.y - simdSize.y / 2
        let newSize = simd_clamp(simdSize * factor, SIMD3(repeating: ObjectBoxEstimator.minSide),
                                 SIMD3(repeating: ObjectBoxEstimator.maxSide))
        // Keep the box standing on the same support surface.
        return ScanTargetBox(center: SIMD3(simdCenter.x, bottom + newSize.y / 2, simdCenter.z),
                             size: newSize, yawRadians: yawRadians, source: "adjusted", subject: subject)
    }

    /// e.g. "32 × 28 × 40 cm" (width × depth × height), or "身高约 1.7 m" for a person.
    var sizeLabel: String {
        if isPerson { return String(format: "身高约 %.1f m", size[1]) }
        let cm = simdSize * 100
        return String(format: "%.0f × %.0f × %.0f cm", cm.x, cm.z, cm.y)
    }
}

/// Pure geometry for fitting the target; unit-tested without ARKit.
enum ObjectBoxEstimator {
    static let minSide: Float = 0.05
    static let maxSide: Float = 2.5

    /// Connected region around `seed` (default: the image center) whose depth changes
    /// smoothly (the object there), limited to a window around the seed. Returns pixel indices.
    static func segment(depth: [Float], width: Int, height: Int,
                        windowFraction: Float = 0.45, confidence: [UInt8]? = nil,
                        seed seedPixel: (x: Int, y: Int)? = nil) -> [Int] {
        guard width > 2, height > 2, depth.count == width * height else { return [] }
        let halfW = max(1, Int(Float(width) * windowFraction / 2)), halfH = max(1, Int(Float(height) * windowFraction / 2))
        let cx = min(width - 1, max(0, seedPixel?.x ?? width / 2))
        let cy = min(height - 1, max(0, seedPixel?.y ?? height / 2))
        let minX = max(0, cx - halfW), maxX = min(width - 1, cx + halfW)
        let minY = max(0, cy - halfH), maxY = min(height - 1, cy + halfH)
        func valid(_ index: Int) -> Bool {
            let d = depth[index]
            guard d.isFinite, d > 0.1, d < 5 else { return false }
            if let confidence { return confidence[index] >= 1 } // medium or high
            return true
        }
        // Seed at the valid pixel nearest the requested point.
        var seed: Int?
        search: for radius in 0...3 {
            for dy in -radius...radius { for dx in -radius...radius {
                let x = cx + dx, y = cy + dy
                guard x >= minX, x <= maxX, y >= minY, y <= maxY else { continue }
                let index = y * width + x
                if valid(index) { seed = index; break search }
            } }
        }
        guard let seed else { return [] }
        var visited = [Bool](repeating: false, count: depth.count)
        var queue = [seed], result: [Int] = []
        visited[seed] = true
        var head = 0
        while head < queue.count {
            let index = queue[head]; head += 1
            result.append(index)
            let x = index % width, y = index / width, d = depth[index]
            for (nx, ny) in [(x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)]
            where nx >= minX && nx <= maxX && ny >= minY && ny <= maxY {
                let next = ny * width + nx
                guard !visited[next], valid(next) else { continue }
                // Continuous surface: neighbor depth within 3 cm + 2% of distance.
                guard abs(depth[next] - d) < 0.03 + 0.02 * d else { continue }
                visited[next] = true
                queue.append(next)
            }
        }
        return result
    }

    /// Fits an upright box to world points. `forward` is the camera's view direction;
    /// the box is aligned to it so it faces the user. Points at or below the support
    /// surface (table/floor) are discarded.
    static func fit(points: [SIMD3<Float>], forward: SIMD3<Float>, supportY: Float?) -> ScanTargetBox? {
        var flat = SIMD3<Float>(forward.x, 0, forward.z)
        guard simd_length(flat) > 1e-3 else { return nil }
        flat = simd_normalize(flat)
        let right = simd_normalize(simd_cross(flat, SIMD3<Float>(0, 1, 0)))
        let kept = supportY.map { y in points.filter { $0.y > y + 0.015 } } ?? points
        guard kept.count >= 30 else { return nil }
        func range(_ values: [Float]) -> (Float, Float) {
            let sorted = values.sorted()
            let low = sorted[Int(Float(sorted.count - 1) * 0.03)], high = sorted[Int(Float(sorted.count - 1) * 0.97)]
            return (low, high)
        }
        let (a0, a1) = range(kept.map { simd_dot($0, right) })
        let (b0, b1) = range(kept.map { simd_dot($0, flat) })
        let (y0, y1) = range(kept.map(\.y))
        let bottom = supportY ?? y0
        let margin: Float = 1.08
        var width = (a1 - a0) * margin + 0.02
        // Depth only sees the front surface; assume a roughly square footprint at least.
        var depth = max((b1 - b0) * margin + 0.02, width * 0.8)
        var height = (y1 - bottom) * margin + 0.01
        width = min(maxSide, max(minSide, width))
        depth = min(maxSide, max(minSide, depth))
        height = min(maxSide, max(minSide, height))
        let centerA = (a0 + a1) / 2, centerB = b0 - 0.01 + depth / 2, centerY = bottom + height / 2
        let center = right * centerA + flat * centerB + SIMD3(0, centerY, 0)
        return ScanTargetBox(center: center, size: SIMD3(width, height, depth),
                             yawRadians: atan2(-flat.x, -flat.z), source: "lidar")
    }

    static let defaultPersonHeight: Float = 1.7

    /// A standing person tapped at `hit` (a point on the body's front surface). The body
    /// axis sits about 12 cm behind the hit; height comes from the LiDAR points that lie
    /// near that axis (the top of the head), else a default 1.7 m. Walls and floor
    /// further away are ignored, so a flood fill that leaked into them does not matter.
    static func fitPerson(hit: SIMD3<Float>, forward: SIMD3<Float>, floorY: Float,
                          bodyPoints: [SIMD3<Float>], source: String) -> ScanTargetBox? {
        var flat = SIMD3<Float>(forward.x, 0, forward.z)
        guard simd_length(flat) > 1e-3, hit.y > floorY + 0.1 else { return nil }
        flat = simd_normalize(flat)
        let axis = SIMD2(hit.x + flat.x * 0.12, hit.z + flat.z * 0.12)
        let heights = bodyPoints
            .filter { $0.y > floorY + 0.05 && simd_length(SIMD2($0.x, $0.z) - axis) < 0.45 }
            .map(\.y).sorted()
        var height = defaultPersonHeight
        if heights.count >= 30 {
            let top = heights[Int(Float(heights.count - 1) * 0.98)]
            height = top - floorY + 0.03
        }
        // Never shorter than the tapped point plus a head; seated adult to tall adult.
        height = min(2.2, max(0.8, max(height, hit.y - floorY + 0.25)))
        return ScanTargetBox(center: SIMD3(axis.x, floorY + height / 2, axis.y),
                             size: SIMD3(0.6, height, 0.45), yawRadians: atan2(-flat.x, -flat.z),
                             source: source, subject: "person")
    }
}

/// Tap-to-anchor targeting in the AR view. The user taps the object; the app finds
/// it in the LiDAR depth around the tap (or the surface under it), marks its center
/// with an anchor point and draws a guide ring around its base. While recording the
/// ring lights up the angles already covered and points toward the next gap.
@MainActor
final class ScanAnchorController: ObservableObject {
    enum Phase: Equatable { case aiming, anchored }

    @Published private(set) var phase: Phase = .aiming
    @Published private(set) var target: ScanTargetBox?
    /// Portrait mode: a tap anchors a standing person instead of an object.
    var portrait = false
    private weak var view: ARSCNView?
    private let root = SCNNode()
    private var nextMarker: RecommendedPositionNode?
    private var targetPin: SCNNode?

    func attach(_ view: ARSCNView) {
        self.view = view
        if root.parent == nil { view.scene.rootNode.addChildNode(root) }
        root.isHidden = target == nil
    }

    /// Anchors the object under `point` (view coordinates). Returns false when nothing
    /// usable was found there, leaving any previous anchor in place.
    @discardableResult
    func place(at point: CGPoint) -> Bool {
        guard let view, let frame = view.session.currentFrame,
              case .normal = frame.camera.trackingState else { return false }
        let estimate = portrait
            ? Self.estimatePerson(frame: frame, view: view, at: point)
            : Self.estimateFromDepth(frame: frame, view: view, at: point)
                ?? Self.estimateFromRaycast(frame: frame, view: view, at: point)
        guard let estimate else { return false }
        target = estimate
        phase = .anchored
        render(estimate)
        return true
    }

    /// Anchors whatever is at the center of the screen.
    @discardableResult
    func placeAtCenter() -> Bool {
        guard let view else { return false }
        return place(at: CGPoint(x: view.bounds.midX, y: view.bounds.midY))
    }

    func clear() {
        target = nil
        phase = .aiming
        nextMarker = nil; targetPin = nil
        root.childNodes.forEach { $0.removeFromParentNode() }
        root.isHidden = true
    }

    func showNextPosition(_ suggestion: SubjectStepGuidance?, recording: Bool, suppressed: Bool = false) {
        targetPin?.isHidden = recording
        guard let marker = nextMarker else { return }
        marker.isHidden = !recording || suppressed || suggestion == nil || suggestion?.motion == .hold
        if let suggestion { marker.simdWorldPosition = suggestion.position }
    }

    // MARK: Estimation

    /// One LiDAR depth map copied out of the frame, with intrinsics scaled to it.
    private struct DepthSample {
        let depth: [Float]
        let confidence: [UInt8]?
        let width: Int, height: Int
        let fx: Float, fy: Float, cx: Float, cy: Float
        let transform: simd_float4x4

        func world(_ index: Int) -> SIMD3<Float> {
            let u = Float(index % width), v = Float(index / width), d = depth[index]
            let world = transform * SIMD4<Float>((u - cx) / fx * d, -(v - cy) / fy * d, -d, 1)
            return SIMD3(world.x, world.y, world.z)
        }

        /// Up to `limit` world points of a segmented region, evenly thinned.
        func worldPoints(_ region: [Int], limit: Int) -> [SIMD3<Float>] {
            let stride = max(1, region.count / limit)
            return Swift.stride(from: 0, to: region.count, by: stride).map { world(region[$0]) }
        }
    }

    private static func depthSample(_ frame: ARFrame) -> DepthSample? {
        guard let sceneDepth = frame.sceneDepth ?? frame.smoothedSceneDepth else { return nil }
        let map = sceneDepth.depthMap
        guard CVPixelBufferGetPixelFormatType(map) == kCVPixelFormatType_DepthFloat32 else { return nil }
        CVPixelBufferLockBaseAddress(map, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(map, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(map) else { return nil }
        let width = CVPixelBufferGetWidth(map), height = CVPixelBufferGetHeight(map)
        let rowBytes = CVPixelBufferGetBytesPerRow(map)
        var depth = [Float](repeating: 0, count: width * height)
        for y in 0..<height {
            let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: Float32.self)
            for x in 0..<width { depth[y * width + x] = row[x] }
        }
        var confidence: [UInt8]?
        if let confidenceMap = sceneDepth.confidenceMap,
           CVPixelBufferGetWidth(confidenceMap) == width, CVPixelBufferGetHeight(confidenceMap) == height {
            CVPixelBufferLockBaseAddress(confidenceMap, .readOnly)
            if let cBase = CVPixelBufferGetBaseAddress(confidenceMap) {
                let cRow = CVPixelBufferGetBytesPerRow(confidenceMap)
                var values = [UInt8](repeating: 0, count: width * height)
                for y in 0..<height {
                    let row = cBase.advanced(by: y * cRow).assumingMemoryBound(to: UInt8.self)
                    for x in 0..<width { values[y * width + x] = row[x] }
                }
                confidence = values
            }
            CVPixelBufferUnlockBaseAddress(confidenceMap, .readOnly)
        }
        // Depth map shares the captured image's sensor orientation; scale intrinsics to it.
        let imageSize = frame.camera.imageResolution
        let sx = Float(width) / Float(imageSize.width), sy = Float(height) / Float(imageSize.height)
        let k = frame.camera.intrinsics
        return DepthSample(depth: depth, confidence: confidence, width: width, height: height,
                           fx: k[0][0] * sx, fy: k[1][1] * sy, cx: k[2][0] * sx, cy: k[2][1] * sy,
                           transform: frame.camera.transform)
    }

    /// View point → depth-map pixel (the depth map shares the image orientation).
    private static func seedPixel(frame: ARFrame, view: ARSCNView, at point: CGPoint,
                                  width: Int, height: Int) -> (x: Int, y: Int)? {
        let viewport = view.bounds.size
        guard viewport.width > 0, viewport.height > 0 else { return nil }
        let orientation = view.window?.windowScene?.interfaceOrientation ?? .portrait
        let toImage = frame.displayTransform(for: orientation, viewportSize: viewport).inverted()
        let normalized = CGPoint(x: point.x / viewport.width, y: point.y / viewport.height).applying(toImage)
        guard (0...1).contains(normalized.x), (0...1).contains(normalized.y) else { return nil }
        return (x: min(width - 1, Int(normalized.x * CGFloat(width))),
                y: min(height - 1, Int(normalized.y * CGFloat(height))))
    }

    private static func forward(_ frame: ARFrame) -> SIMD3<Float> {
        let t = frame.camera.transform
        return -SIMD3(t.columns.2.x, t.columns.2.y, t.columns.2.z)
    }

    private static func estimateFromDepth(frame: ARFrame, view: ARSCNView, at point: CGPoint) -> ScanTargetBox? {
        guard let sample = depthSample(frame),
              let seed = seedPixel(frame: frame, view: view, at: point, width: sample.width, height: sample.height)
        else { return nil }
        let region = ObjectBoxEstimator.segment(depth: sample.depth, width: sample.width, height: sample.height,
                                                windowFraction: 0.5, confidence: sample.confidence, seed: seed)
        guard region.count >= 30 else { return nil }
        let points = sample.worldPoints(region, limit: 4000)
        let t = frame.camera.transform
        let seedPoint = points.first ?? SIMD3(t.columns.3.x, t.columns.3.y, t.columns.3.z)
        return ObjectBoxEstimator.fit(points: points, forward: forward(frame),
                                      supportY: supportHeight(below: seedPoint, in: frame))
    }

    /// Portrait: the person under the tap. The tapped body point comes from LiDAR depth
    /// (or a raycast without depth); the floor from ARKit planes; the height from the
    /// depth region connected to the tap across the whole frame.
    private static func estimatePerson(frame: ARFrame, view: ARSCNView, at point: CGPoint) -> ScanTargetBox? {
        var hit: SIMD3<Float>?
        var bodyPoints: [SIMD3<Float>] = []
        var source = "plane"
        if let sample = depthSample(frame),
           let seed = seedPixel(frame: frame, view: view, at: point, width: sample.width, height: sample.height) {
            // windowFraction 2 lets the region span the whole frame from any seed.
            let region = ObjectBoxEstimator.segment(depth: sample.depth, width: sample.width, height: sample.height,
                                                    windowFraction: 2, confidence: sample.confidence, seed: seed)
            if region.count >= 30 {
                hit = sample.world(region[0])
                bodyPoints = sample.worldPoints(region, limit: 6000)
                source = "lidar"
            }
        }
        if hit == nil, let query = view.raycastQuery(from: point, allowing: .estimatedPlane, alignment: .any),
           let result = view.session.raycast(query).first {
            let c = result.worldTransform.columns.3
            hit = SIMD3(c.x, c.y, c.z)
        }
        guard let hit else { return nil }
        let floor = floorHeight(below: hit, in: frame, session: view.session)
            ?? frame.camera.transform.columns.3.y - 1.35 // phone held at chest height
        return ObjectBoxEstimator.fitPerson(hit: hit, forward: forward(frame), floorY: floor,
                                            bodyPoints: bodyPoints, source: source)
    }

    /// The floor under a person: a plane ARKit classified as floor, else the lowest
    /// horizontal plane at least 30 cm below, else a downward raycast.
    private static func floorHeight(below point: SIMD3<Float>, in frame: ARFrame, session: ARSession) -> Float? {
        var floor: Float?, lowest: Float?
        for case let plane as ARPlaneAnchor in frame.anchors where plane.alignment == .horizontal {
            let y = plane.transform.columns.3.y
            guard y < point.y - 0.3 else { continue }
            if case .floor = plane.classification { floor = min(floor ?? y, y) }
            lowest = min(lowest ?? y, y)
        }
        if let value = floor ?? lowest { return value }
        let query = ARRaycastQuery(origin: point, direction: SIMD3(0, -1, 0),
                                   allowing: .estimatedPlane, alignment: .horizontal)
        return session.raycast(query).first.map { $0.worldTransform.columns.3.y }.flatMap { $0 < point.y - 0.3 ? $0 : nil }
    }

    /// Without usable depth: a 20 cm target standing on the surface under the tap.
    private static func estimateFromRaycast(frame: ARFrame, view: ARSCNView, at point: CGPoint) -> ScanTargetBox? {
        guard let query = view.raycastQuery(from: point, allowing: .estimatedPlane, alignment: .any),
              let hit = view.session.raycast(query).first else { return nil }
        let p = SIMD3(hit.worldTransform.columns.3.x, hit.worldTransform.columns.3.y, hit.worldTransform.columns.3.z)
        let normalY = hit.worldTransform.columns.1.y
        let back = SIMD3(frame.camera.transform.columns.2.x, 0, frame.camera.transform.columns.2.z)
        guard simd_length(back) > 1e-3 else { return nil }
        let flat = -simd_normalize(back)
        // Tapped a floor/table: the target stands there. Tapped a side: it stands on the
        // support below the hit (or about 10 cm lower when no plane is known).
        let bottom = normalY > 0.8 ? p.y : (supportHeight(below: p, in: frame) ?? p.y - 0.1)
        let height = max(0.1, min(0.6, (p.y - bottom) * 2))
        let side: Float = 0.2
        return ScanTargetBox(center: SIMD3(p.x, bottom + height / 2, p.z), size: SIMD3(side, height, side),
                             yawRadians: atan2(-flat.x, -flat.z), source: "plane")
    }

    /// Height of the detected horizontal plane directly below `point`, if any.
    private static func supportHeight(below point: SIMD3<Float>, in frame: ARFrame) -> Float? {
        var best: Float?
        for case let plane as ARPlaneAnchor in frame.anchors where plane.alignment == .horizontal {
            let y = plane.transform.columns.3.y
            guard y < point.y + 0.02 else { continue }
            let planeCenter = plane.transform * SIMD4(plane.center.x, 0, plane.center.z, 1)
            let reach = max(plane.planeExtent.width, plane.planeExtent.height) / 2 + 0.25
            guard simd_length(SIMD2(planeCenter.x - point.x, planeCenter.z - point.z)) < reach else { continue }
            if best.map({ y > $0 }) ?? true { best = y }
        }
        return best
    }

    // MARK: Rendering

    private func render(_ target: ScanTargetBox) {
        root.childNodes.forEach { $0.removeFromParentNode() }
        root.simdPosition = target.simdCenter
        let pin = AnchorPinNode(height: 0, ringRadius: target.ringRadius)
        root.addChildNode(pin); targetPin = pin
        let marker = RecommendedPositionNode()
        marker.isHidden = true; root.addChildNode(marker); nextMarker = marker
        root.isHidden = false
        root.opacity = 0
        root.runAction(.fadeIn(duration: 0.25))
    }
}

/// A single camera waypoint. The marker is not a circle or an obstacle-checked route.
final class RecommendedPositionNode: SCNNode {
    override init() {
        super.init()
        let plane = SCNPlane(width: 0.045, height: 0.045)
        plane.cornerRadius = 0.008
        let material = SCNMaterial(); material.lightingModel = .constant
        material.diffuse.contents = UIColor(red: 0.49, green: 0.23, blue: 0.93, alpha: 0.9)
        material.isDoubleSided = true; plane.materials = [material]
        let face = SCNNode(geometry: plane); face.eulerAngles.z = .pi / 4
        addChildNode(face)
        constraints = [SCNBillboardConstraint()]
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// The anchor point (drawn on top of everything so it stays visible on the object)
/// and a thin stem down to the ring's plane.
final class AnchorPinNode: SCNNode {
    init(height: Float, ringRadius: Float) {
        super.init()
        let dotRadius = CGFloat(max(0.006, ringRadius * 0.05))
        let dot = SCNSphere(radius: dotRadius)
        let dotMaterial = SCNMaterial()
        dotMaterial.lightingModel = .constant
        dotMaterial.diffuse.contents = UIColor.white
        dotMaterial.readsFromDepthBuffer = false
        dot.materials = [dotMaterial]
        let dotNode = SCNNode(geometry: dot)
        dotNode.simdPosition = SIMD3(0, height, 0)
        dotNode.renderingOrder = 100
        let halo = SCNSphere(radius: dotRadius * 1.9)
        let haloMaterial = SCNMaterial()
        haloMaterial.lightingModel = .constant
        haloMaterial.diffuse.contents = UIColor.white.withAlphaComponent(0.35)
        haloMaterial.readsFromDepthBuffer = false
        halo.materials = [haloMaterial]
        let haloNode = SCNNode(geometry: halo)
        haloNode.renderingOrder = 99
        haloNode.runAction(.repeatForever(.sequence([.scale(to: 1.25, duration: 0.7), .scale(to: 1, duration: 0.7)])))
        dotNode.addChildNode(haloNode)
        addChildNode(dotNode)
        guard height > 0.01 else { return }
        let stem = SCNCylinder(radius: CGFloat(max(0.0012, ringRadius * 0.008)), height: CGFloat(height))
        let stemMaterial = SCNMaterial()
        stemMaterial.lightingModel = .constant
        stemMaterial.diffuse.contents = UIColor.white.withAlphaComponent(0.55)
        stem.materials = [stemMaterial]
        let stemNode = SCNNode(geometry: stem)
        stemNode.simdPosition = SIMD3(0, height / 2, 0)
        addChildNode(stemNode)
    }

    required init?(coder: NSCoder) { nil }
}

/// A ring of `ScanCoverage.binCount` segments lying flat around the target's base.
/// Segment i covers the same angles as orbit bin i of `ScanCoverageTracker`, colored
/// with the same two colors as the 3D review: red = not captured yet, light green =
/// seen from one height, green = seen from two heights. Before recording, uncovered
/// segments are neutral white. Chevrons run along the ring from the phone's current
/// angle toward the next gap, which pulses.
final class CoverageRingNode: SCNNode {
    static let neutralColor = UIColor.white.withAlphaComponent(0.4)
    static let missingColor = UIColor(red: 1.0, green: 0.30, blue: 0.37, alpha: 1)
    static let coveredColor = UIColor(red: 0.25, green: 0.84, blue: 0.62, alpha: 0.45)
    static let multiHeightColor = UIColor(red: 0.25, green: 0.84, blue: 0.62, alpha: 1)

    /// Red for uncovered segments (recording, review) instead of neutral white.
    var showsMissing = false {
        didSet {
            guard showsMissing != oldValue else { return }
            for bin in segments.indices where bin != pulsingBin {
                segments[bin].geometry?.firstMaterial?.diffuse.contents = color(for: max(0, states[bin]))
            }
        }
    }

    let radius: Float
    private let thickness: Float
    private var segments: [SCNNode] = []
    private var states: [Int]
    private let marker = SCNNode()
    private let chevrons = SCNNode()
    private var guideKey: [Int]?
    private var pulsingBin: Int?

    init(radius: Float) {
        self.radius = radius
        thickness = max(0.008, radius * 0.07)
        states = [Int](repeating: -1, count: ScanCoverage.binCount)
        super.init()
        let count = ScanCoverage.binCount
        let arc = 2 * Float.pi * radius / Float(count)
        for bin in 0..<count {
            let theta = Self.angle(bin)
            let box = SCNBox(width: CGFloat(arc * 0.8), height: CGFloat(thickness * 0.35),
                             length: CGFloat(thickness), chamferRadius: CGFloat(thickness * 0.15))
            let material = SCNMaterial()
            material.lightingModel = .constant
            box.materials = [material]
            let node = SCNNode(geometry: box)
            node.simdPosition = SIMD3(radius * sin(theta), 0, radius * cos(theta))
            // Local +X becomes the tangent toward increasing bins ("right" around the target).
            node.simdEulerAngles = SIMD3(0, theta, 0)
            addChildNode(node)
            segments.append(node)
        }
        let dot = SCNSphere(radius: CGFloat(thickness * 0.85))
        let dotMaterial = SCNMaterial()
        dotMaterial.lightingModel = .constant
        dotMaterial.diffuse.contents = UIColor.white
        dot.materials = [dotMaterial]
        marker.geometry = dot
        marker.isHidden = true
        addChildNode(marker)
        addChildNode(chevrons)
        apply(ScanCoverage(), direction: nil)
    }

    required init?(coder: NSCoder) { nil }

    /// Center angle of orbit bin `bin`, matching `ScanCoverageTracker.bin`: atan2(x, z) + π.
    static func angle(_ bin: Int) -> Float {
        (Float(bin) + 0.5) / Float(ScanCoverage.binCount) * 2 * .pi - .pi
    }

    private func position(_ bin: Int, lift: Float) -> SIMD3<Float> {
        let theta = Self.angle(bin)
        return SIMD3(radius * sin(theta), lift, radius * cos(theta))
    }

    func color(for state: Int) -> UIColor {
        switch state {
        case 2: return Self.multiHeightColor
        case 1: return Self.coveredColor
        default: return showsMissing ? Self.missingColor : Self.neutralColor
        }
    }

    func apply(_ coverage: ScanCoverage, direction: ScanDirection?) {
        let count = ScanCoverage.binCount
        for bin in 0..<count {
            let covered = coverage.orbitBins.indices.contains(bin) && coverage.orbitBins[bin]
            let multi = coverage.heightBands.indices.contains(bin) && coverage.heightBands[bin].nonzeroBitCount >= 2
            let state = covered ? (multi ? 2 : 1) : 0
            guard states[bin] != state else { continue }
            states[bin] = state
            if bin != pulsingBin { segments[bin].geometry?.firstMaterial?.diffuse.contents = color(for: state) }
        }
        if let current = coverage.currentBin {
            marker.isHidden = false
            marker.simdPosition = position(current, lift: thickness * 0.6)
        } else {
            marker.isHidden = true
        }
        var target: (bin: Int, sign: Int, steps: Int)?
        if let current = coverage.currentBin, let direction {
            let step = 360 / count
            switch direction {
            case .right(let degrees): target = ((current + degrees / step) % count, 1, max(1, degrees / step))
            case .left(let degrees): target = ((current - degrees / step % count + count) % count, -1, max(1, degrees / step))
            default: break
            }
        }
        updateGuide(current: coverage.currentBin, target: target)
    }

    private func updateGuide(current: Int?, target: (bin: Int, sign: Int, steps: Int)?) {
        let key = target.map { [current ?? -1, $0.bin, $0.sign] }
        guard key != guideKey else { return }
        guideKey = key
        if let old = pulsingBin {
            segments[old].removeAction(forKey: "pulse")
            segments[old].opacity = 1
            segments[old].geometry?.firstMaterial?.diffuse.contents = color(for: max(0, states[old]))
            pulsingBin = nil
        }
        chevrons.childNodes.forEach { $0.removeFromParentNode() }
        guard let current, let target else { return }
        let segment = segments[target.bin]
        segment.geometry?.firstMaterial?.diffuse.contents = Self.missingColor
        segment.runAction(.repeatForever(.sequence([.fadeOpacity(to: 0.35, duration: 0.45),
                                                    .fadeOpacity(to: 1, duration: 0.45)])), forKey: "pulse")
        pulsingBin = target.bin
        // Up to three chevrons on the ring between the phone and the gap, pointing the way.
        let count = ScanCoverage.binCount
        for k in 1...min(3, target.steps) {
            let bin = ((current + target.sign * k) % count + count) % count
            let theta = Self.angle(bin)
            let tangent = SIMD3<Float>(cos(theta), 0, -sin(theta)) * Float(target.sign)
            let cone = SCNCone(topRadius: 0, bottomRadius: CGFloat(thickness * 0.9), height: CGFloat(thickness * 1.9))
            let material = SCNMaterial()
            material.lightingModel = .constant
            material.diffuse.contents = UIColor.white
            cone.materials = [material]
            let node = SCNNode(geometry: cone)
            node.simdPosition = position(bin, lift: thickness * 1.2)
            node.simdOrientation = simd_quatf(from: SIMD3(0, 1, 0), to: tangent)
            node.opacity = 0.3
            node.runAction(.sequence([.wait(duration: 0.18 * Double(k - 1)),
                                      .repeatForever(.sequence([.fadeOpacity(to: 1, duration: 0.3),
                                                                .fadeOpacity(to: 0.3, duration: 0.5)]))]))
            chevrons.addChildNode(node)
        }
    }
}
