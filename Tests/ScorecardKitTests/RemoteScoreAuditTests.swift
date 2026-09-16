import XCTest
@testable import ScorecardKit

/// Tests for the safeguard that makes an AI reading usable: checking it against the card's own arithmetic
/// before any of it is believed.
///
/// Built from the same photographed Steel Canyon card as `ScoreChecksumSolverTests`. J's row reads
/// 40 / 37 / 77 and C's reads 35 / 33 / 68, both written by the golfers themselves, which is what gives
/// these tests a ground truth that does not depend on anything the parser produced.
final class RemoteScoreAuditTests: XCTestCase {

    // J's real row from the card. Sums: front 40, back 37, total 77.
    private let jScores = [6, 4, 3, 5, 3, 8, 5, 3, 3, 4, 5, 4, 3, 4, 4, 6, 4, 3]
    // C's real row. Sums: front 35, back 33, total 68.
    private let cScores = [4, 4, 3, 4, 3, 6, 3, 4, 4, 4, 3, 3, 3, 4, 4, 4, 4, 4]

    private func remotePlayer(
        name: String? = "J. PEARLMAN",
        scores: [Int?],
        confidence: Double = 0.9,
        out: Int?,
        inward: Int?,
        total: Int?
    ) -> RemoteScorecardPayload.Player {
        RemoteScorecardPayload.Player(
            name: name,
            holes: scores.enumerated().map { index, score in
                .init(holeNumber: index + 1, playerScore: score, confidence: score == nil ? nil : confidence)
            },
            writtenOut: out,
            writtenIn: inward,
            writtenTotal: total
        )
    }

    private func localPlayer(
        name: String? = "J. PEARLMAN",
        scores: [ParsedField<Int>]? = nil,
        out: ParsedField<Int> = .empty,
        inward: ParsedField<Int> = .empty,
        total: ParsedField<Int> = .empty
    ) -> DetectedPlayer {
        DetectedPlayer(
            name: name,
            fallbackLabel: "Player 1",
            scores: scores ?? Array(repeating: .empty, count: 18),
            rowConfidence: 0.6,
            writtenOut: out,
            writtenIn: inward,
            writtenTotal: total
        )
    }

    /// Holes as they look after the printed data was restored from the template but no handwriting was read
    /// — which is precisely the state the real app reached on the photographed card.
    private func holesWithNoScores() -> [ParsedHole] {
        (1...18).map { number in
            var hole = ParsedHole(holeNumber: number)
            hole.par = .template(SteelCanyonTemplate.pars[number - 1])
            hole.handicapIndex = .template(SteelCanyonTemplate.handicapIndices[number - 1])
            hole.yardage = .template(SteelCanyonTemplate.whiteYardages[number - 1])
            return hole
        }
    }

    private func cardWithNoHandwriting() -> ParsedScorecard {
        ParsedScorecard(
            candidateCourse: SteelCanyonTemplate.template.identity,
            candidateTee: "White",
            teeConfidence: 0.4,
            courseConfidence: 0.84,
            appliedTemplateID: SteelCanyonTemplate.template.id,
            holeCount: 18,
            holes: holesWithNoScores(),
            detectedPlayers: [],
            warnings: [ParseWarning(
                kind: .noPlayerRowsDetected,
                severity: .warning,
                detail: "No handwritten score row was recognised. You can enter your scores directly."
            )],
            quality: .needsAttention
        )
    }

    // MARK: - The audit itself

    func testARowThatAddsUpToItsOwnWrittenTotalsIsCorroborated() {
        let verdict = RemoteScoreAudit.audit(
            player: remotePlayer(scores: jScores, out: 40, inward: 37, total: 77),
            against: nil,
            holeCount: 18
        )
        guard case .corroborated(let checks) = verdict else {
            return XCTFail("Expected corroboration, got \(verdict)")
        }
        // Front, back and total, all against the model's own transcription of those cells.
        XCTAssertEqual(checks.count, 3)
        XCTAssertTrue(checks.allSatisfy { $0.passed })
        XCTAssertTrue(checks.allSatisfy { $0.source == .remote })
        XCTAssertEqual(RemoteConfidencePolicy.ceiling(for: verdict), RemoteConfidencePolicy.corroboratedCeiling)
    }

