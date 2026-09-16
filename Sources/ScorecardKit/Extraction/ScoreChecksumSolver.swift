import Foundation

/// Recovers unreadable scores from the subtotals the golfer wrote on their own card.
///
/// ## Why this is the strongest tool available
///
/// A scorecard is a self-checking document. The golfer writes nine strokes and then writes their sum, so a
/// nine with exactly one unreadable cell is not ambiguous at all — the subtotal determines the missing
/// value exactly. No amount of better handwriting recognition competes with arithmetic.
///
/// This matters most for precisely the cells OCR handles worst. A digit inside a hand-drawn box or circle
/// often reads as noise, and a score written over a scratched-out earlier number is worse still. Those are
/// also the cells a golfer is *most* likely to have marked up, because they mark up the holes that went
/// unusually. The subtotal recovers them without guessing.
///
/// ## What it will not do
///
/// - It never overwrites a value the golfer typed (`.userEdited`).
/// - It refuses a solution that is not a plausible stroke count, which is the signal that the *subtotal*
///   was misread rather than the cell — reported as a discrepancy instead of written in.
/// - With two or more unknowns in a nine it does nothing. The residual would have many splits and picking
///   one would be exactly the invented data this parser exists to avoid.
public struct ScoreChecksumSolver: Sendable {

    public struct Configuration: Sendable {
        /// A read at or below this confidence is treated as an unknown the subtotal may overwrite.
        ///
        /// Set above zero deliberately: a boxed or overwritten digit frequently produces a *confident-
        /// looking* wrong read rather than a blank, and the arithmetic is more trustworthy than a shaky
        /// read of a marked-up cell.
        public var overwritableConfidence: Double

        public init(overwritableConfidence: Double = 0.55) {
            self.overwritableConfidence = overwritableConfidence
        }
    }

    /// What the solver did to one nine.
    public enum HalfOutcome: Equatable, Sendable {
        /// No written subtotal, so nothing could be checked.
        case noSubtotal
        /// Every cell read and the sum matches the written subtotal. The strongest possible confirmation.
        case verified(subtotal: Int)
        /// Exactly one unknown, solved exactly from the subtotal.
        case solved(hole: Int, strokes: Int)
        /// Every cell read but the sum disagrees with the written subtotal.
        case discrepancy(sum: Int, subtotal: Int)
        /// Too many unknowns to determine a unique answer.
        case underdetermined(unknownHoles: [Int])
        /// One unknown, but the implied value is not a possible stroke count.
        case implausibleSolution(hole: Int, implied: Int)
    }

    public struct Result: Sendable {
        public var holes: [ParsedHole]
        public var front: HalfOutcome
        public var back: HalfOutcome
        /// Holes this solver filled in, for the review screen to explain.
        public var solvedHoles: [Int]
        public var warnings: [ParseWarning]

        /// How strongly the card's arithmetic backs up the scores, for the confidence evaluator.
        ///
        /// A contradiction anywhere outweighs confirmation elsewhere: if one nine does not add up, the
        /// card has been misread somewhere and the other nine adding up does not make that less true.
        public var checksumSupport: ParsingConfidenceEvaluator.ChecksumSupport {
            let outcomes = [front, back]
            if outcomes.contains(where: { if case .discrepancy = $0 { return true }; return false }) {
                return .contradicted
            }
            if outcomes.contains(where: { if case .implausibleSolution = $0 { return true }; return false }) {
                return .contradicted
            }
            let confirmed = outcomes.filter {
                switch $0 {
                case .verified, .solved: return true
                case .noSubtotal, .discrepancy, .underdetermined, .implausibleSolution: return false
                }
            }.count
            return confirmed > 0 ? .confirmed(halves: confirmed) : .unavailable
        }
    }

    public var configuration: Configuration

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    /// Applies the card's own arithmetic to a parsed set of holes.
    ///
    /// - Parameters:
    ///   - holes: the holes as read, which this returns a corrected copy of.
    ///   - writtenOut: the golfer's written front-nine total.
    ///   - writtenIn: the golfer's written back-nine total.
    ///   - writtenTotal: the golfer's written 18-hole total, used to recover a missing nine's subtotal.
    ///   - holeCount: how many holes the card covers.
    public func solve(
        holes: [ParsedHole],
        writtenOut: ParsedField<Int>,
        writtenIn: ParsedField<Int>,
        writtenTotal: ParsedField<Int>,
        holeCount: Int
    ) -> Result {
        var result = holes
        var solved: [Int] = []
        var warnings: [ParseWarning] = []

        // A missing nine-total can often be recovered from the other nine plus the grand total, which is
        // worth doing first: it turns a nine that could not be checked at all into one that can.
        let (outTotal, inTotal) = inferMissingSubtotals(
            writtenOut: writtenOut.value,
            writtenIn: writtenIn.value,
            writtenTotal: writtenTotal.value,
            holeCount: holeCount
        )

        let frontOutcome = applyHalf(
            to: &result,
            holeNumbers: Array(1...min(9, max(holeCount, 1))),
            subtotal: outTotal,
            solved: &solved
        )

        var backOutcome = HalfOutcome.noSubtotal
        if holeCount > 9 {
            backOutcome = applyHalf(
                to: &result,
                holeNumbers: Array(10...holeCount),
                subtotal: inTotal,
                solved: &solved
            )
        }

        warnings.append(contentsOf: warningsFor(frontOutcome, half: "front nine"))
        warnings.append(contentsOf: warningsFor(backOutcome, half: "back nine"))

        if !solved.isEmpty {
            warnings.append(ParseWarning(
                kind: .someScoresLowConfidence,
                severity: .info,
                detail: solved.count == 1
                    ? "Hole \(solved[0])'s score was worked out from the total you wrote. Worth a glance."
                    : "\(solved.count) scores were worked out from the totals you wrote. Worth a glance.",
                holeNumbers: solved.sorted()
            ))
        }

        return Result(
            holes: result,
            front: frontOutcome,
            back: backOutcome,
            solvedHoles: solved.sorted(),
            warnings: warnings
        )
    }

