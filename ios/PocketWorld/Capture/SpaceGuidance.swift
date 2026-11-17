import simd

/// A short instruction based on saved views. Pose-only walking never completes a step.
struct SpaceGuidance: Equatable {
    struct Action: Equatable {
        let text: String
        let symbol: String
        var warning = false
    }
    private(set) var savedCount = 0
    private var firstPosition: SIMD3<Float>?
    private var firstForward: SIMD3<Float>?
    private var lastSavedTime: Double?
    private var currentTime: Double = 0
    private var beganAt: Double?
    private(set) var baseline: Float = 0
    private(set) var upperSaved = false
    private(set) var lowerSaved = false
    private(set) var obliqueSaved = false

    mutating func update(transform: simd_float4x4, timestamp: Double) {
        guard timestamp.isFinite else { return }
        currentTime = timestamp
        if beganAt == nil { beganAt = timestamp }
    }
    mutating func recordSaved(transform: simd_float4x4, timestamp: Double) {
        guard timestamp.isFinite, lastSavedTime.map({ timestamp > $0 }) ?? true else { return }
        let p = SIMD3(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
        let f = -SIMD3(transform.columns.2.x, transform.columns.2.y, transform.columns.2.z)
        guard [p.x,p.y,p.z,f.x,f.y,f.z].allSatisfy(\.isFinite), simd_length(f) > 0.9 else { return }
        savedCount += 1; lastSavedTime = timestamp
        if firstPosition == nil { firstPosition = p; firstForward = simd_normalize(f) }
        let delta = p - firstPosition!
        baseline = max(baseline, simd_length(SIMD2(delta.x, delta.z)))
        // Count a height only with some translation; panning in place is insufficient.
        if baseline >= 0.35 {
            upperSaved = upperSaved || f.y > 0.22 || delta.y > 0.25
            lowerSaved = lowerSaved || f.y < -0.22 || delta.y < -0.25
            obliqueSaved = obliqueSaved || simd_dot(simd_normalize(f), firstForward!) < cos(25 * Float.pi / 180)
        }
    }
    func action(coverage c: ScanCoverage, elapsed: Int) -> Action {
        if currentTime - (lastSavedTime ?? beganAt ?? currentTime) > 5 {
            return Action(text: "停稳，对准有纹理处", symbol: "viewfinder", warning: true)
        }
        if savedCount < 2 { return Action(text: "对准墙角，停稳拍摄", symbol: "camera") }
        if elapsed >= 60 {
            if c.loopClosed { return Action(text: "本段已回到起点，可结束", symbol: "checkmark") }
            return Action(text: c.distanceFromStart < 0.5 ? "对准开始的画面" : "沿原路回到起点", symbol: "arrow.uturn.backward")
        }
        if baseline < 0.7 || savedCount < 6 {
            return Action(text: c.lateralMeters < -0.15 ? "向左小步，保留重叠" : "向右小步，保留重叠", symbol: c.lateralMeters < -0.15 ? "arrow.left" : "arrow.right")
        }
        if !upperSaved { return Action(text: "镜头稍抬高，补拍上方", symbol: "arrow.up") }
        if !lowerSaved { return Action(text: "镜头稍放低，补拍地面", symbol: "arrow.down") }
        if !obliqueSaved { return Action(text: "侧走一步，斜拍这个角落", symbol: "arrow.up.right") }
        if c.loopClosed { return Action(text: "本段可结束，或继续补拍", symbol: "checkmark") }
        return Action(text: "慢移到相邻区域，保留重叠", symbol: "rectangle.on.rectangle")
    }
}
