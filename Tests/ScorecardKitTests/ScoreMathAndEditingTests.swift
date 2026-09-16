import XCTest
@testable import ScorecardKit

final class ScoreMathAndEditingTests: XCTestCase {

    private let steelCanyonPars: [Int?] = SteelCanyonTemplate.pars.map { Optional($0) }

    func testTotalsForACompleteEighteenHoleRound() {
        let scores = ParserTestSupport.steelCanyonScores
        let totals = ScoreMath.totals(scores: scores, pars: steelCanyonPars, holeCount: 18)

        XCTAssertEqual(totals.front, 35)
        XCTAssertEqual(totals.back, 35)
        XCTAssertEqual(totals.total, 70)
        XCTAssertEqual(totals.relativeToPar, 9, "70 against Steel Canyon's par 61")
        XCTAssertEqual(totals.holesWithScores, 18)
        XCTAssertTrue(totals.isComplete)
    }

    func testTotalsForAnIncompleteRoundReportNilRatherThanAPartialSum() {
        var scores = ParserTestSupport.steelCanyonScores
        for index in 14..<18 { scores[index] = nil }
        let totals = ScoreMath.totals(scores: scores, pars: steelCanyonPars, holeCount: 18)

        XCTAssertEqual(totals.front, 35, "The front nine is complete")
        XCTAssertNil(totals.back, "The back nine is not, so it has no total")
        XCTAssertNil(totals.total)
        XCTAssertFalse(totals.isComplete)
        XCTAssertEqual(totals.holesWithScores, 14)
        XCTAssertEqual(totals.partialTotal, scores.compactMap { $0 }.reduce(0, +))
        // A partial round can still show a meaningful figure against the holes actually played.
        XCTAssertNotNil(totals.relativeToParForHolesPlayed)
    }

    func testNineHoleTotals() {
        let scores: [Int?] = [5, 3, 6, 4, 5, 4, 3, 5, 4]
        let pars: [Int?] = [4, 3, 4, 3, 4, 4, 3, 4, 4]
        let totals = ScoreMath.totals(scores: scores, pars: pars, holeCount: 9)

        XCTAssertEqual(totals.front, 39)
        XCTAssertNil(totals.back, "A nine-hole card has no back nine")
        XCTAssertEqual(totals.total, 39)
        XCTAssertEqual(totals.relativeToPar, 6)
    }

    func testRelativeToParFormatting() {
        XCTAssertEqual(ScoreMath.formatRelativeToPar(0), "E")
        XCTAssertEqual(ScoreMath.formatRelativeToPar(4), "+4")
        XCTAssertEqual(ScoreMath.formatRelativeToPar(-2), "-2")
        XCTAssertEqual(ScoreMath.formatRelativeToPar(nil), "—")
    }

    func testEditingAScoreRecalculatesEveryTotal() async throws {
        let card = ScorecardFixtureBuilder.steelCanyonCard(scores: ParserTestSupport.steelCanyonScores)
        var parsed = try await ParserTestSupport.parse(card)

        XCTAssertEqual(parsed.totals.total, 70)
        XCTAssertEqual(parsed.totals.front, 35)

        parsed.setScore(9, forHole: 1)   // was a 5

        XCTAssertEqual(parsed.hole(1)?.playerScore.value, 9)
        XCTAssertEqual(parsed.totals.front, 39)
        XCTAssertEqual(parsed.totals.back, 35)
        XCTAssertEqual(parsed.totals.total, 74)
        XCTAssertEqual(parsed.totals.relativeToPar, 13)
    }

    func testAnEditedScoreIsMarkedAsTheGolfersOwnAndLeavesReview() async throws {
        var card = ScorecardFixtureBuilder.steelCanyonCard(scores: ParserTestSupport.steelCanyonScores)
        card.rows[5] = card.rows[5].corruptingHole(4, to: "~")
        var parsed = try await ParserTestSupport.parse(card)

        XCTAssertTrue(parsed.hole(4)?.scoreNeedsReview ?? false)
        XCTAssertTrue(parsed.holesNeedingReview.contains(4))

        parsed.setScore(4, forHole: 4)

        let hole = try XCTUnwrap(parsed.hole(4))
        XCTAssertEqual(hole.playerScore.value, 4)
        XCTAssertEqual(hole.playerScore.provenance, .userEdited)
        XCTAssertEqual(hole.playerScore.confidence, 1.0)
        XCTAssertFalse(hole.scoreNeedsReview)
        XCTAssertFalse(parsed.holesNeedingReview.contains(4))
    }

    func testClearingAScoreIsAllowedAndReopensReview() async throws {
        let card = ScorecardFixtureBuilder.steelCanyonCard(scores: ParserTestSupport.steelCanyonScores)
        var parsed = try await ParserTestSupport.parse(card)

        parsed.setScore(nil, forHole: 12)
        XCTAssertNil(parsed.hole(12)?.playerScore.value)
        XCTAssertNil(parsed.totals.total, "Clearing a hole makes the round incomplete again")
        XCTAssertEqual(parsed.totals.holesWithScores, 17)
    }

    func testATemplateNeverOverwritesAnEditedStaticValue() {
        let parser = DefaultScorecardParser()
        var hole = ParsedHole(holeNumber: 16)
        hole.yardage = .userEdited(340)
        hole.par = .ocr(3, confidence: 0.4)

        let result = parser.applyTemplate(SteelCanyonTemplate.template, teeName: "White", to: [hole])

        XCTAssertEqual(result.holes[0].yardage.value, 340, "The golfer's own correction must survive")
        XCTAssertEqual(result.holes[0].yardage.provenance, .userEdited)
        XCTAssertEqual(result.holes[0].par.value, 4, "A low-confidence OCR par is replaced")
        XCTAssertEqual(result.holes[0].par.provenance, .verifiedCourseTemplate)
    }

    func testRelativeToParPerHole() async throws {
        let card = ScorecardFixtureBuilder.steelCanyonCard(scores: ParserTestSupport.steelCanyonScores)
        let parsed = try await ParserTestSupport.parse(card)

        XCTAssertEqual(parsed.hole(1)?.relativeToPar, 1, "5 on a par 4")
        XCTAssertEqual(parsed.hole(3)?.relativeToPar, 0, "3 on a par 3")
        XCTAssertEqual(parsed.hole(6)?.relativeToPar, 1, "6 on a par 5")
    }

    func testConfidenceLevelBucketing() {
        XCTAssertEqual(ConfidenceLevel(score: 0.95), .high)
        XCTAssertEqual(ConfidenceLevel(score: 0.7), .medium)
        XCTAssertEqual(ConfidenceLevel(score: 0.4), .low)
        XCTAssertEqual(ConfidenceLevel(score: 0.0), .none)
        XCTAssertLessThan(ConfidenceLevel.low, ConfidenceLevel.high)

        let empty = ParsedField<Int>.empty
        XCTAssertEqual(empty.level, .none)
        XCTAssertTrue(empty.requiresReview)

        let edited = ParsedField<Int>.userEdited(4)
        XCTAssertEqual(edited.level, .high)
        XCTAssertFalse(edited.requiresReview)
    }
}
