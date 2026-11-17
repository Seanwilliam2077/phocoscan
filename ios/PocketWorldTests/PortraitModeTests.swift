import XCTest
import simd
@testable import PocketWorld

/// Portrait mode: anchoring a standing person and the two-height orbit around them.
/// Synthetic poses and points only.
final class PortraitModeTests: XCTestCase {
    private func look(from position: SIMD3<Float>, at target: SIMD3<Float>) -> simd_float4x4 {
        let back = -simd_normalize(target - position)
        let right = simd_normalize(simd_cross(SIMD3<Float>(0, 1, 0), back))
        let up = simd_cross(back, right)
        return simd_float4x4(columns: (SIMD4(right, 0), SIMD4(up, 0), SIMD4(back, 0), SIMD4(position, 1)))
    }

    private func person(height: Float = 1.7) -> ScanTargetBox {
        ScanTargetBox(center: SIMD3(0, height / 2, 0), size: SIMD3(0.6, height, 0.45),
                      yawRadians: 0, source: "lidar", subject: "person")
    }

    /// The head sets the height; a wall the flood fill leaked into does not.
    func testPersonHeightComesFromPointsNearTheBodyNotTheWall() throws {
        let hit = SIMD3<Float>(0, 1.2, -1.5)
        var points = stride(from: Float(0.1), through: 1.76, by: 0.01).map { SIMD3<Float>(0.05, $0, -1.62) }
        points += stride(from: Float(0), through: 2.6, by: 0.01).map { SIMD3<Float>(0.8, $0, -2.5) } // wall
        let box = try XCTUnwrap(ObjectBoxEstimator.fitPerson(hit: hit, forward: SIMD3(0, 0, -1), floorY: 0,
                                                             bodyPoints: points, source: "lidar"))
        XCTAssertTrue(box.isPerson)
        XCTAssertEqual(box.simdSize.y, 1.77, accuracy: 0.04)
        XCTAssertEqual(box.baseCenter.y, 0, accuracy: 1e-5, "stands on the floor")
        XCTAssertEqual(box.simdCenter.z, -1.62, accuracy: 1e-4, "body axis sits behind the tapped surface")
        XCTAssertEqual(box.ringCenter, box.simdCenter, "ring at waist height")
        XCTAssertEqual(box.ringRadius, 0.5)
        XCTAssertEqual(person().sizeLabel, "身高约 1.7 m")
    }

    func testPersonWithoutDepthGetsTheDefaultHeight() throws {
        let box = try XCTUnwrap(ObjectBoxEstimator.fitPerson(hit: SIMD3(0, 1.1, -1.2), forward: SIMD3(0, 0, -1),
                                                             floorY: -0.2, bodyPoints: [], source: "plane"))
        XCTAssertEqual(box.simdSize.y, ObjectBoxEstimator.defaultPersonHeight, accuracy: 1e-5)
        XCTAssertNil(ObjectBoxEstimator.fitPerson(hit: SIMD3(0, 0.05, -1), forward: SIMD3(0, 0, -1),
                                                  floorY: 0, bodyPoints: [], source: "plane"),
                     "a tap on the floor is not a person")
    }

    /// Scans saved before portrait mode have no `subject`; they must stay objects.
    func testOlderTargetBoxesDecodeAsObjects() throws {
        let json = #"{"center":[0,0.1,-1],"size":[0.2,0.2,0.2],"yawRadians":0,"source":"lidar"}"#
        let old = try JSONDecoder().decode(ScanTargetBox.self, from: Data(json.utf8))
        XCTAssertFalse(old.isPerson)
        XCTAssertEqual(old.ringCenter, old.baseCenter)
        XCTAssertNil(old.bodyAxis)
        let roundTrip = try JSONDecoder().decode(ScanTargetBox.self, from: JSONEncoder().encode(person()))
        XCTAssertTrue(roundTrip.isPerson)
    }