    /// The case that matters most: a single invented digit in an otherwise correct row.
    ///
    /// This is the actual failure mode of handing handwriting to a language model — not a wildly wrong
    /// answer, but a confident, plausible row with one cell filled in rather than read. The arithmetic
    /// catches it; nothing about the value itself would.
    func testOneFabricatedScoreBreaksTheArithmeticAndIsCaught() {
        var fabricated: [Int?] = jScores
        fabricated[5] = 5   // hole 6 was an 8; 5 is a perfectly plausible score

        let verdict = RemoteScoreAudit.audit(
            player: remotePlayer(scores: fabricated, out: 40, inward: 37, total: 77),
            against: nil,
            holeCount: 18
        )
        guard case .contradicted(let failures) = verdict else {
            return XCTFail("Expected contradiction, got \(verdict)")
        }
        XCTAssertTrue(failures.contains { $0.label == "front nine" && $0.sum == 37 && $0.subtotal == 40 })
        XCTAssertTrue(failures.contains { $0.label == "18-hole total" })
        XCTAssertFalse(failures.contains { $0.label == "back nine" }, "The untouched half still checks out")

        // Low enough that every cell is shown for review, and low enough that the checksum solver may
        // overwrite it.
        let ceiling = RemoteConfidencePolicy.ceiling(for: verdict)
        XCTAssertLessThan(ceiling, 0.82)
        XCTAssertLessThanOrEqual(ceiling, ScoreChecksumSolver.Configuration().overwritableConfidence)
    }

    func testALocallyReadSubtotalIsUsedAsAnIndependentCheck() {
        // The model did not transcribe the subtotals, but on-device OCR read OUT.
        let verdict = RemoteScoreAudit.audit(
            player: remotePlayer(scores: jScores, out: nil, inward: nil, total: nil),
            against: localPlayer(out: .ocr(40, confidence: 0.8)),
            holeCount: 18
        )
        guard case .corroborated(let checks) = verdict else {
            return XCTFail("Expected corroboration, got \(verdict)")
        }
        XCTAssertEqual(checks.count, 1)
        XCTAssertEqual(checks[0].source, .local)
    }

    /// A shaky local read must not be allowed to condemn a correct remote row.
    func testAWeaklyReadLocalSubtotalIsNotUsedToCondemnTheRow() {
        let verdict = RemoteScoreAudit.audit(
            player: remotePlayer(scores: jScores, out: nil, inward: nil, total: nil),
            against: localPlayer(out: .ocr(46, confidence: 0.3)),   // misread, barely
            holeCount: 18
        )
        XCTAssertEqual(verdict, .unverifiable(.noSubtotals))
    }

    func testARowWithNoTotalsAnywhereIsReportedUnverifiedRatherThanTrusted() {
        let verdict = RemoteScoreAudit.audit(
            player: remotePlayer(scores: jScores, out: nil, inward: nil, total: nil),
            against: nil,
            holeCount: 18
        )
        XCTAssertEqual(verdict, .unverifiable(.noSubtotals))
        // Just below the review threshold: an unchecked model reading is a suggestion, not an answer.
        XCTAssertLessThan(RemoteConfidencePolicy.unverifiedCeiling, 0.82)
        XCTAssertEqual(RemoteConfidencePolicy.ceiling(for: verdict), RemoteConfidencePolicy.unverifiedCeiling)
    }

    func testARowWithUnreadCellsCannotBeSummedAndSaysSo() {
        var withGaps: [Int?] = jScores
        withGaps[12] = nil

        let verdict = RemoteScoreAudit.audit(
            player: remotePlayer(scores: withGaps, out: 40, inward: nil, total: nil),
            against: nil,
            holeCount: 18
        )
        // The front nine is complete and still checks out; the back nine cannot be summed at all.
        guard case .corroborated(let checks) = verdict else {
            return XCTFail("Expected the intact half to corroborate, got \(verdict)")
        }
        XCTAssertEqual(checks.map(\.label), ["front nine"])
    }

