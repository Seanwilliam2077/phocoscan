import simd

/// Red/green supervision of captured surfaces, shared by the live panel while
/// recording and the 3D review afterwards so both classify identically.
///
/// LiDAR depth from one view every `viewInterval` seconds is binned into cells.
/// A cell is green when it was seen from at least `minViews` views whose
/// directions spread by at least about 25° (enough parallax to triangulate);
/// otherwise it is red. This is observation geometry from recorded poses and
/// depth, a capture-guidance signal, not a reconstruction quality grade.
struct QualityVolume {
    static let viewInterval: Double = 0.5
    static let minViews = 3
    /// 1 - mean resultant length of the view directions; 0.025 ≈ a 25° spread.
    static let minSpread: Float = 0.025
    static let depthStride = 4

    struct Cell {
        var positionSum: SIMD3<Float>
        var count: Float
        var views: Int
        var directionSum: SIMD3<Float>
        var lastView: Int
        var isGood: Bool {
            views >= QualityVolume.minViews
                && 1 - simd_length(directionSum) / Float(views) >= QualityVolume.minSpread
        }
        var center: SIMD3<Float> { positionSum / count }
    }

    /// Optional region of interest: an anchored object's base and reach.
    struct Region {
        let base: SIMD3<Float>
        let reach: Float
        let top: Float
        init(target: ScanTargetBox) {
            base = target.baseCenter
            reach = target.ringRadius * 1.8
            // An object's height is only seen from the front, so allow well above it; a
            // person's height comes from the head, so the region stops just above it.
            top = base.y + (target.isPerson ? target.simdSize.y + 0.15
                                             : max(target.simdSize.y * 2.5, target.ringRadius * 2))
        }
        func contains(_ p: SIMD3<Float>) -> Bool {
            p.y >= base.y - 0.03 && p.y <= top && simd_length(SIMD2(p.x - base.x, p.z - base.z)) <= reach
        }
    }

    let cellSize: Float
    let region: Region?
    let maxCells: Int
    private(set) var cells: [SIMD3<Int32>: Cell] = [:]
    private(set) var viewCount = 0

    /// Cell size follows the anchored object (about 2 cm for a small object), else 5 cm.
    /// Coarser than the LiDAR noise so one surface is not split across cells.
    static func cellSize(for target: ScanTargetBox?) -> Float {
        target.map { min(0.06, max(0.012, $0.ringRadius / 6)) } ?? 0.05
    }

    init(target: ScanTargetBox?, cropToTarget: Bool, maxCells: Int = 60_000) {
        cellSize = Self.cellSize(for: target)
        region = cropToTarget ? target.map(Region.init) : nil
        self.maxCells = maxCells
    }

    func key(_ p: SIMD3<Float>) -> SIMD3<Int32> {
        SIMD3<Int32>(Int32((p.x / cellSize).rounded(.down)), Int32((p.y / cellSize).rounded(.down)),
                     Int32((p.z / cellSize).rounded(.down)))
    }

    /// Adds one view: world points seen from `camera`.
    mutating func add(points: [SIMD3<Float>], camera: SIMD3<Float>) {
        let view = viewCount
        viewCount += 1
        for p in points {
            if let region, !region.contains(p) { continue }
            let k = key(p)
            let toCamera = camera - p
            let length = simd_length(toCamera)
            guard length > 1e-4 else { continue }
            let direction = toCamera / length
            if var cell = cells[k] {
                cell.positionSum += p; cell.count += 1
                if cell.lastView != view {
                    cell.lastView = view; cell.views += 1; cell.directionSum += direction
                }
                cells[k] = cell
            } else if cells.count < maxCells {
                cells[k] = Cell(positionSum: p, count: 1, views: 1, directionSum: direction, lastView: view)
            }
        }
    }

    func isGood(at p: SIMD3<Float>) -> Bool? { cells[key(p)]?.isGood }

    var goodFraction: Double {
        guard !cells.isEmpty else { return 0 }
        return Double(cells.values.filter(\.isGood).count) / Double(cells.count)
    }

    /// Back-projects LiDAR depth (every `stride` pixels, medium+ confidence, 0.1–4 m).
    /// `intrinsics` are (fx, fy, cx, cy) in depth-map pixels; ARKit camera axes.
    static func unproject(width: Int, height: Int, stride: Int = depthStride,
                          intrinsics: SIMD4<Float>, cameraToWorld: simd_float4x4,
                          depth: (Int) -> Float, confidence: ((Int) -> UInt8)?) -> [SIMD3<Float>] {
        let fx = intrinsics.x, fy = intrinsics.y, cx = intrinsics.z, cy = intrinsics.w
        guard fx > 0, fy > 0, width > 0, height > 0 else { return [] }
        var points: [SIMD3<Float>] = []
        points.reserveCapacity((width / stride + 1) * (height / stride + 1))
        for y in Swift.stride(from: 0, to: height, by: stride) {
            for x in Swift.stride(from: 0, to: width, by: stride) {
                let index = y * width + x
                let d = depth(index)
                guard d.isFinite, d > 0.1, d < 4 else { continue }
                if let confidence, confidence(index) < 1 { continue }
                let local = SIMD4<Float>((Float(x) + 0.5 - cx) / fx * d, -(Float(y) + 0.5 - cy) / fy * d, -d, 1)
                let world = cameraToWorld * local
                points.append(SIMD3(world.x, world.y, world.z))
            }
        }
        return points
    }

    /// A row-major 4×4 (as stored in `frames.jsonl`) as a simd matrix.
    static func matrix(rowMajor m: [[Float]]) -> simd_float4x4? {
        guard m.count == 4, m.allSatisfy({ $0.count == 4 }) else { return nil }
        return simd_float4x4(columns: (SIMD4(m[0][0], m[1][0], m[2][0], m[3][0]),
                                       SIMD4(m[0][1], m[1][1], m[2][1], m[3][1]),
                                       SIMD4(m[0][2], m[1][2], m[2][2], m[3][2]),
                                       SIMD4(m[0][3], m[1][3], m[2][3], m[3][3])))
    }
}

/// What the live panel draws: cell centers with their red/green state.
struct LiveQualitySnapshot: Equatable {
    var version = 0
    var positions: [SIMD3<Float>] = []
    var good: [Bool] = []
    var camera: SIMD3<Float>?
    var goodFraction = 0.0

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.version == rhs.version }

    init() {}
    init(volume: QualityVolume, camera: SIMD3<Float>?, version: Int) {
        self.version = version
        self.camera = camera
        positions.reserveCapacity(volume.cells.count)
        good.reserveCapacity(volume.cells.count)
        for cell in volume.cells.values {
            positions.append(cell.center)
            good.append(cell.isGood)
        }
        goodFraction = volume.goodFraction
    }
}
