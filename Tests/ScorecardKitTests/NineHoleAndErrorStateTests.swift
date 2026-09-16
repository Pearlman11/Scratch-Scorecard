import XCTest
@testable import ScorecardKit

/// Nine-hole support and the error states the product must handle without inventing data.
final class NineHoleAndErrorStateTests: XCTestCase {

    func testANineHoleCardParsesEndToEnd() async throws {
        let parsed = try await ParserTestSupport.parse(ParserTestSupport.nineHoleCard())

        XCTAssertEqual(parsed.holeCount, 9, "The architecture must not assume 18 holes")
        XCTAssertEqual(parsed.holes.count, 9)
        XCTAssertEqual(parsed.holes.map { $0.par.value ?? -1 }, [4, 3, 4, 3, 4, 4, 3, 4, 4])
        XCTAssertEqual(parsed.holes.map { $0.handicapIndex.value ?? -1 }, [3, 9, 1, 7, 5, 4, 8, 2, 6])
        XCTAssertEqual(parsed.holes.map(\.playerScore.value), [5, 3, 6, 4, 5, 4, 3, 5, 4])

        let totals = parsed.totals
        XCTAssertEqual(totals.front, 39)
        XCTAssertNil(totals.back)
        XCTAssertEqual(totals.total, 39)
        XCTAssertEqual(totals.relativeToPar, 6)
        XCTAssertTrue(parsed.warnings.contains { $0.kind == .nineHoleRoundDetected })
    }

    func testANineHoleCourseOutsideTheCatalogIsNotMatchedToAnythingPlausible() async throws {
        let parsed = try await ParserTestSupport.parse(ParserTestSupport.nineHoleCard())

        XCTAssertNil(parsed.candidateCourse, "An unknown course must not be silently matched")
        XCTAssertTrue(parsed.warnings.contains {
            $0.kind == .courseNotInCatalog || $0.kind == .courseNameUnreadable || $0.kind == .multipleCourseMatches
        })
        // The card's own printed data must still be usable even with no template behind it.
        XCTAssertEqual(parsed.holes.compactMap(\.par.value).count, 9)
        XCTAssertEqual(parsed.holes[0].par.provenance, .ocr)
    }

    func testTheGolferCanForceACourseAndTheTemplateThenApplies() async throws {
        // The course name is destroyed, so the golfer picks Steel Canyon by hand.
        var card = ScorecardFixtureBuilder.steelCanyonCard(scores: ParserTestSupport.steelCanyonScores)
        card.titleLines = []
        card.rows[3] = card.rows[3].corruptingHole(2, to: "?")

        let parsed = try await ParserTestSupport.parse(
            card,
            forcedTemplateID: "ga-steel-canyon",
            forcedTeeName: "Red"
        )

        XCTAssertEqual(parsed.candidateCourse?.id, "ga-steel-canyon")
        XCTAssertEqual(parsed.courseConfidence, 1.0, "The golfer's own choice is authoritative")
        XCTAssertEqual(parsed.candidateTee, "Red")
        XCTAssertEqual(parsed.teeConfidence, 1.0)
        XCTAssertEqual(parsed.holes.map { $0.yardage.value ?? -1 }, SteelCanyonTemplate.redYardages)
        XCTAssertEqual(parsed.hole(2)?.par.value, 4, "The damaged par cell is restored")
    }

