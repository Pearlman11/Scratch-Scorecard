import XCTest
@testable import ScorecardKit

/// The honesty tests.
///
/// Every case here checks that the parser declines to invent a score. A wrong score that looks plausible is
/// the single worst failure this app can have: the golfer scrolls past it on the review screen, saves, and
/// the round is quietly wrong forever. A blank cell, by contrast, is visible and costs one tap.
final class PlayerScoreExtractionTests: XCTestCase {

    func testAnIllegibleScoreIsLeftEmptyRatherThanGuessed() async throws {
        var card = ScorecardFixtureBuilder.steelCanyonCard(scores: ParserTestSupport.steelCanyonScores)
        card.rows[5] = card.rows[5].corruptingHole(4, to: "~")

        let parsed = try await ParserTestSupport.parse(card)
        let hole4 = try XCTUnwrap(parsed.hole(4))

        XCTAssertNil(hole4.playerScore.value, "An unreadable mark must not become a number")
        XCTAssertTrue(hole4.scoreNeedsReview)
        XCTAssertEqual(hole4.playerScore.rawText, "~", "The raw mark is kept so the golfer knows we saw something")
        // Par is a 3 here and the template supplies it — but that must not leak into the score.
        XCTAssertEqual(hole4.par.value, 3)
    }

    func testABlankHoleStaysBlank() async throws {
        var scores = ParserTestSupport.steelCanyonScores
        scores[6] = nil
        let card = ScorecardFixtureBuilder.steelCanyonCard(scores: scores)

        let parsed = try await ParserTestSupport.parse(card)
        XCTAssertNil(parsed.hole(7)?.playerScore.value)
        XCTAssertNil(parsed.hole(7)?.playerScore.rawText, "Nothing was written, so there is no raw text")
        XCTAssertEqual(parsed.hole(8)?.playerScore.value, 4, "A blank must not shift its neighbours")
    }

    func testAnImplausibleScoreIsRejectedNotClamped() async throws {
        var card = ScorecardFixtureBuilder.steelCanyonCard(scores: ParserTestSupport.steelCanyonScores)
        // Hole 11 is a par 4. "88" is not a golf score, and must not be clamped to 8 either.
        card.rows[5] = card.rows[5].corruptingHole(11, to: "88")

        let parsed = try await ParserTestSupport.parse(card)
        XCTAssertNil(parsed.hole(11)?.playerScore.value)
    }

    func testThePlausibleRangeRejectsButNeverSelects() {
        let extractor = PlayerScoreExtractor()
        // A 1 on a par 5 is a double eagle hole-in-one: far more often a misread than a fact.
        XCTAssertFalse(extractor.isPlausible(score: 1, par: 5))
        XCTAssertTrue(extractor.isPlausible(score: 1, par: 3))
        XCTAssertTrue(extractor.isPlausible(score: 12, par: 3))
        XCTAssertFalse(extractor.isPlausible(score: 20, par: 4))

        // An empty cell yields nothing, whatever par says. The range never fills a blank.
        let empty = TableCell(holeNumber: 5, observations: [], rect: CardRect(x: 0, y: 0, width: 0.04, height: 0.03))
        let field = extractor.readScore(cell: empty, columnIsInterpolated: false, par: 4)
        XCTAssertNil(field.value)
        XCTAssertEqual(field.provenance, .none)
    }

    func testATemplateNeverSuppliesAPlayerScore() async throws {
        // Every score cell is blank; the template is fully applied. Static data must fill, scores must not.
        let card = ScorecardFixtureBuilder.steelCanyonCard(scores: [Int?](repeating: nil, count: 18))
        let parsed = try await ParserTestSupport.parse(card)

        XCTAssertEqual(parsed.holes.map { $0.par.value ?? -1 }, SteelCanyonTemplate.pars)
        for hole in parsed.holes {
            XCTAssertNil(hole.playerScore.value, "Hole \(hole.holeNumber) invented a score")
            XCTAssertTrue(
                hole.playerScore.provenance.isPermittedForPlayerScore,
                "Hole \(hole.holeNumber) has a provenance that must never reach a score"
            )
        }
    }

    func testProvenanceRulesForbidTemplateAndLayoutOnScores() {
        XCTAssertFalse(FieldProvenance.verifiedCourseTemplate.isPermittedForPlayerScore)
        XCTAssertFalse(FieldProvenance.inferredFromLayout.isPermittedForPlayerScore)
        XCTAssertTrue(FieldProvenance.ocr.isPermittedForPlayerScore)
        XCTAssertTrue(FieldProvenance.userEdited.isPermittedForPlayerScore)
        XCTAssertTrue(FieldProvenance.multimodalFallback.isPermittedForPlayerScore)
    }

