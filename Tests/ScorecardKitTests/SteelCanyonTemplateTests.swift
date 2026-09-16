import XCTest
@testable import ScorecardKit

/// Guards the golden template's data.
///
/// These are transcription tests, not tautologies: they assert the arithmetic relationships printed on the
/// physical card (front + back = total par, each tee's yardages sum to its printed total, the stroke index
/// is a permutation of 1...18). A typo introduced while editing the arrays breaks at least one of them,
/// which is exactly what a golden fixture is for — every OCR-tolerance test downstream is only meaningful
/// if this data is right.
final class SteelCanyonTemplateTests: XCTestCase {

    private let template = SteelCanyonTemplate.template

    func testHasEighteenHoles() {
        XCTAssertEqual(template.holeCount, 18)
        XCTAssertEqual(template.pars.count, 18)
        XCTAssertEqual(template.handicapIndices.count, 18)
        XCTAssertTrue(template.isHoleCountKnown)
    }

    func testTotalParIsSixtyOne() {
        XCTAssertEqual(template.totalPar, 61)
        XCTAssertEqual(template.frontNinePar, 31)
        XCTAssertEqual(template.backNinePar, 30)
        XCTAssertEqual((template.frontNinePar ?? 0) + (template.backNinePar ?? 0), template.totalPar)
    }

    func testParSequenceMatchesTheCard() {
        let expected = [4, 4, 3, 3, 3, 5, 3, 3, 3, 3, 4, 3, 3, 3, 4, 4, 3, 3]
        XCTAssertEqual(template.pars.map { $0 ?? -1 }, expected)
        // Steel Canyon is an executive course: twelve par 3s, five par 4s and a single par 5.
        // Asserting the whole distribution, not just one bucket, makes the arithmetic self-checking:
        // 12x3 + 5x4 + 1x5 = 61 across 18 holes.
        XCTAssertEqual(expected.filter { $0 == 3 }.count, 12)
        XCTAssertEqual(expected.filter { $0 == 4 }.count, 5)
        XCTAssertEqual(expected.filter { $0 == 5 }.count, 1)
        XCTAssertEqual(expected.count, 18)
        XCTAssertEqual(expected.reduce(0, +), 61)
    }

    func testHandicapSequenceIsCorrectAndIsAPermutation() {
        let expected = [3, 5, 15, 9, 17, 1, 11, 7, 13, 12, 4, 16, 18, 8, 6, 2, 14, 10]
        XCTAssertEqual(template.handicapIndices.map { $0 ?? -1 }, expected)
        XCTAssertEqual(Set(expected), Set(1...18), "Stroke indices must be a permutation of 1...18")
        // Odd indices on the front nine, even on the back: the standard allocation, and a strong signal
        // that the two halves were not transposed during transcription.
        XCTAssertEqual(Set(expected.prefix(9)), Set(stride(from: 1, through: 17, by: 2)))
        XCTAssertEqual(Set(expected.suffix(9)), Set(stride(from: 2, through: 18, by: 2)))
    }

    func testEachTeeMapsYardagesToTheCorrectHoles() {
        guard let black = template.teeSet(named: "Black"),
              let white = template.teeSet(named: "White"),
              let red = template.teeSet(named: "Red") else {
            return XCTFail("Steel Canyon must define Black, White and Red tees")
        }

        // Spot-check holes at both ends and the par 5, so an off-by-one shift cannot pass.
        XCTAssertEqual(black.yardage(forHole: 1), 317)
        XCTAssertEqual(black.yardage(forHole: 6), 501)
        XCTAssertEqual(black.yardage(forHole: 18), 153)

        XCTAssertEqual(white.yardage(forHole: 1), 289)
        XCTAssertEqual(white.yardage(forHole: 16), 333)
        XCTAssertEqual(white.yardage(forHole: 18), 116)

        XCTAssertEqual(red.yardage(forHole: 1), 262)
        XCTAssertEqual(red.yardage(forHole: 13), 71)
        XCTAssertEqual(red.yardage(forHole: 18), 83)

        for tee in template.teeSets {
            XCTAssertEqual(tee.yardages.count, 18, "\(tee.name) must cover all 18 holes")
            XCTAssertTrue(tee.hasCompleteYardages, "\(tee.name) must have no gaps")
        }

        // Every tee must get shorter as you move forward, on every single hole.
        for hole in 1...18 {
            guard let b = black.yardage(forHole: hole),
                  let w = white.yardage(forHole: hole),
                  let r = red.yardage(forHole: hole) else {
                return XCTFail("Missing yardage on hole \(hole)")
            }
            XCTAssertGreaterThan(b, w, "Black should play longer than White on hole \(hole)")
            XCTAssertGreaterThan(w, r, "White should play longer than Red on hole \(hole)")
        }
    }

    func testTeeTotalsMatchThePrintedTotals() {
        XCTAssertEqual(template.teeSet(named: "Black")?.totalYardage, 3842)
        XCTAssertEqual(template.teeSet(named: "White")?.totalYardage, 3397)
        XCTAssertEqual(template.teeSet(named: "Red")?.totalYardage, 2834)

        XCTAssertEqual(template.teeSet(named: "Black")?.total(holes: 1...9), 2021)
        XCTAssertEqual(template.teeSet(named: "Black")?.total(holes: 10...18), 1821)
        XCTAssertEqual(template.teeSet(named: "White")?.total(holes: 1...9), 1811)
        XCTAssertEqual(template.teeSet(named: "White")?.total(holes: 10...18), 1586)
        XCTAssertEqual(template.teeSet(named: "Red")?.total(holes: 1...9), 1484)
        XCTAssertEqual(template.teeSet(named: "Red")?.total(holes: 10...18), 1350)
    }

    func testTemplateIsVerifiedAndMayRestoreStaticData() {
        XCTAssertEqual(template.verification, .verified)
        XCTAssertTrue(template.hasUsableHoleData)
        XCTAssertTrue(template.mayRestoreStaticData)
        XCTAssertEqual(template.identity.state, "GA")
        XCTAssertEqual(template.identity.city, "Sandy Springs")
    }
}