    func testNoTextAtAllThrows() async {
        let parser = DefaultScorecardParser()
        let request = ScorecardParseRequest(observations: [], templates: ParserTestSupport.catalog)
        do {
            _ = try await parser.parse(request)
            XCTFail("An empty recognition must throw rather than return an empty card")
        } catch let error as ScorecardParsingError {
            guard case .noTextRecognized = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testTextWithNoScorecardGridFailsCleanly() async throws {
        let parser = DefaultScorecardParser()
        let observations = [
            TextObservation(text: "PRO SHOP RECEIPT", rect: CardRect(x: 0.1, y: 0.1, width: 0.4, height: 0.04), confidence: 0.9),
            TextObservation(text: "GREEN FEE", rect: CardRect(x: 0.1, y: 0.2, width: 0.3, height: 0.03), confidence: 0.9),
            TextObservation(text: "42.00", rect: CardRect(x: 0.6, y: 0.2, width: 0.2, height: 0.03), confidence: 0.9)
        ]
        let outcome = try await parser.parse(
            ScorecardParseRequest(observations: observations, templates: ParserTestSupport.catalog)
        )

        XCTAssertEqual(outcome.scorecard.quality, .failed)
        XCTAssertTrue(outcome.scorecard.hasBlockingWarning)
        XCTAssertTrue(outcome.scorecard.warnings.contains { $0.kind == .noScorecardTableDetected })
        XCTAssertTrue(outcome.scorecard.holes.isEmpty, "A failed parse must produce no holes, not empty ones")
    }

    func testACardWithNoPlayerRowIsReportedRatherThanInvented() async throws {
        var card = ScorecardFixtureBuilder.steelCanyonCard(scores: [Int?](repeating: nil, count: 18))
        card.rows.removeLast()

        let parsed = try await ParserTestSupport.parse(card)
        XCTAssertTrue(parsed.detectedPlayers.isEmpty)
        XCTAssertTrue(parsed.warnings.contains { $0.kind == .noPlayerRowsDetected })
        XCTAssertTrue(parsed.holes.allSatisfy { $0.playerScore.value == nil })
        // The static half of the card is still fully recovered and usable.
        XCTAssertEqual(parsed.candidateCourse?.id, "ga-steel-canyon")
        XCTAssertEqual(parsed.holes.map { $0.par.value ?? -1 }, SteelCanyonTemplate.pars)
    }

    func testACardPrintingSeveralTeesAsksWhichWasPlayed() async throws {
        // Steel Canyon's card prints Black, White and Red. Nothing on it records which was played.
        let card = ScorecardFixtureBuilder.steelCanyonCard(scores: ParserTestSupport.steelCanyonScores)
        let parsed = try await ParserTestSupport.parse(card)

        XCTAssertTrue(parsed.warnings.contains { $0.kind == .multipleTeeMatches })
        XCTAssertTrue(parsed.teeNeedsConfirmation)
        XCTAssertLessThan(parsed.teeConfidence, 0.6)
        XCTAssertNotNil(parsed.candidateTee, "A provisional default is still offered so the card is not blank")
    }

    func testACardPrintingOneTeeIdentifiesItConfidently() async throws {
        var card = ScorecardFixtureBuilder.steelCanyonCard(scores: ParserTestSupport.steelCanyonScores)
        // Keep only the White yardage row, plus par, HCP and the player.
        card.rows = [card.rows[1], card.rows[3], card.rows[4], card.rows[5]]

        let parsed = try await ParserTestSupport.parse(card)
        XCTAssertEqual(parsed.candidateTee, "White")
        XCTAssertGreaterThanOrEqual(parsed.teeConfidence, 0.8)
        XCTAssertFalse(parsed.teeNeedsConfirmation)
        XCTAssertEqual(parsed.holes.map { $0.yardage.value ?? -1 }, SteelCanyonTemplate.whiteYardages)
    }

    func testLowConfidenceScoresAreFlaggedForReview() async throws {
        var card = ScorecardFixtureBuilder.steelCanyonCard(scores: ParserTestSupport.steelCanyonScores)
        card.rows[5] = card.rows[5]
            .corruptingHole(3, to: "~")
            .corruptingHole(9, to: "&")

        let parsed = try await ParserTestSupport.parse(card)
        XCTAssertTrue(parsed.holesNeedingReview.contains(3))
        XCTAssertTrue(parsed.holesNeedingReview.contains(9))
        XCTAssertTrue(parsed.warnings.contains { $0.kind == .someScoresMissing })
    }

    func testHandwrittenScoresAreNeverFullyConfidentWithoutReview() async throws {
        let card = ScorecardFixtureBuilder.steelCanyonCard(scores: ParserTestSupport.steelCanyonScores)
        let parsed = try await ParserTestSupport.parse(card)

        for hole in parsed.holes {
            XCTAssertEqual(hole.playerScore.provenance, .ocr)
            XCTAssertLessThan(
                hole.playerScore.confidence, 1.0,
                "A handwritten score read by OCR is never certain, however plausible it looks"
            )
        }
        // Static data, by contrast, comes from the verified template and is certain.
        XCTAssertTrue(parsed.holes.allSatisfy { $0.par.provenance == .verifiedCourseTemplate })
    }

    func testDebugReportIsProducedOnRequestAndSkippedOtherwise() async throws {
        let card = ScorecardFixtureBuilder.steelCanyonCard(scores: ParserTestSupport.steelCanyonScores)

        let withoutReport = try await ParserTestSupport.outcome(card)
        XCTAssertNil(withoutReport.debugReport, "A normal scan must not pay for the inspector")

        let withReport = try await ParserTestSupport.outcome(card, collectsDebugReport: true)
        let report = try XCTUnwrap(withReport.debugReport)
        XCTAssertFalse(report.observations.isEmpty)
        XCTAssertFalse(report.rows.isEmpty)
        XCTAssertEqual(report.columns.filter { $0.label.hasPrefix("H") }.count, 18)
        XCTAssertEqual(report.appliedTemplateID, "ga-steel-canyon")
        XCTAssertTrue(report.courseCandidates.contains { $0.templateID == "ga-steel-canyon" })
        XCTAssertEqual(report.playerRowIndices.count, 1)
    }
}
