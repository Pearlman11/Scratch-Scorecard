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

    /// Every subtotal printed on the physical card, checked against the transcribed arrays.
    ///
    /// This is the test that catches a transcription error, and it has already earned its keep: four
    /// yardages were originally entered wrong (Black 14, White 14, Red 3, Red 11) and the printed subtotals
    /// are what proved which version was right. A card's OUT, IN and TOT are an independent check on the
    /// nine numbers above them, so if the per-hole arrays and these totals ever disagree again, one of them
    /// was typed wrong.
    func testTeeTotalsMatchThePrintedTotals() {
        // (tee, printed OUT, printed IN, printed TOT) exactly as they appear on the card.
        let printed: [(name: String, out: Int, inward: Int, total: Int)] = [
            ("Black", 2021, 1778, 3799),
            ("White", 1811, 1564, 3375),
            ("Red", 1457, 1245, 2702)
        ]

        for tee in printed {
            guard let set = template.teeSet(named: tee.name) else {
                return XCTFail("Steel Canyon must define a \(tee.name) tee")
            }
            XCTAssertEqual(set.total(holes: 1...9), tee.out, "\(tee.name) OUT")
            XCTAssertEqual(set.total(holes: 10...18), tee.inward, "\(tee.name) IN")
            XCTAssertEqual(set.totalYardage, tee.total, "\(tee.name) TOTAL")
            // The card is self-checking, so the transcription must be too.
            XCTAssertEqual(tee.out + tee.inward, tee.total, "\(tee.name): printed OUT + IN must equal TOT")
        }
    }

    /// Spot-checks the four holes that were transcribed incorrectly the first time.
    ///
    /// Named explicitly so a future regression points straight at the cause rather than at a totals
    /// mismatch several steps removed from it.
    func testThePreviouslyMistranscribedHolesMatchTheCard() {
        XCTAssertEqual(template.teeSet(named: "Black")?.yardage(forHole: 14), 170, "was 213")
        XCTAssertEqual(template.teeSet(named: "White")?.yardage(forHole: 14), 148, "was 170")
        XCTAssertEqual(template.teeSet(named: "Red")?.yardage(forHole: 3), 67, "was 94")
        XCTAssertEqual(template.teeSet(named: "Red")?.yardage(forHole: 11), 122, "was 227")
    }

    func testTemplateIsVerifiedAndMayRestoreStaticData() {
        XCTAssertEqual(template.verification, .verified)
        XCTAssertTrue(template.hasUsableHoleData)
        XCTAssertTrue(template.mayRestoreStaticData)
        XCTAssertEqual(template.identity.state, "GA")
        XCTAssertEqual(template.identity.city, "Sandy Springs")
    }
}
