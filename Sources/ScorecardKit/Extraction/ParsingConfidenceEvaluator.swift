import Foundation

/// Turns a finished parse into an overall confidence, a quality band and a set of actionable warnings.
///
/// The evaluator is separate from the parser so that "how good is this parse?" can be tuned and tested
/// without touching extraction. It is also where the product's honesty rule is enforced at the top level:
/// a parse that identified nothing is reported as failed, not as an empty success.
public struct ParsingConfidenceEvaluator: Sendable {

    public struct Configuration: Sendable {
        /// Fraction of holes that must carry a confident score for the parse to be `readyToReview`.
        public var readyScoreCoverage: Double
        /// Course confidence needed before static data is considered settled.
        public var courseConfidenceFloor: Double

        public init(readyScoreCoverage: Double = 0.80, courseConfidenceFloor: Double = 0.72) {
            self.readyScoreCoverage = readyScoreCoverage
            self.courseConfidenceFloor = courseConfidenceFloor
        }
    }

    public var configuration: Configuration

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    public struct Assessment: Sendable {
        public var overallConfidence: Double
        public var quality: ParseQuality
        public var warnings: [ParseWarning]
    }

    /// How much the card's own arithmetic corroborates the scores that were read.
    ///
    /// This is a genuinely different kind of evidence from a glyph read, and much stronger. A nine whose
    /// scores sum to the subtotal the golfer wrote is confirmed by a second, independent piece of their
    /// handwriting — so treating it with the same ~0.5 confidence that OCR assigns to any handwritten
    /// digit badly understates what is actually known.
    public enum ChecksumSupport: Sendable, Equatable {
        /// No written subtotals, so nothing corroborates the reads.
        case unavailable
        /// A nine's scores sum to its written subtotal, or a single unknown was solved from it.
        case confirmed(halves: Int)
        /// Scores were read but do not sum to the written subtotal. Something is wrong.
        case contradicted
    }