    func testAnEntirelyUnreadRowIsUnverifiableNotCorroborated() {
        let verdict = RemoteScoreAudit.audit(
            player: remotePlayer(scores: Array(repeating: nil, count: 18), out: nil, inward: nil, total: nil),
            against: nil,
            holeCount: 18
        )
        XCTAssertEqual(verdict, .unverifiable(.rowIncomplete))
    }

    // MARK: - Integration: the card the app actually failed on

    func testTheAIReadRecoversACardWhereNoHandwritingWasDetectedAtAll() {
        let card = cardWithNoHandwriting()
        XCTAssertTrue(card.detectedPlayers.isEmpty)
        XCTAssertTrue(card.holes.allSatisfy { !$0.playerScore.hasValue })

        let payload = RemoteScorecardPayload(
            courseName: "Steel Canyon Golf Club",
            teeName: "White",
            players: [remotePlayer(scores: jScores, out: 40, inward: 37, total: 77)]
        )
        let outcome = RemoteParseIntegrator.integrate(payload: payload, into: card)

        XCTAssertEqual(outcome.adoptedPlayerIDs.count, 1, "The row the local parser never saw becomes a player")
        XCTAssertEqual(outcome.scorecard.selectedPlayer?.name, "J. PEARLMAN")
        XCTAssertEqual(outcome.scorecard.scores.compactMap { $0 }, jScores)
        XCTAssertEqual(outcome.scorecard.totals.total, 77)
        XCTAssertTrue(outcome.audits.allSatisfy { $0.verdict.isCorroborated })

        // Every score is the model's, and none of it is passed off as having been read on device.
        XCTAssertTrue(outcome.scorecard.holes.allSatisfy { $0.playerScore.provenance == .multimodalFallback })
        XCTAssertTrue(outcome.scorecard.holes.allSatisfy { $0.playerScore.provenance.isPermittedForPlayerScore })

        // The warning that prompted all of this is gone, because it is no longer true.
        XCTAssertTrue(outcome.scorecard.warnings(ofKind: .noPlayerRowsDetected).isEmpty)
        XCTAssertFalse(outcome.scorecard.warnings(ofKind: .remoteParseCorroborated).isEmpty)
    }

    /// A corroborated read should leave the golfer with a card they can save, not eighteen warnings.
    func testACorroboratedReadRaisesConfidenceEnoughToStopNaggingAboutEveryCell() {
        let before = cardWithNoHandwriting()
        let payload = RemoteScorecardPayload(
            courseName: nil, teeName: nil,
            players: [remotePlayer(scores: jScores, out: 40, inward: 37, total: 77)]
        )
        let after = RemoteParseIntegrator.integrate(payload: payload, into: before).scorecard

        XCTAssertTrue(after.holesNeedingReview.isEmpty)
        XCTAssertGreaterThan(after.overallConfidence, before.overallConfidence)
        XCTAssertGreaterThan(after.overallConfidence, 0.8)
        XCTAssertEqual(after.quality, .readyToReview)
    }

    /// A contradicted read must still surface every cell, however sure the model claimed to be.
    func testAContradictedReadIsSavedButFlaggedForReviewThroughout() {
        var fabricated: [Int?] = jScores
        fabricated[5] = 5

        let payload = RemoteScorecardPayload(
            courseName: nil, teeName: nil,
            players: [remotePlayer(scores: fabricated, confidence: 0.99, out: 40, inward: 37, total: 77)]
        )
        let outcome = RemoteParseIntegrator.integrate(payload: payload, into: cardWithNoHandwriting())

        XCTAssertFalse(outcome.scorecard.warnings(ofKind: .remoteParseContradicted).isEmpty)
        XCTAssertTrue(
            outcome.scorecard.holes.allSatisfy { $0.playerScore.confidence <= RemoteConfidencePolicy.contradictedCeiling },
            "A model's 0.99 does not survive a row that does not add up"
        )
        XCTAssertEqual(outcome.scorecard.holesNeedingReview.count, 18)
    }

