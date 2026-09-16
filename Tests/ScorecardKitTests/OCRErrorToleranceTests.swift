import XCTest
@testable import ScorecardKit

/// The tests the product was specified around: OCR gets several printed values wrong, and the combined
/// evidence must still identify Steel Canyon and restore the correct static data.
///
/// Every case here damages the *fixture*, not the expectation — the parser is given a card that is wrong in
/// specific, realistic ways and is asked to recover the right answer.
final class OCRErrorToleranceTests: XCTestCase {

    /// A Steel Canyon card damaged the way a real photograph is: a mangled course name in the logo, a
    /// three-digit yardage with a letter in it, a dropped cell, a `1` read as an `l`, and a `5` read as `S`.
    private func damagedSteelCanyonCard() -> ScorecardFixtureBuilder.Card {
        var card = ScorecardFixtureBuilder.steelCanyonCard(scores: ParserTestSupport.steelCanyonScores)
        card.titleLines = ["STEE CANYQN GOLE CLUB", "SANDY SPRINGS, GEORGIA"]
        // Row 0 Black, 1 White, 2 Red, 3 Par, 4 HCP, 5 player.
        card.rows[1] = card.rows[1].corruptingHole(16, to: "33B")   // White hole 16: 333 -> 33B
        card.rows[0] = card.rows[0].droppingHole(12)                // Black hole 12: never recognised
        card.rows[4] = card.rows[4].corruptingHole(5, to: "l7")     // HCP hole 5: 17 -> l7
        card.rows[3] = card.rows[3].corruptingHole(6, to: "S")      // Par hole 6: 5 -> S
        card.rows[2] = card.rows[2].corruptingHole(3, to: "9A")     // Red hole 3: 94 -> 9A
        return card
    }

    func testSeveralOCRMistakesStillIdentifySteelCanyon() async throws {
        let parsed = try await ParserTestSupport.parse(damagedSteelCanyonCard())

        XCTAssertEqual(parsed.candidateCourse?.id, "ga-steel-canyon")
        XCTAssertGreaterThanOrEqual(parsed.courseConfidence, 0.72)
        XCTAssertEqual(parsed.appliedTemplateID, "ga-steel-canyon")
        XCTAssertTrue(parsed.alternateCourseIDs.isEmpty, "A clear winner must not be reported as ambiguous")
    }

    func testTemplateRestoresTheCorruptedStaticValues() async throws {
        let parsed = try await ParserTestSupport.parse(
            damagedSteelCanyonCard(),
            forcedTeeName: "White"
        )

        // The headline case: "33B" becomes 333 because the template knows hole 16 from the White tees.
        let hole16 = try XCTUnwrap(parsed.hole(16))
        XCTAssertEqual(hole16.yardage.value, 333)
        XCTAssertEqual(hole16.yardage.provenance, .verifiedCourseTemplate)

        // A par cell read as "S" is restored.
        let hole6 = try XCTUnwrap(parsed.hole(6))
        XCTAssertEqual(hole6.par.value, 5)
        XCTAssertEqual(hole6.par.provenance, .verifiedCourseTemplate)

        // A stroke index read as "l7" is restored.
        let hole5 = try XCTUnwrap(parsed.hole(5))
        XCTAssertEqual(hole5.handicapIndex.value, 17)

        // Every static field is complete and correct after repair.
        XCTAssertEqual(parsed.holes.map { $0.par.value ?? -1 }, SteelCanyonTemplate.pars)
        XCTAssertEqual(parsed.holes.map { $0.handicapIndex.value ?? -1 }, SteelCanyonTemplate.handicapIndices)
        XCTAssertEqual(parsed.holes.map { $0.yardage.value ?? -1 }, SteelCanyonTemplate.whiteYardages)
    }

    func testAnUnreadableCourseNameStillIdentifiesTheCourse() async throws {
        // The name contributes nothing at all: the par and stroke-index sequences carry the identification.
        var card = ScorecardFixtureBuilder.steelCanyonCard(scores: ParserTestSupport.steelCanyonScores)
        card.titleLines = ["XQZW MNBVC PLKJH"]

        let parsed = try await ParserTestSupport.parse(card)
        XCTAssertEqual(parsed.candidateCourse?.id, "ga-steel-canyon")
        XCTAssertGreaterThanOrEqual(parsed.courseConfidence, 0.72)
    }

    func testACardWithNoHeadingAtAllStillIdentifiesTheCourse() async throws {
        var card = ScorecardFixtureBuilder.steelCanyonCard(scores: ParserTestSupport.steelCanyonScores)
        card.titleLines = []

        let parsed = try await ParserTestSupport.parse(card)
        XCTAssertEqual(parsed.candidateCourse?.id, "ga-steel-canyon")
    }

    func testAMissingHoleNumberInTheHeaderIsInterpolated() async throws {
        // Hole 7's header cell is never recognised. The column must still exist, positioned between its
        // neighbours, so hole 7's score is not silently dropped or shifted onto hole 8.
        var card = ScorecardFixtureBuilder.steelCanyonCard(scores: ParserTestSupport.steelCanyonScores)
        card.headerCells = [7: ""]

        let parsed = try await ParserTestSupport.parse(card)
        XCTAssertEqual(parsed.holeCount, 18)
        XCTAssertEqual(parsed.hole(7)?.playerScore.value, 3)
        XCTAssertEqual(parsed.hole(8)?.playerScore.value, 4)
    }

    func testSkewedPhotographStillParses() async throws {
        for degrees in [-7.0, -3.0, 2.5, 6.0] {
            let card = ScorecardFixtureBuilder.steelCanyonCard(
                scores: ParserTestSupport.steelCanyonScores,
                skewDegrees: degrees
            )
            let parsed = try await ParserTestSupport.parse(card)
            XCTAssertEqual(parsed.candidateCourse?.id, "ga-steel-canyon", "failed at \(degrees)°")
            XCTAssertEqual(parsed.holeCount, 18, "failed at \(degrees)°")
            XCTAssertEqual(
                parsed.holes.compactMap(\.playerScore.value).count, 18,
                "all scores should survive \(degrees)° of skew"
            )
        }
    }

    func testFrontAndBackNineInSeparateTablesParseAsOneCard() async throws {
        let card = ScorecardFixtureBuilder.steelCanyonCard(
            scores: ParserTestSupport.steelCanyonScores,
            layout: .stackedNines
        )
        let parsed = try await ParserTestSupport.parse(card)

        XCTAssertEqual(parsed.holeCount, 18)
        XCTAssertEqual(parsed.candidateCourse?.id, "ga-steel-canyon")
        XCTAssertEqual(parsed.holes.map { $0.par.value ?? -1 }, SteelCanyonTemplate.pars)
        XCTAssertEqual(
            parsed.holes.map(\.playerScore.value),
            ParserTestSupport.steelCanyonScores,
            "A player's row split across two tables must be rejoined into one set of scores"
        )
    }
}
