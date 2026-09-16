import XCTest
@testable import ScorecardKit

/// Growing the catalog from confirmed scans, and the optional remote parser.
final class LearnedTemplateAndRemoteTests: XCTestCase {

    /// A confirmed parse of a course that ships with identity only.
    private func confirmedWolfCreekParse() -> ParsedScorecard {
        let pars = [4, 3, 5, 4, 3, 4, 5, 3, 4, 4, 3, 4, 5, 3, 4, 4, 3, 4]
        let handicaps = [5, 15, 1, 7, 17, 9, 3, 13, 11, 6, 16, 8, 2, 18, 4, 10, 14, 12]
        let yards = [380, 165, 510, 410, 175, 395, 530, 150, 420, 400, 180, 365, 520, 155, 405, 340, 190, 430]

        let holes = (1...18).map { number -> ParsedHole in
            var hole = ParsedHole(holeNumber: number)
            hole.par = .ocr(pars[number - 1], confidence: 0.94)
            hole.handicapIndex = .ocr(handicaps[number - 1], confidence: 0.93)
            hole.yardage = .ocr(yards[number - 1], confidence: 0.92)
            hole.playerScore = .ocr(5, confidence: 0.6)
            return hole
        }

        var parsed = ParsedScorecard(
            candidateCourse: GeorgiaCourseCatalog.template(withID: "ga-wolf-creek")?.identity,
            candidateTee: "Blue",
            teeConfidence: 0.9,
            courseConfidence: 0.95,
            holeCount: 18,
            holes: holes
        )
        parsed.appliedTemplateID = "ga-wolf-creek"
        return parsed
    }

    func testAConfirmedScanBecomesAReusableTemplate() throws {
        let parsed = confirmedWolfCreekParse()
        XCTAssertTrue(LearnedTemplateBuilder.canBuildTemplate(from: parsed))

        let existing = GeorgiaCourseCatalog.template(withID: "ga-wolf-creek")
        let learned = try LearnedTemplateBuilder.build(from: parsed, improving: existing)

        XCTAssertEqual(learned.identity.id, "ga-wolf-creek")
        XCTAssertEqual(learned.holeCount, 18)
        XCTAssertEqual(learned.pars.map { $0 ?? -1 }, [4, 3, 5, 4, 3, 4, 5, 3, 4, 4, 3, 4, 5, 3, 4, 4, 3, 4])
        XCTAssertEqual(learned.totalPar, 69)
        XCTAssertEqual(learned.teeSets.map(\.name), ["Blue"])
        XCTAssertEqual(learned.teeSets.first?.totalYardage, 6120)
        XCTAssertEqual(learned.verification, .userConfirmed)
        XCTAssertTrue(learned.mayRestoreStaticData, "A confirmed template is now useful for later scans")
        XCTAssertGreaterThan(learned.templateVersion, existing?.templateVersion ?? 0)
    }

