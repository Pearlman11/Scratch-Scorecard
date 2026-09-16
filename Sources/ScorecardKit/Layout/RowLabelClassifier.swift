import Foundation

/// Decides what each reconstructed row *is*.
///
/// This is the highest-stakes decision in the parser. Par, stroke index and yardage are printed facts a
/// verified template is allowed to correct; a player's score is not. Misclassifying one as the other would
/// let the app write a template's par into a golfer's card and call it a scan. Two independent lines of
/// evidence are therefore combined for every row:
///
/// 1. **The label gutter** — what the card printed to the left of the grid. Decisive when readable.
/// 2. **The numeric signature** — what the values themselves can and cannot be. A row whose eighteen
///    values are a permutation of `1…18` is a stroke-index row and essentially nothing else; a row whose
///    values run to three digits is a yardage row and cannot be a score.
///
/// Where the two collide, the label wins, because a card that prints `PAR` is telling us something the
/// numbers cannot.
public struct RowLabelClassifier: Sendable {

    public init() {}

    /// What the values in a row could plausibly be, independent of any label.
    public struct NumericSignature: Sendable, Equatable {
        public var values: [Int]
        public var parLikelihood: Double
        public var handicapLikelihood: Double
        public var yardageLikelihood: Double
        public var scoreLikelihood: Double

        public var isEmpty: Bool { values.isEmpty }
    }

    /// Classification of one row, with the evidence that produced it.
    public struct Classification: Sendable {
        public var role: ScorecardRowRole
        public var confidence: Double
        public var labelMatch: RowLabelLexicon.LabelMatch?
        public var signature: NumericSignature
        /// Filled in when the row could be either par or a player's scores on the evidence available.
        public var isParScoreAmbiguous: Bool
    }

    // MARK: - Signature

    /// Scores what a row of integers is likely to represent.
    ///
    /// Likelihoods are deliberately *not* normalized to sum to one: a row can look strongly like nothing at
    /// all, and saying so is more useful than forcing a winner.
    public func numericSignature(of values: [Int]) -> NumericSignature {
        guard !values.isEmpty else {
            return NumericSignature(values: [], parLikelihood: 0, handicapLikelihood: 0, yardageLikelihood: 0, scoreLikelihood: 0)
        }
        let count = Double(values.count)

        // Yardage: three-digit distances. Nothing else on a scorecard reaches these magnitudes, which makes
        // this the one signature that is close to conclusive on its own.
        let yardageLike = values.filter { $0 >= 60 && $0 <= 750 }.count
        let bigValues = values.filter { $0 >= 100 }.count
        var yardage = Double(yardageLike) / count
        if bigValues == 0 { yardage *= 0.25 }

        // Par: 3...6, with the distribution a real course has. Executive courses are mostly 3s, so no
        // assumption is made about the mean — only about the range.
        let parLike = values.filter { $0 >= 3 && $0 <= 6 }.count
        var par = Double(parLike) / count
        if values.contains(where: { $0 > 6 || $0 < 3 }) {
            par *= 0.6
        }

        // Stroke index: a permutation of 1...n. Distinctness is the real signal.
        let hcpInRange = values.filter { $0 >= 1 && $0 <= 18 }.count
        let distinct = Set(values).count
        var handicap = Double(hcpInRange) / count
        handicap *= Double(distinct) / count
        // A stroke-index row spans its range; par and score rows bunch up.
        if let maximum = values.max(), let minimum = values.min() {
            let spread = Double(maximum - minimum)
            let expectedSpread = Double(max(1, values.count - 1))
            handicap *= min(1.0, spread / expectedSpread)
        }
        if values.count >= 9 && distinct == values.count && Set(values).allSatisfy({ $0 >= 1 && $0 <= 18 }) {
            handicap = min(1.0, handicap + 0.25)
        }

        // Score: a stroke count a human could actually write down.
        let scoreLike = values.filter { $0 >= 1 && $0 <= 15 }.count
        var score = Double(scoreLike) / count
        if values.contains(where: { $0 > 15 }) { score *= 0.3 }

        return NumericSignature(
            values: values,
            parLikelihood: min(1, par),
            handicapLikelihood: min(1, handicap),
            yardageLikelihood: min(1, yardage),
            scoreLikelihood: min(1, score)
        )
    }

