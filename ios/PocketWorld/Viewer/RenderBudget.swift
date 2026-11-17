import CoreGraphics
import Foundation
import simd
import SplatIO

/// Device class for 3DGS rendering. Thresholds are starting values from
/// docs/MOBILE-3DGS-RENDERING-PLAN.md and must be recalibrated with R0 measurements.
enum RenderTier: String, Sendable, CaseIterable {
    case flagship, mainstream, entry

    var label: String {
        switch self {
        case .flagship: return "旗舰"
        case .mainstream: return "主流"
        case .entry: return "入门"
        }
    }
}

/// Everything the viewer may spend on one model on this device right now.
struct RenderBudget: Equatable, Sendable {
    var tier: RenderTier
    /// Splats kept on the GPU; larger models are pruned by importance.
    var maxPoints: Int
    /// Highest spherical-harmonics degree kept (0…3).
    var maxSHDegree: Int
    /// Drawable scale range for the dynamic-resolution governor.
    var minScale: CGFloat
    var maxScale: CGFloat
    var preferredFPS: Int
    /// True when the device is hot and the budget was lowered.
    var thermalReduced: Bool

    static func forDevice(physicalMemory: UInt64, thermal: ProcessInfo.ThermalState,
                          screenScale: CGFloat) -> RenderBudget {
        let gigabytes = Double(physicalMemory) / 1_073_741_824
        var budget: RenderBudget
        if gigabytes >= 7 {
            budget = RenderBudget(tier: .flagship, maxPoints: 1_500_000, maxSHDegree: 3,
                                  minScale: 1.0, maxScale: 2.0, preferredFPS: 60, thermalReduced: false)
        } else if gigabytes >= 5 {
            budget = RenderBudget(tier: .mainstream, maxPoints: 800_000, maxSHDegree: 2,
                                  minScale: 1.0, maxScale: 1.5, preferredFPS: 30, thermalReduced: false)
        } else {
            budget = RenderBudget(tier: .entry, maxPoints: 400_000, maxSHDegree: 0,
                                  minScale: 1.0, maxScale: 1.25, preferredFPS: 30, thermalReduced: false)
        }
        budget.maxScale = max(1.0, min(budget.maxScale, screenScale))
        budget.minScale = min(budget.minScale, budget.maxScale)
        if thermal == .serious || thermal == .critical {
            budget.maxPoints = budget.maxPoints * 6 / 10
            budget.maxSHDegree = min(budget.maxSHDegree, 1)
            budget.maxScale = budget.minScale
            budget.preferredFPS = 30
            budget.thermalReduced = true
        }
        return budget
    }

    var summary: String {
        "\(tier.label) · \(maxPoints / 10_000) 万点 · SH≤\(maxSHDegree)" + (thermalReduced ? " · 降温中" : "")
    }
}

/// Importance-based reduction for models above the device budget.
enum SplatPruning {
    /// Screen-contribution proxy: opacity × projected area (volume^(2/3)).
    static func importance(opacity: Float, scale: SIMD3<Float>) -> Float {
        let alpha = max(0, min(1, opacity.isFinite ? opacity : 0))
        let s = simd_max(scale, SIMD3(repeating: 0))
        let volume = s.x * s.y * s.z
        guard volume.isFinite, volume > 0 else { return 0 }
        return alpha * pow(volume, 2.0 / 3.0)
    }

    /// Indices of the `count` most important splats, returned in original file order.
    static func topIndices(_ scores: [Float], count: Int) -> [Int] {
        guard count < scores.count else { return Array(scores.indices) }
        guard count > 0 else { return [] }
        let order = scores.indices.sorted { scores[$0] > scores[$1] }
        return order.prefix(count).sorted()
    }
}

extension SplatPruning {
    /// Keeps SH bands 0…degree. Coefficients are RGB triplets stored DC first, then by band.
    static func truncatedSH(_ coefficients: [SIMD3<Float>], degree: Int) -> [SIMD3<Float>] {
        let keep = (max(0, degree) + 1) * (max(0, degree) + 1)
        return coefficients.count > keep ? Array(coefficients.prefix(keep)) : coefficients
    }
}

extension SplatPoint {
    /// Drops spherical-harmonic bands above `degree`.
    func limitingSH(to degree: Int) -> SplatPoint {
        guard case let .sphericalHarmonicFloat(coefficients) = color else { return self }
        let kept = SplatPruning.truncatedSH(coefficients, degree: degree)
        guard kept.count < coefficients.count else { return self }
        var copy = self
        copy.color = .sphericalHarmonicFloat(kept)
        return copy
    }
}

/// Keeps GPU frame time inside the frame budget by adjusting drawable scale:
/// drop quickly when slow, climb back slowly when there is clear headroom.
struct ResolutionGovernor {
    private(set) var scale: CGFloat
    private(set) var minScale: CGFloat
    private(set) var maxScale: CGFloat
    private var samples: [Double] = []
    private var cheapWindows = 0
    static let window = 20

    init(scale: CGFloat, minScale: CGFloat, maxScale: CGFloat) {
        self.minScale = minScale
        self.maxScale = max(minScale, maxScale)
        self.scale = min(self.maxScale, max(minScale, scale))
    }

    mutating func setRange(minScale: CGFloat, maxScale: CGFloat) {
        self.minScale = minScale
        self.maxScale = max(minScale, maxScale)
        scale = min(self.maxScale, max(self.minScale, scale))
    }

    /// Records one frame's GPU time; returns a new scale when it should change.
    mutating func record(gpuSeconds: Double, frameBudget: Double) -> CGFloat? {
        guard gpuSeconds.isFinite, gpuSeconds >= 0, frameBudget > 0 else { return nil }
        samples.append(gpuSeconds)
        guard samples.count >= Self.window else { return nil }
        let average = samples.reduce(0, +) / Double(samples.count)
        samples.removeAll(keepingCapacity: true)
        if average > 0.85 * frameBudget {
            cheapWindows = 0
            guard scale > minScale else { return nil }
            scale = max(minScale, scale - 0.15)
            return scale
        }
        if average < 0.45 * frameBudget {
            cheapWindows += 1
            guard cheapWindows >= 3, scale < maxScale else { return nil }
            cheapWindows = 0
            scale = min(maxScale, scale + 0.1)
            return scale
        }
        cheapWindows = 0
        return nil
    }
}