    func testALearnedTemplateImprovesTheNextScanOfTheSameCourse() async throws {
        let learned = try LearnedTemplateBuilder.build(from: confirmedWolfCreekParse(), improving: GeorgiaCourseCatalog.template(withID: "ga-wolf-creek"))

        // The same course scanned again, this time with the name unreadable and two pars lost.
        var card = ScorecardFixtureBuilder.Card(
            titleLines: ["\u{2022}\u{2022}\u{2022}"],
            holeNumbers: Array(1...18),
            rows: [
                ScorecardFixtureBuilder.Row.printed(
                    label: "BLUE",
                    values: [380, 165, 510, 410, 175, 395, 530, 150, 420, 400, 180, 365, 520, 155, 405, 340, 190, 430].map { Optional($0) }
                ),
                ScorecardFixtureBuilder.Row.printed(
                    label: "PAR",
                    values: [4, 3, 5, 4, 3, 4, 5, 3, 4, 4, 3, 4, 5, 3, 4, 4, 3, 4].map { Optional($0) }
                ),
                ScorecardFixtureBuilder.Row.printed(
                    label: "HCP",
                    values: [5, 15, 1, 7, 17, 9, 3, 13, 11, 6, 16, 8, 2, 18, 4, 10, 14, 12].map { Optional($0) }
                ),
                ScorecardFixtureBuilder.Row.handwritten(
                    label: "JP",
                    values: [5, 4, 6, 5, 3, 5, 6, 4, 5, 5, 4, 5, 6, 4, 5, 5, 4, 5].map { Optional($0) }
                )
            ]
        )
        card.rows[1] = card.rows[1].corruptingHole(3, to: "?").droppingHole(13)

        // Replace the identity-only catalog entry with the learned one, as the app does.
        let templates = GeorgiaCourseCatalog.templates.map { $0.id == "ga-wolf-creek" ? learned : $0 }
        let parsed = try await ParserTestSupport.parse(card, templates: templates)

        XCTAssertEqual(parsed.candidateCourse?.id, "ga-wolf-creek", "The learned sequences identify the course with no name")
        XCTAssertEqual(parsed.hole(3)?.par.value, 5, "The learned template repairs the par cell OCR could not read")
        XCTAssertEqual(parsed.hole(13)?.par.value, 5, "And fills the one that was never read")
        XCTAssertEqual(parsed.hole(3)?.par.provenance, .verifiedCourseTemplate)
    }

    func testATemplateIsNotBuiltFromAnIncompleteScan() {
        var parsed = confirmedWolfCreekParse()
        parsed.holes[4].par = .empty

        XCTAssertFalse(LearnedTemplateBuilder.canBuildTemplate(from: parsed))
        XCTAssertThrowsError(try LearnedTemplateBuilder.build(from: parsed, improving: nil)) { error in
            guard case LearnedTemplateBuilder.BuildFailure.insufficientStaticData(let missing) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(missing, [5])
        }
    }

    func testValuesThatCameFromAnotherTemplateAreNotRePromoted() throws {
        // A value restored from a template is not independent evidence; promoting it would launder one
        // template's error into a second "source".
        var parsed = confirmedWolfCreekParse()
        parsed.holes[2].handicapIndex = .template(1)
        parsed.holes[2].yardage = .template(510)

        let learned = try LearnedTemplateBuilder.build(from: parsed, improving: nil)
        XCTAssertNil(learned.handicapIndices[2], "A template-supplied stroke index must not be re-promoted")
        XCTAssertNil(learned.teeSets.first?.yardages[2])
        XCTAssertEqual(learned.verification, .partial, "An incomplete promotion is marked partial, not confirmed")
    }

    func testAScoreCanNeverEnterATemplate() throws {
        let parsed = confirmedWolfCreekParse()
        let learned = try LearnedTemplateBuilder.build(from: parsed, improving: nil)

        // There is nowhere in CourseTemplate for a score to live, and the encoded form proves it.
        let encoded = try JSONEncoder().encode(learned)
        let json = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        XCTAssertFalse(json.lowercased().contains("playerscore"))
        XCTAssertFalse(json.lowercased().contains("\"score\""))
    }

    // MARK: - Remote service

    func testTheShippingRemoteServiceIsDisabledAndTheAppStillWorks() async throws {
        let service = LocalOnlyRemoteVisionService()
        XCTAssertFalse(service.isConfigured)
        XCTAssertFalse(service.hasUserConsent)

        do {
            _ = try await service.parseScorecard(imageData: Data(), holeCount: 18)
            XCTFail("The local-only service must not pretend to parse")
        } catch let error as RemoteScorecardVisionError {
            guard case .notConfigured = error else { return XCTFail("Unexpected error: \(error)") }
        }

        // And a full parse succeeds without it.
        let parsed = try await ParserTestSupport.parse(
            ScorecardFixtureBuilder.steelCanyonCard(scores: ParserTestSupport.steelCanyonScores)
        )
        XCTAssertEqual(parsed.candidateCourse?.id, "ga-steel-canyon")
    }

