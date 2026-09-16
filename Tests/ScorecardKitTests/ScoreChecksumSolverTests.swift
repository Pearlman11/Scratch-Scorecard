import XCTest
@testable import ScorecardKit

/// Tests built from a photograph of a real, marked-up Steel Canyon card.
///
/// The card carries two golfers, "C" and "J", and the cells that defeat OCR on it are exactly the ones a
/// golfer marks up: C's hole 6 is a boxed 6 on the par 5, C's hole 18 is written over an earlier number,
/// and J's hole 13 is likewise corrected. Every one of those is recoverable from the subtotals the golfers
/// wrote, which is what these tests pin down.
final class ScoreChecksumSolverTests: XCTestCase {

    private let solver = ScoreChecksumSolver()

    /// Builds holes as they look after a successful parse of the real card: every static field supplied by
    /// the matched template, and the given scores read by OCR. A `nil` score stands for a cell OCR could
    /// not read.
    ///
    /// Populating all three static fields matters for the confidence test below — leaving handicap and
    /// yardage empty would halve the static-completeness term and measure a card the parser never produces.
    private func holes(scores: [Int?], confidence: Double = 0.60) -> [ParsedHole] {
        (1...18).map { number in
            var hole = ParsedHole(holeNumber: number)
            hole.par = .template(SteelCanyonTemplate.pars[number - 1])
            hole.handicapIndex = .template(SteelCanyonTemplate.handicapIndices[number - 1])
            hole.yardage = .template(SteelCanyonTemplate.whiteYardages[number - 1])
            if let value = scores[number - 1] {
                hole.playerScore = .ocr(value, confidence: confidence)
            }
            return hole
        }
    }

    private func field(_ value: Int) -> ParsedField<Int> { .ocr(value, confidence: 0.8) }

    // C's card: hole 6 (boxed) and hole 18 (written over) unreadable. Written 35 / 33 / 68.
    private var playerCScores: [Int?] {
        [4, 4, 3, 4, 3, nil, 3, 4, 4, 4, 3, 3, 3, 4, 4, 4, 4, nil]
    }

    // J's card: hole 13 (written over) unreadable. Written 40 / 37 / 77.
    private var playerJScores: [Int?] {
        [6, 4, 3, 5, 3, 8, 5, 3, 3, 4, 5, 4, nil, 4, 4, 6, 4, 3]
    }

    func testSolvesBothUnreadableCellsOnTheRealCard() {
        let result = solver.solve(
            holes: holes(scores: playerCScores),
            writtenOut: field(35),
            writtenIn: field(33),
            writtenTotal: field(68),
            holeCount: 18
        )

        XCTAssertEqual(result.solvedHoles, [6, 18])

        // Hole 6 is a par 5 that C boxed, meaning a bogey. The arithmetic says 6, and a 6 on a par 5 is
        // exactly the bogey the box denotes — two independent signals agreeing.
        XCTAssertEqual(result.holes[5].playerScore.value, 6)
        XCTAssertEqual(result.holes[5].playerScore.provenance, .solvedFromSubtotal)
        XCTAssertEqual(result.holes[17].playerScore.value, 4)

        let scores = result.holes.map(\.playerScore.value)
        let totals = ScoreMath.totals(scores: scores, pars: SteelCanyonTemplate.pars.map { Optional($0) }, holeCount: 18)
        XCTAssertEqual(totals.front, 35, "must reproduce the OUT the golfer wrote")
        XCTAssertEqual(totals.back, 33, "must reproduce the IN the golfer wrote")
        XCTAssertEqual(totals.total, 68)
        XCTAssertEqual(totals.relativeToPar, 7, "68 against Steel Canyon's par 61")
    }

    func testAFullyReadableNineIsVerifiedRatherThanChanged() {
        let result = solver.solve(
            holes: holes(scores: playerJScores),
            writtenOut: field(40),
            writtenIn: field(37),
            writtenTotal: field(77),
            holeCount: 18
        )

        XCTAssertEqual(result.front, .verified(subtotal: 40), "J's front nine reads completely and sums to 40")
        XCTAssertEqual(result.back, .solved(hole: 13, strokes: 3))
        XCTAssertEqual(result.solvedHoles, [13])
        // Nothing on the verified nine may be touched.
        XCTAssertEqual(Array(result.holes.prefix(9)).map(\.playerScore.value), [6, 4, 3, 5, 3, 8, 5, 3, 3])
    }