    // MARK: - One nine

    private func applyHalf(
        to holes: inout [ParsedHole],
        holeNumbers: [Int],
        subtotal: Int?,
        solved: inout [Int]
    ) -> HalfOutcome {
        guard let subtotal else { return .noSubtotal }

        var knownSum = 0
        var unknownHoles: [Int] = []

        for number in holeNumbers {
            guard let index = holes.firstIndex(where: { $0.holeNumber == number }) else { continue }
            let field = holes[index].playerScore
            // The golfer's own correction is never second-guessed, so it counts as known whatever its
            // confidence would otherwise suggest.
            if field.provenance == .userEdited, let value = field.value {
                knownSum += value
                continue
            }
            if let value = field.value, field.confidence > configuration.overwritableConfidence {
                knownSum += value
            } else {
                unknownHoles.append(number)
            }
        }

        switch unknownHoles.count {
        case 0:
            return knownSum == subtotal
                ? .verified(subtotal: subtotal)
                : .discrepancy(sum: knownSum, subtotal: subtotal)

        case 1:
            let hole = unknownHoles[0]
            let implied = subtotal - knownSum
            guard ScoreMath.plausibleScoreRange.contains(implied) else {
                // The arithmetic is sound, so an impossible answer means an input was wrong — most likely
                // the subtotal itself. Reporting that is useful; writing the number in would not be.
                return .implausibleSolution(hole: hole, implied: implied)
            }
            guard let index = holes.firstIndex(where: { $0.holeNumber == hole }) else {
                return .implausibleSolution(hole: hole, implied: implied)
            }
            holes[index].playerScore = .solvedFromSubtotal(implied)
            solved.append(hole)
            return .solved(hole: hole, strokes: implied)

        default:
            return .underdetermined(unknownHoles: unknownHoles)
        }
    }

    // MARK: - Subtotal recovery

    /// Fills in whichever nine-total is missing when the grand total and the other nine are both known.
    func inferMissingSubtotals(
        writtenOut: Int?,
        writtenIn: Int?,
        writtenTotal: Int?,
        holeCount: Int
    ) -> (out: Int?, inward: Int?) {
        guard holeCount > 9 else {
            // On a nine-hole card OUT and TOTAL are the same figure, so either can stand in for the other.
            return (writtenOut ?? writtenTotal, nil)
        }
        guard let total = writtenTotal else { return (writtenOut, writtenIn) }

        if let out = writtenOut, writtenIn == nil {
            let implied = total - out
            return (out, isPlausibleNineTotal(implied) ? implied : nil)
        }
        if let inward = writtenIn, writtenOut == nil {
            let implied = total - inward
            return (isPlausibleNineTotal(implied) ? implied : nil, inward)
        }
        return (writtenOut, writtenIn)
    }

    /// A nine of golf: nine holes at one stroke minimum, and generously capped well above any real round.
    private func isPlausibleNineTotal(_ value: Int) -> Bool {
        value >= 9 && value <= 9 * ScoreMath.plausibleScoreRange.upperBound
    }

    // MARK: - Warnings

    private func warningsFor(_ outcome: HalfOutcome, half: String) -> [ParseWarning] {
        switch outcome {
        case .noSubtotal, .verified, .solved:
            return []

        case .discrepancy(let sum, let subtotal):
            return [ParseWarning(
                kind: .someScoresLowConfidence,
                severity: .warning,
                detail: "The \(half) scores add up to \(sum), but the total written on the card is \(subtotal). One of them was misread — check the \(half)."
            )]

        case .underdetermined(let unknownHoles):
            return [ParseWarning(
                kind: .someScoresMissing,
                severity: .warning,
                detail: "\(unknownHoles.count) scores on the \(half) could not be read, so the written total cannot settle them. Enter them to finish the round.",
                holeNumbers: unknownHoles
            )]

        case .implausibleSolution(let hole, let implied):
            return [ParseWarning(
                kind: .someScoresLowConfidence,
                severity: .warning,
                detail: "Hole \(hole) is the only unread score on the \(half), but the written total implies \(implied) strokes, which is not a real score. The total itself was probably misread.",
                holeNumbers: [hole]
            )]
        }
    }
}