    func testARemoteReadingOnlyFillsScoresTheLocalParserWasUnsureOf() async throws {
        var card = ScorecardFixtureBuilder.steelCanyonCard(scores: ParserTestSupport.steelCanyonScores)
        card.rows[5] = card.rows[5].corruptingHole(4, to: "~")
        let parsed = try await ParserTestSupport.parse(card)
        XCTAssertNil(parsed.hole(4)?.playerScore.value)

        let localHole1Confidence = try XCTUnwrap(parsed.hole(1)?.playerScore.confidence)

        let payload = RemoteScorecardPayload(
            courseName: "Steel Canyon Golf Club",
            teeName: "White",
            playerName: "J. PEARLMAN",
            holes: [
                .init(holeNumber: 4, playerScore: 4, confidence: 0.91),   // local read nothing at all
                // Clears the minimum, but not by the margin over what the local parser already read.
                .init(holeNumber: 1, playerScore: 8, confidence: localHole1Confidence + 0.05),
                .init(holeNumber: 2, playerScore: 7, confidence: 0.20),   // below the minimum entirely
                .init(holeNumber: 3, playerScore: 99, confidence: 0.99)   // not a golf score
            ]
        )
        let (merged, updated) = RemoteParseMerger.merge(payload: payload, into: parsed)

        XCTAssertEqual(updated, [4], "Only the hole the local parser could not read should change")
        XCTAssertEqual(merged.hole(4)?.playerScore.value, 4)
        XCTAssertEqual(merged.hole(4)?.playerScore.provenance, .multimodalFallback)
        XCTAssertEqual(merged.hole(1)?.playerScore.value, 5, "A marginal improvement is not enough to overwrite")
        XCTAssertEqual(merged.hole(2)?.playerScore.value, 4, "A low-confidence remote reading is ignored")
        XCTAssertNotEqual(merged.hole(3)?.playerScore.value, 99, "An implausible remote reading is rejected")
    }

    func testAClearlyBetterRemoteReadingDoesReplaceAWeakLocalOne() async throws {
        var card = ScorecardFixtureBuilder.steelCanyonCard(scores: ParserTestSupport.steelCanyonScores)
        card.rows[5] = card.rows[5].corruptingHole(7, to: "3")
        let parsed = try await ParserTestSupport.parse(card)
        let localConfidence = try XCTUnwrap(parsed.hole(7)?.playerScore.confidence)
        XCTAssertLessThan(localConfidence, 0.8, "Handwriting is never read confidently")

        let payload = RemoteScorecardPayload(
            courseName: nil, teeName: nil, playerName: nil,
            holes: [.init(holeNumber: 7, playerScore: 6, confidence: localConfidence + 0.3)]
        )
        let (merged, updated) = RemoteParseMerger.merge(payload: payload, into: parsed)

        XCTAssertEqual(updated, [7])
        XCTAssertEqual(merged.hole(7)?.playerScore.value, 6)
        XCTAssertEqual(merged.hole(7)?.playerScore.provenance, .multimodalFallback)
    }

    func testARemoteReadingNeverOverwritesTheGolfersOwnEdit() async throws {
        var parsed = try await ParserTestSupport.parse(
            ScorecardFixtureBuilder.steelCanyonCard(scores: ParserTestSupport.steelCanyonScores)
        )
        parsed.setScore(6, forHole: 4)

        let payload = RemoteScorecardPayload(
            courseName: nil, teeName: nil, playerName: nil,
            holes: [.init(holeNumber: 4, playerScore: 3, confidence: 0.99)]
        )
        let (merged, updated) = RemoteParseMerger.merge(payload: payload, into: parsed)

        XCTAssertTrue(updated.isEmpty)
        XCTAssertEqual(merged.hole(4)?.playerScore.value, 6)
        XCTAssertEqual(merged.hole(4)?.playerScore.provenance, .userEdited)
    }
}
