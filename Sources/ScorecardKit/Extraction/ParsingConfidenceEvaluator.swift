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

    public func evaluate(
        holes: [ParsedHole],
        holeCount: Int,
        players: [DetectedPlayer],
        courseConfidence: Double,
        courseResolved: Bool,
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
        let meanScoreConfidence = scored.isEmpty
            ? 0
            : scored.map(\.confidence).reduce(0, +) / Double(scored.count)
        let staticCompleteness = (parCoverage * 0.5) + (handicapCoverage * 0.2) + (yardageCoverage * 0.3)

        let overall =
            courseConfidence * 0.25 +
            staticCompleteness * 0.25 +
            (scoreCoverage * meanScoreConfidence) * 0.50

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