    func testAVerifiedCardRaisesConfidenceWellAboveTheRawHandwritingRead() {
        let evaluator = ParsingConfidenceEvaluator()
        let solved = solver.solve(
            holes: holes(scores: playerCScores),
            writtenOut: field(35),
            writtenIn: field(33),
            writtenTotal: field(68),
            holeCount: 18
        )
        XCTAssertEqual(solved.checksumSupport, .confirmed(halves: 2))

        func confidence(support: ParsingConfidenceEvaluator.ChecksumSupport) -> Double {
            evaluator.evaluate(
                holes: solved.holes,
                holeCount: 18,
                players: [DetectedPlayer(fallbackLabel: "C", scores: [], rowConfidence: 0.6)],
                courseConfidence: 1.0,
                courseResolved: true,
                checksumSupport: support,
                existingWarnings: []
            ).overallConfidence
        }

        // Raw handwriting confidence sits near 0.6 even on a perfect read, which is what caps an otherwise
        // flawless scan at a misleadingly mediocre score. Arithmetic confirmation is the better evidence.
        let unconfirmed = confidence(support: .unavailable)
        let confirmed = confidence(support: .confirmed(halves: 2))
        XCTAssertGreaterThan(confirmed, 0.9, "a card that adds up should read as high confidence")
        XCTAssertGreaterThan(confirmed - unconfirmed, 0.10, "confirmation must move the number meaningfully")

        // And a card that does *not* add up must score below one that was never checked at all.
        XCTAssertLessThan(confidence(support: .contradicted), unconfirmed)
    }

    // MARK: - Refusals

    func testTwoUnknownsInOneNineAreLeftAloneRatherThanSplit() {
        var scores = playerCScores
        scores[2] = nil  // a second unknown on the front nine alongside hole 6
        let result = solver.solve(
            holes: holes(scores: scores),
            writtenOut: field(35),
            writtenIn: field(33),
            writtenTotal: field(68),
            holeCount: 18
        )

        XCTAssertEqual(result.front, .underdetermined(unknownHoles: [3, 6]))
        XCTAssertNil(result.holes[2].playerScore.value, "a residual with many splits must not be guessed")
        XCTAssertNil(result.holes[5].playerScore.value)
        XCTAssertFalse(result.solvedHoles.contains(3))
        XCTAssertTrue(result.warnings.contains { $0.kind == .someScoresMissing })
        // The back nine still had one unknown, so it is still solved. One bad nine does not poison the other.
        XCTAssertEqual(result.holes[17].playerScore.value, 4)
    }

    func testAnImpossibleImpliedScoreIsReportedNotWritten() {
        // A misread subtotal (35 read as 85) implies 56 strokes on hole 6. The arithmetic is sound, so an
        // impossible answer means an *input* was wrong — almost always the subtotal, not the cell.
        let result = solver.solve(
            holes: holes(scores: playerCScores),
            writtenOut: field(85),
            writtenIn: field(33),
            writtenTotal: .empty,
            holeCount: 18
        )

        XCTAssertEqual(result.front, .implausibleSolution(hole: 6, implied: 56))
        XCTAssertNil(result.holes[5].playerScore.value)
        XCTAssertEqual(result.checksumSupport, .contradicted)
        XCTAssertTrue(result.warnings.contains { $0.severity == .warning })
    }

    func testAMismatchedNineIsFlaggedNotSilentlyAccepted() {
        var scores = playerJScores
        scores[12] = 3  // complete the nine, then contradict the written subtotal
        let result = solver.solve(
            holes: holes(scores: scores),
            writtenOut: field(40),
            writtenIn: field(31),   // the card actually says 37
            writtenTotal: .empty,
            holeCount: 18
        )

        XCTAssertEqual(result.back, .discrepancy(sum: 37, subtotal: 31))
        XCTAssertEqual(result.checksumSupport, .contradicted)
        XCTAssertTrue(result.warnings.contains { $0.detail.contains("37") && $0.detail.contains("31") })
    }

