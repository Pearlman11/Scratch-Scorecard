import Foundation

/// Compares a sequence read off a card against a sequence a template claims.
///
/// Par and stroke-index sequences are the strongest fingerprints a scorecard carries. There are only so
/// many ways to arrange eighteen pars, and a stroke index is a permutation of `1…18` — two courses
/// agreeing on both by chance is vanishingly unlikely. That is what lets the matcher recover from a badly
/// damaged course name.
public enum SequenceSimilarity {

    /// The outcome of comparing one signal.
    public struct Result: Sendable, Equatable {
        /// Agreement across the entries that could be compared, `0...1`.
        public var score: Double
        /// Fraction of the template's holes for which the card supplied a reading, `0...1`.
        public var coverage: Double
        /// Entries compared.
        public var comparedCount: Int
        /// Entries that matched exactly, with no glyph substitution.
        public var exactCount: Int

        public static let none = Result(score: 0, coverage: 0, comparedCount: 0, exactCount: 0)

        /// Score weighted by how much of the sequence was actually available.
        ///
        /// A single hole agreeing is not evidence of anything; this keeps a one-hole read from scoring the
        /// same as a full eighteen-hole agreement.
        public var weightedScore: Double {
            score * coverage
        }
    }

    /// Element-wise comparison with OCR tolerance. `observed` entries may be `nil` for unread holes.
    public static func compare(observed: [Int?], expected: [Int?]) -> Result {
        guard !expected.isEmpty else { return .none }
        var total = 0.0
        var compared = 0
        var exact = 0
        var expectedAvailable = 0

        for index in expected.indices {
            guard let expectedValue = expected[index] else { continue }
            expectedAvailable += 1
            guard observed.indices.contains(index), let observedValue = observed[index] else { continue }
            compared += 1
            let agreement = NumericOCR.similarity(observed: observedValue, expected: expectedValue)
            total += agreement
            if agreement >= 1.0 { exact += 1 }
        }

        guard compared > 0, expectedAvailable > 0 else { return .none }
        return Result(
            score: total / Double(compared),
            coverage: Double(compared) / Double(expectedAvailable),
            comparedCount: compared,
            exactCount: exact
        )
    }

    /// Yardage comparison, which needs a different tolerance from small integers.
    ///
    /// A yardage read as `333` when the card says `338` is a plausible misread; a yardage read as `433` is
    /// a different hole. Relative distance is therefore scored alongside digit confusion, and the better of
    /// the two is used so both failure modes are forgiven once.
    public static func compareYardages(observed: [Int?], expected: [Int?]) -> Result {
        guard !expected.isEmpty else { return .none }
        var total = 0.0
        var compared = 0
        var exact = 0
        var expectedAvailable = 0

        for index in expected.indices {
            guard let expectedValue = expected[index], expectedValue > 0 else { continue }
            expectedAvailable += 1
            guard observed.indices.contains(index), let observedValue = observed[index] else { continue }
            compared += 1
            if observedValue == expectedValue {
                total += 1
                exact += 1
                continue
            }
            let glyphScore = NumericOCR.similarity(observed: observedValue, expected: expectedValue)
            let relativeError = Double(abs(observedValue - expectedValue)) / Double(expectedValue)
            // Within 4% is near-certainly the same hole; beyond 15% is a different hole.
            let proximityScore: Double
            switch relativeError {
            case ..<0.04: proximityScore = 0.9
            case ..<0.15: proximityScore = 0.5 * (1 - (relativeError - 0.04) / 0.11)
            default: proximityScore = 0
            }
            total += max(glyphScore, proximityScore)
        }

        guard compared > 0, expectedAvailable > 0 else { return .none }
        return Result(
            score: total / Double(compared),
            coverage: Double(compared) / Double(expectedAvailable),
            comparedCount: compared,
            exactCount: exact
        )
    }

    /// Compares a total (OUT, IN or overall) against a template's total.
    public static func compareTotal(observed: Int?, expected: Int?) -> Double? {
        guard let observed, let expected, expected > 0 else { return nil }
        if observed == expected { return 1 }
        let glyph = NumericOCR.similarity(observed: observed, expected: expected)
        let relativeError = Double(abs(observed - expected)) / Double(expected)
        let proximity = relativeError < 0.03 ? 0.8 : max(0, 1 - relativeError * 8)
        return max(glyph, proximity)
    }
}