    /// Pointing at the head from chest height still counts as seeing the person. The
    /// plan's rounds: chest height (whole body), then head height (face and hair), then
    /// a frontal face; heights are judged from where the phone is relative to the body.
    func testPortraitRoundsAreChestThenHeadThenFace() {
        let target = person()
        let body = target.baseCenter.y...(target.baseCenter.y + target.size[1])
        var portrait = ScanCoverageTracker(portrait: true)
        portrait.lockPivot(target.simdCenter, axis: target.bodyAxis, body: body)
        var pointOnly = ScanCoverageTracker()
        pointOnly.lockPivot(target.simdCenter)
        for step in 0..<360 {
            let a = Float(step) * .pi / 180
            let phone = SIMD3<Float>(1.2 * sin(a), 1.3, 1.2 * cos(a)) // chest height: 76% of 1.7 m
            let pose = look(from: phone, at: SIMD3(0, 1.65, 0)) // aimed at the head
            portrait.add(transform: pose)
            pointOnly.add(transform: pose)
        }
        XCTAssertEqual(portrait.snapshot.orbitFraction, 1, accuracy: 1e-9)
        XCTAssertEqual(pointOnly.snapshot.orbitFraction, 0, accuracy: 1e-9, "the body center alone is out of frame")
        XCTAssertTrue(portrait.snapshot.heightBands.allSatisfy { $0 == 2 }, "chest round")
        XCTAssertEqual(portrait.snapshot.suggestedDirection(for: .portrait), .up, "then the head round")
        XCTAssertEqual(portrait.snapshot.completeness(for: .portrait), 0.55, accuracy: 1e-9)

        for step in 0..<360 {
            let a = Float(step) * .pi / 180
            portrait.add(transform: look(from: SIMD3(0.8 * sin(a), 1.6, 0.8 * cos(a)), at: SIMD3(0, 1.55, 0)))
        }
        XCTAssertEqual(portrait.snapshot.bandFraction(4), 1, accuracy: 1e-9, "head round")
        XCTAssertEqual(portrait.snapshot.suggestedDirection(for: .portrait), .face)
        XCTAssertEqual(portrait.snapshot.completeness(for: .portrait), 0.85, accuracy: 1e-9)
        portrait.markFrontFace()
        XCTAssertEqual(portrait.snapshot.suggestedDirection(for: .portrait), .none)
        XCTAssertEqual(portrait.snapshot.completeness(for: .portrait), 1, accuracy: 1e-9)
    }

    /// Mid-way through the head round the guide points at the nearest angle not yet
    /// seen from head height; from chest height it says to go up.
    func testHeadRoundGuidesToItsOwnGaps() {
        var value = ScanCoverage()
        value.orbitBins = [Bool](repeating: true, count: ScanCoverage.binCount)
        value.heightBands = [UInt8](repeating: 2, count: ScanCoverage.binCount)
        for bin in 0..<10 { value.heightBands[bin] |= 4 }
        value.currentBin = 9
        value.currentHeightBand = 2
        XCTAssertEqual(value.suggestedDirection(for: .portrait), .up)
        value.currentHeightBand = 4
        XCTAssertEqual(value.suggestedDirection(for: .portrait), .right(degrees: 10))
    }

    /// Objects: after a top-down round, go level; after a level or mid round, go higher.
    func testObjectAsksForTheMissingHeight() {
        var value = ScanCoverage()
        value.orbitBins = [Bool](repeating: true, count: ScanCoverage.binCount)
        value.currentBin = 3
        value.currentHeightBand = 4
        value.heightBands = [UInt8](repeating: 4, count: ScanCoverage.binCount)
        XCTAssertEqual(value.suggestedDirection(for: .object), .down)
        value.currentHeightBand = 2
        value.heightBands = [UInt8](repeating: 2, count: ScanCoverage.binCount)
        XCTAssertEqual(value.suggestedDirection(for: .object), .up)
        value.heightBands = [UInt8](repeating: 6, count: ScanCoverage.binCount)
        XCTAssertEqual(value.suggestedDirection(for: .object), .none, "two heights everywhere, and no face step")
    }

    func testPersonRegionStopsAboveTheHead() {
        let region = QualityVolume.Region(target: person())
        XCTAssertTrue(region.contains(SIMD3(0, 1.7, 0.1)))
        XCTAssertTrue(region.contains(SIMD3(0.7, 0.0, 0)), "floor around the feet")
        XCTAssertFalse(region.contains(SIMD3(0, 2.0, 0)), "ceiling")
        XCTAssertFalse(region.contains(SIMD3(1.2, 1.0, 0)), "furniture beyond the ring")
    }

    func testPortraitAnalysisGivesPersonAdvice() {
        let analysis = ScanAnalyzer().finalize(coverage: ScanCoverage(), mode: .portrait)
        XCTAssertEqual(analysis.mode, "portrait")
        XCTAssertEqual(ScanMode(rawValue: analysis.mode), .portrait)
        XCTAssertTrue(analysis.suggestions.contains("从不同位置补拍侧面和背面"))
        XCTAssertFalse(analysis.suggestions.contains { $0.contains("物体") })
    }
}