    func testTheGolfersOwnEditIsNeverOverwritten() {
        var input = holes(scores: playerCScores)
        input[5].playerScore = .userEdited(7)   // they typed 7; the subtotal implies 6

        let result = solver.solve(
            holes: input,
            writtenOut: field(35),
            writtenIn: field(33),
            writtenTotal: field(68),
            holeCount: 18
        )

        XCTAssertEqual(result.holes[5].playerScore.value, 7)
        XCTAssertEqual(result.holes[5].playerScore.provenance, .userEdited)
        // With hole 6 now counted as known, the nine no longer adds up — which is correctly reported
        // rather than resolved by overruling the golfer.
        XCTAssertEqual(result.front, .discrepancy(sum: 36, subtotal: 35))
    }

    func testALowConfidenceReadIsOverwrittenByTheArithmetic() {
        // A boxed digit often produces a confident-*looking* wrong read rather than a blank. Where the
        // subtotal disagrees with a shaky read, the arithmetic is the better source.
        var input = holes(scores: playerCScores)
        input[5].playerScore = .ocr(4, confidence: 0.30)   // hole 6 misread as 4

        let result = solver.solve(
            holes: input,
            writtenOut: field(35),
            writtenIn: field(33),
            writtenTotal: field(68),
            holeCount: 18
        )

        XCTAssertEqual(result.holes[5].playerScore.value, 6, "the subtotal corrects a weak read")
        XCTAssertEqual(result.holes[5].playerScore.provenance, .solvedFromSubtotal)
    }

    func testAConfidentReadIsNotOverwritten() {
        var input = holes(scores: playerCScores)
        input[5].playerScore = .ocr(4, confidence: 0.95)   // read clearly, but contradicts the subtotal

        let result = solver.solve(
            holes: input,
            writtenOut: field(35),
            writtenIn: field(33),
            writtenTotal: field(68),
            holeCount: 18
        )

        XCTAssertEqual(result.holes[5].playerScore.value, 4)
        XCTAssertEqual(result.front, .discrepancy(sum: 33, subtotal: 35), "reported for the golfer to settle")
    }

    // MARK: - Subtotal recovery

    func testAMissingNineTotalIsRecoveredFromTheGrandTotal() {
        // The IN cell is blank, but OUT and TOT are both written, which determines it.
        let result = solver.solve(
            holes: holes(scores: playerCScores),
            writtenOut: field(35),
            writtenIn: .empty,
            writtenTotal: field(68),
            holeCount: 18
        )

        XCTAssertEqual(result.back, .solved(hole: 18, strokes: 4), "IN = 68 - 35 = 33 settles hole 18")
        XCTAssertEqual(result.solvedHoles, [6, 18])
    }

    func testNoSubtotalsMeansNothingIsInventedOrClaimed() {
        let result = solver.solve(
            holes: holes(scores: playerCScores),
            writtenOut: .empty,
            writtenIn: .empty,
            writtenTotal: .empty,
            holeCount: 18
        )

        XCTAssertEqual(result.front, .noSubtotal)
        XCTAssertEqual(result.back, .noSubtotal)
        XCTAssertTrue(result.solvedHoles.isEmpty)
        XCTAssertEqual(result.checksumSupport, .unavailable)
        XCTAssertNil(result.holes[5].playerScore.value)
    }

    func testNineHoleCardUsesItsTotalAsTheFrontSubtotal() {
        let nine: [Int?] = [5, 3, nil, 4, 5, 4, 3, 5, 4]
        let holes = (1...9).map { number -> ParsedHole in
            var hole = ParsedHole(holeNumber: number)
            if let value = nine[number - 1] { hole.playerScore = .ocr(value, confidence: 0.6) }
            return hole
        }

        // On a nine-hole card OUT and TOTAL are the same figure, so a card that only filled TOT still checks.
        let result = solver.solve(
            holes: holes,
            writtenOut: .empty,
            writtenIn: .empty,
            writtenTotal: field(39),
            holeCount: 9
        )

        XCTAssertEqual(result.front, .solved(hole: 3, strokes: 6))
        XCTAssertEqual(result.back, .noSubtotal, "a nine-hole card has no back nine to check")
    }

    func testASolvedScoreIsAllowedToBeAPlayerScore() {
        // The rule that a template may never supply a score must not accidentally block arithmetic derived
        // from the golfer's own handwriting.
        XCTAssertTrue(FieldProvenance.solvedFromSubtotal.isPermittedForPlayerScore)
        XCTAssertFalse(FieldProvenance.verifiedCourseTemplate.isPermittedForPlayerScore)
    }
}