    func testMultiplePlayersAreDetectedSeparately() async throws {
        var card = ScorecardFixtureBuilder.steelCanyonCard(scores: ParserTestSupport.steelCanyonScores)
        card.rows.append(ScorecardFixtureBuilder.Row.handwritten(
            label: "MIKE",
            values: [6, 5, 4, 3, 4, 7, 4, 3, 4, 3, 6, 4, 3, 5, 6, 5, 4, 3]
        ))
        card.rows.append(ScorecardFixtureBuilder.Row.handwritten(
            label: "DANA",
            values: [4, 4, 3, 3, 3, 5, 3, 4, 3, 4, 4, 3, 3, 3, 5, 5, 3, 3]
        ))

        let parsed = try await ParserTestSupport.parse(card)
        XCTAssertEqual(parsed.detectedPlayers.count, 3)
        XCTAssertEqual(parsed.detectedPlayers.map(\.displayName), ["J. PEARLMAN", "MIKE", "DANA"])
        XCTAssertNil(parsed.selectedPlayerID, "With several golfers the app must not choose one")
        XCTAssertTrue(parsed.holes.allSatisfy { $0.playerScore.value == nil })
    }

    func testSelectingAPlayerAdoptsThatRowsScores() async throws {
        var card = ScorecardFixtureBuilder.steelCanyonCard(scores: ParserTestSupport.steelCanyonScores)
        let mikeScores = [6, 5, 4, 3, 4, 7, 4, 3, 4, 3, 6, 4, 3, 5, 6, 5, 4, 3]
        card.rows.append(ScorecardFixtureBuilder.Row.handwritten(label: "MIKE", values: mikeScores.map { Optional($0) }))

        var parsed = try await ParserTestSupport.parse(card)
        let mike = try XCTUnwrap(parsed.detectedPlayers.first { $0.displayName == "MIKE" })
        parsed.selectPlayer(id: mike.id)

        XCTAssertEqual(parsed.holes.map(\.playerScore.value), mikeScores.map { Optional($0) })
        XCTAssertEqual(parsed.totals.total, mikeScores.reduce(0, +))
    }

    func testAnUnnamedPlayerRowGetsAFallbackLabel() async throws {
        var card = ScorecardFixtureBuilder.steelCanyonCard(
            scores: ParserTestSupport.steelCanyonScores,
            playerName: nil
        )
        card.rows.append(ScorecardFixtureBuilder.Row.handwritten(
            label: nil,
            values: [6, 5, 4, 3, 4, 7, 4, 3, 4, 3, 6, 4, 3, 5, 6, 5, 4, 3]
        ))

        let parsed = try await ParserTestSupport.parse(card)
        XCTAssertEqual(parsed.detectedPlayers.count, 2)
        XCTAssertEqual(parsed.detectedPlayers.map(\.displayName), ["Player 1", "Player 2"])
    }

    func testAnIncompleteRoundIsReportedAsIncompleteNotFilledIn() async throws {
        var scores = ParserTestSupport.steelCanyonScores
        for index in 14..<18 { scores[index] = nil }
        let card = ScorecardFixtureBuilder.steelCanyonCard(scores: scores)

        let parsed = try await ParserTestSupport.parse(card)
        XCTAssertEqual(parsed.holes.compactMap(\.playerScore.value).count, 14)
        for holeNumber in 15...18 {
            XCTAssertNil(parsed.hole(holeNumber)?.playerScore.value)
        }
        XCTAssertNil(parsed.totals.total, "An incomplete round has no total")
        XCTAssertNotNil(parsed.totals.front, "The front nine is complete, so it does have a total")
        XCTAssertNil(parsed.totals.back)
        XCTAssertEqual(parsed.totals.holesWithScores, 14)
        XCTAssertTrue(parsed.warnings.contains { $0.kind == .incompleteRound })
    }

    func testARowOfStrayMarksIsNotTreatedAsAGolfer() async throws {
        var card = ScorecardFixtureBuilder.steelCanyonCard(scores: ParserTestSupport.steelCanyonScores)
        // One stray digit in an otherwise empty row: below the minimum to count as a golfer.
        var stray = [Int?](repeating: nil, count: 18)
        stray[3] = 4
        card.rows.append(ScorecardFixtureBuilder.Row.handwritten(label: nil, values: stray))

        let parsed = try await ParserTestSupport.parse(card)
        XCTAssertEqual(parsed.detectedPlayers.count, 1)
    }
}