    public func evaluate(
        holes: [ParsedHole],
        holeCount: Int,
        players: [DetectedPlayer],
        courseConfidence: Double,
        courseResolved: Bool,
        checksumSupport: ChecksumSupport = .unavailable,
        existingWarnings: [ParseWarning]
    ) -> Assessment {
        var warnings = existingWarnings

        guard holeCount > 0, !holes.isEmpty else {
            warnings.append(ParseWarning(
                kind: .noScorecardTableDetected,
                severity: .blocking,
                detail: "No scorecard grid could be reconstructed from this image."
            ))
            return Assessment(overallConfidence: 0, quality: .failed, warnings: warnings)
        }

        // Static data completeness.
        let parCoverage = coverage(holes.map(\.par))
        let handicapCoverage = coverage(holes.map(\.handicapIndex))
        let yardageCoverage = coverage(holes.map(\.yardage))

        if parCoverage == 0 {
            warnings.append(ParseWarning(
                kind: .parRowNotFound,
                severity: .warning,
                detail: "No par row was found. Pick the course to fill par from its template, or enter par by hand."
            ))
        }
        if handicapCoverage == 0 {
            warnings.append(ParseWarning(
                kind: .handicapRowNotFound,
                severity: .info,
                detail: "No stroke-index (HCP) row was found."
            ))
        }
        if yardageCoverage == 0 {
            warnings.append(ParseWarning(
                kind: .yardageRowNotFound,
                severity: .info,
                detail: "No yardage row was found. Choosing a tee will fill yardages from the course template."
            ))
        }

        // Player data.
        //
        // Confirming the roster up front removes a whole class of grid errors: once the app and the golfer
        // agree on how many rows are theirs and which one is which, every later question is about a cell
        // rather than about which row it belongs to. Raised even when exactly one row was found, because a
        // foursome whose other three rows went unread looks identical to a solo round from here.
        if !players.isEmpty {
            let names = players.map(\.displayName).joined(separator: ", ")
            warnings.append(ParseWarning(
                kind: .playerCountNeedsConfirmation,
                severity: .info,
                detail: players.count == 1
                    ? "Found 1 scoring row: \(names). Tap to change if more golfers were on this card."
                    : "Found \(players.count) scoring rows: \(names). Tap to pick yours or change the count."
            ))
        }
        if players.isEmpty {
            warnings.append(ParseWarning(
                kind: .noPlayerRowsDetected,
                severity: .warning,
                detail: "No handwritten score row was recognised. You can enter your scores directly."
            ))
        }

        let scoreFields = holes.map(\.playerScore)
        let scored = scoreFields.filter(\.hasValue)
        let scoreCoverage = Double(scored.count) / Double(holeCount)
        let missingHoles = holes.filter { !$0.playerScore.hasValue }.map(\.holeNumber)
        let lowConfidenceHoles = holes
            .filter { $0.playerScore.hasValue && $0.playerScore.requiresReview }
            .map(\.holeNumber)

        if !missingHoles.isEmpty && !players.isEmpty {
            warnings.append(ParseWarning(
                kind: missingHoles.count == holeCount ? .noPlayerRowsDetected : .someScoresMissing,
                severity: .warning,
                detail: "\(missingHoles.count) hole\(missingHoles.count == 1 ? "" : "s") have no score yet.",
                holeNumbers: missingHoles
            ))
        }
        if !lowConfidenceHoles.isEmpty {
            warnings.append(ParseWarning(
                kind: .someScoresLowConfidence,
                severity: .warning,
                detail: "\(lowConfidenceHoles.count) score\(lowConfidenceHoles.count == 1 ? "" : "s") were hard to read. Check them before saving.",
                holeNumbers: lowConfidenceHoles
            ))
        }

        if holeCount == 9 {
            warnings.append(ParseWarning(
                kind: .nineHoleRoundDetected,
                severity: .info,
                detail: "This card covers 9 holes."
            ))
        } else if holeCount != 18 && holeCount != 9 {
            warnings.append(ParseWarning(
                kind: .holeCountMismatch,
                severity: .warning,
                detail: "Only \(holeCount) hole columns were found. Part of the card may be cut off."
            ))
            warnings.append(ParseWarning(
                kind: .cardLikelyCropped,
                severity: .warning,
                detail: "Re-shoot the card with all hole columns in frame for a better read."
            ))
        }

        if scored.count > 0 && scored.count < holeCount {
            warnings.append(ParseWarning(
                kind: .incompleteRound,
                severity: .info,
                detail: "\(scored.count) of \(holeCount) holes have scores. You can still save an incomplete round.",
                holeNumbers: missingHoles
            ))
        }

        // Overall confidence blends identification, static completeness and score quality. Scores carry the
        // most weight because they are what the golfer actually came to capture.
        //
        // Score quality is measured over the cells that are *supposed* to hold a score — this golfer's
        // holes — never over every text block on the card. Blank rows a foursome never filled in, and the
        // printed par and yardage rows, say nothing about how well the handwriting was read.
        let rawMeanScoreConfidence = scored.isEmpty
            ? 0
            : scored.map(\.confidence).reduce(0, +) / Double(scored.count)

        // Raw OCR confidence on handwriting sits near 0.5 even when the read is perfect, because that is
        // simply how well a recognizer trained on print reports on a hand-drawn digit. Taken at face value
        // it caps a flawless scan at roughly half marks. Where the card's arithmetic confirms the scores,
        // that is the better evidence and it governs instead.
        let effectiveScoreConfidence: Double
        switch checksumSupport {
        case .confirmed(let halves):
            let expectedHalves = holeCount > 9 ? 2 : 1
            let share = Double(min(halves, expectedHalves)) / Double(expectedHalves)
            effectiveScoreConfidence = rawMeanScoreConfidence + (0.97 - rawMeanScoreConfidence) * share
        case .contradicted:
            effectiveScoreConfidence = rawMeanScoreConfidence * 0.6
        case .unavailable:
            effectiveScoreConfidence = rawMeanScoreConfidence
        }

        let staticCompleteness = (parCoverage * 0.5) + (handicapCoverage * 0.2) + (yardageCoverage * 0.3)

        let overall =
            courseConfidence * 0.25 +
            staticCompleteness * 0.25 +
            (scoreCoverage * effectiveScoreConfidence) * 0.50

        let quality: ParseQuality
        if !courseResolved && scoreCoverage < 0.25 {
            quality = .needsManualEntry
        } else if courseResolved
            && courseConfidence >= configuration.courseConfidenceFloor
            && scoreCoverage >= configuration.readyScoreCoverage
            && lowConfidenceHoles.count <= max(1, holeCount / 6) {
            quality = .readyToReview
        } else if scoreCoverage >= 0.25 || parCoverage > 0 {
            quality = .needsAttention
        } else {
            quality = .needsManualEntry
        }

        return Assessment(
            overallConfidence: min(1, max(0, overall)),
            quality: quality,
            warnings: warnings
        )
    }

    private func coverage(_ fields: [ParsedField<Int>]) -> Double {
        guard !fields.isEmpty else { return 0 }
        return Double(fields.filter(\.hasValue).count) / Double(fields.count)
    }
}