    /// The arithmetic outranks the model, which is the whole ordering of the pipeline.
    func testTheChecksumSolverFillsACellTheModelCouldNotRead() {
        var withGap: [Int?] = jScores
        withGap[5] = nil   // hole 6, the boxed 8 — the cell every reader struggles with

        let payload = RemoteScorecardPayload(
            courseName: nil, teeName: nil,
            players: [remotePlayer(scores: withGap, out: 40, inward: 37, total: 77)]
        )
        let outcome = RemoteParseIntegrator.integrate(payload: payload, into: cardWithNoHandwriting())

        XCTAssertEqual(outcome.scorecard.hole(6)?.playerScore.value, 8, "40 - 32 = 8, determined exactly")
        XCTAssertEqual(outcome.scorecard.hole(6)?.playerScore.provenance, .solvedFromSubtotal)
        XCTAssertEqual(outcome.scorecard.checksumSolvedHoles, [6])
        XCTAssertEqual(outcome.scorecard.totals.total, 77)
    }

    func testWithSeveralRowsTheAppAsksWhichIsYoursRatherThanChoosing() {
        let payload = RemoteScorecardPayload(
            courseName: nil, teeName: nil,
            players: [
                remotePlayer(name: "C", scores: cScores, out: 35, inward: 33, total: 68),
                remotePlayer(name: "J. PEARLMAN", scores: jScores, out: 40, inward: 37, total: 77)
            ]
        )
        let outcome = RemoteParseIntegrator.integrate(payload: payload, into: cardWithNoHandwriting())

        XCTAssertEqual(outcome.adoptedPlayerIDs.count, 2)
        XCTAssertNil(outcome.scorecard.selectedPlayerID, "Picking a golfer's row for them is not the app's call")
        XCTAssertTrue(outcome.scorecard.holes.allSatisfy { !$0.playerScore.hasValue })
        XCTAssertFalse(outcome.scorecard.warnings(ofKind: .playerCountNeedsConfirmation).isEmpty)
    }

    func testAModelReadingNeverOverwritesAScoreTheGolferTyped() {
        var card = cardWithNoHandwriting()
        card.detectedPlayers = [localPlayer(scores: Array(repeating: ParsedField<Int>.empty, count: 18))]
        card.selectPlayer(id: card.detectedPlayers[0].id)
        card.setScore(9, forHole: 3)

        let payload = RemoteScorecardPayload(
            courseName: nil, teeName: nil,
            players: [remotePlayer(scores: jScores, confidence: 0.99, out: nil, inward: nil, total: nil)]
        )
        let outcome = RemoteParseIntegrator.integrate(payload: payload, into: card)

        XCTAssertEqual(outcome.scorecard.hole(3)?.playerScore.value, 9)
        XCTAssertEqual(outcome.scorecard.hole(3)?.playerScore.provenance, .userEdited)
        XCTAssertFalse(outcome.updatedHoles.contains(3))
    }

    /// The remote parser's remit is the handwriting. Nothing else on the card is its business.
    func testAModelReadingCannotTouchPrintedCourseData() {
        let card = cardWithNoHandwriting()
        let payload = RemoteScorecardPayload(
            courseName: "Somewhere Else Golf Club",
            teeName: "Black",
            players: [remotePlayer(scores: jScores, out: 40, inward: 37, total: 77)]
        )
        let outcome = RemoteParseIntegrator.integrate(payload: payload, into: card)

        XCTAssertEqual(outcome.scorecard.candidateCourse?.id, SteelCanyonTemplate.template.id)
        XCTAssertEqual(outcome.scorecard.candidateTee, "White")
        for hole in outcome.scorecard.holes {
            XCTAssertEqual(hole.par.provenance, .verifiedCourseTemplate)
            XCTAssertEqual(hole.par.value, SteelCanyonTemplate.pars[hole.holeNumber - 1])
            XCTAssertEqual(hole.yardage.value, SteelCanyonTemplate.whiteYardages[hole.holeNumber - 1])
        }
    }

    func testAnEmptyResponseChangesNothingAndSaysWhy() {
        let card = cardWithNoHandwriting()
        let outcome = RemoteParseIntegrator.integrate(
            payload: RemoteScorecardPayload(courseName: nil, teeName: nil, players: []),
            into: card
        )
        XCTAssertFalse(outcome.changedAnything)
        XCTAssertTrue(outcome.scorecard.holes.allSatisfy { !$0.playerScore.hasValue })
        XCTAssertFalse(outcome.scorecard.warnings(ofKind: .noPlayerRowsDetected).isEmpty)
    }
}