    // MARK: - Classification

    /// Classifies a row from its label gutter and the values found in its hole columns.
    public func classify(
        labelTokens: [String],
        holeValues: [Int],
        meanOCRConfidence: Double,
        heightUniformity: Double
    ) -> Classification {
        let signature = numericSignature(of: holeValues)
        let labelMatch = RowLabelLexicon.match(labelTokens: labelTokens)

        // A label is decisive when the values do not actively contradict it.
        if let labelMatch {
            switch labelMatch {
            case .hole:
                return Classification(role: .holeHeader, confidence: 0.95, labelMatch: labelMatch, signature: signature, isParScoreAmbiguous: false)
            case .par:
                let agreement = max(signature.parLikelihood, signature.isEmpty ? 0.5 : 0)
                return Classification(role: .par, confidence: 0.70 + 0.28 * agreement, labelMatch: labelMatch, signature: signature, isParScoreAmbiguous: false)
            case .handicap:
                let agreement = max(signature.handicapLikelihood, signature.isEmpty ? 0.5 : 0)
                return Classification(role: .handicap, confidence: 0.70 + 0.28 * agreement, labelMatch: labelMatch, signature: signature, isParScoreAmbiguous: false)
            case .tee(let name, _):
                // A tee label with no big numbers is a ratings row, not a yardage row.
                if signature.isEmpty || signature.yardageLikelihood < 0.35 {
                    return Classification(role: .metadata, confidence: 0.55, labelMatch: labelMatch, signature: signature, isParScoreAmbiguous: false)
                }
                return Classification(
                    role: .yardage(teeName: name),
                    confidence: 0.70 + 0.28 * signature.yardageLikelihood,
                    labelMatch: labelMatch,
                    signature: signature,
                    isParScoreAmbiguous: false
                )
            case .out, .inward, .total:
                return Classification(role: .metadata, confidence: 0.4, labelMatch: labelMatch, signature: signature, isParScoreAmbiguous: false)
            }
        }

        guard !signature.isEmpty else {
            return Classification(role: .unknown, confidence: 0, labelMatch: nil, signature: signature, isParScoreAmbiguous: false)
        }

        // No usable label: fall back to the signature, in order of how conclusive each one is.
        let playerName = RowLabelLexicon.looksLikePlayerName(labelTokens) ? labelTokens.joined(separator: " ") : nil

        if signature.yardageLikelihood >= 0.6 {
            return Classification(
                role: .yardage(teeName: nil),
                confidence: 0.45 + 0.35 * signature.yardageLikelihood,
                labelMatch: nil,
                signature: signature,
                isParScoreAmbiguous: false
            )
        }

        if signature.handicapLikelihood >= 0.85 && signature.values.count >= 9 {
            return Classification(
                role: .handicap,
                confidence: 0.40 + 0.40 * signature.handicapLikelihood,
                labelMatch: nil,
                signature: signature,
                isParScoreAmbiguous: false
            )
        }

        // Par and player scores overlap completely in range: both live in 3...6 for most holes. Neither the
        // values nor a missing label can separate them, so the row is marked ambiguous and resolved later
        // with card-level context (position, print quality, and agreement with a matched template).
        if signature.parLikelihood >= 0.5 || signature.scoreLikelihood >= 0.5 {
            // A written name is the one local signal that settles it immediately.
            if playerName != nil {
                return Classification(
                    role: .playerScores(name: playerName),
                    confidence: 0.6,
                    labelMatch: nil,
                    signature: signature,
                    isParScoreAmbiguous: false
                )
            }
            let printedLooking = (meanOCRConfidence >= 0.72 ? 1.0 : 0.0) * 0.5 + heightUniformity * 0.5
            let role: ScorecardRowRole = printedLooking >= 0.6 ? .par : .playerScores(name: nil)
            return Classification(
                role: role,
                confidence: 0.32,
                labelMatch: nil,
                signature: signature,
                isParScoreAmbiguous: true
            )
        }

        return Classification(
            role: playerName == nil ? .unknown : .playerScores(name: playerName),
            confidence: playerName == nil ? 0.1 : 0.45,
            labelMatch: nil,
            signature: signature,
            isParScoreAmbiguous: false
        )
    }
}
