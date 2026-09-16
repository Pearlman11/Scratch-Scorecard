import Foundation

/// Totals for a round or a partial round.
///
/// Every total is optional because a golfer who walked in after fourteen holes still has a real,
/// displayable card. Reporting `nil` for the back nine is honest; reporting the sum of four holes as if it
/// were nine is not.
public struct ScoreTotals: Sendable, Hashable, Codable {
    /// Sum of holes 1-9 when every one of them has a score.
    public var front: Int?
    /// Sum of holes 10-18 when every one of them has a score.
    public var back: Int?
    /// Sum of all holes when every hole on the card has a score.
    public var total: Int?
    /// Sum of the scores actually entered, however many that is. Always present.
    public var partialTotal: Int
    /// How many holes have a score.
    public var holesWithScores: Int
    /// `total - par` when both are known.
    public var relativeToPar: Int?
    /// `partialTotal` minus the par of just the holes played. Lets a partial round still show a meaningful
    /// figure without pretending the round is complete.
    public var relativeToParForHolesPlayed: Int?

    public var isComplete: Bool { total != nil }
}

/// Totals and par arithmetic. Pure, so the review screen can recompute on every keystroke and the tests
/// can verify it without a database.
public enum ScoreMath {

    /// Computes totals from per-hole scores and pars.
    ///
    /// - Parameters:
    ///   - scores: score per hole, index 0 == hole 1. `nil` for a hole not yet played or not yet read.
    ///   - pars: par per hole, same indexing.
    ///   - holeCount: how many holes the layout has. Governs which ranges are meaningful.
    public static func totals(scores: [Int?], pars: [Int?], holeCount: Int) -> ScoreTotals {
        func sum(_ range: Range<Int>, from values: [Int?]) -> Int? {
            var accumulated = 0
            for index in range {
                guard values.indices.contains(index), let value = values[index] else { return nil }
                accumulated += value
            }
            return accumulated
        }

        let front = holeCount >= 9 ? sum(0..<9, from: scores) : nil
        let back = holeCount >= 18 ? sum(9..<18, from: scores) : nil
        let total = holeCount > 0 ? sum(0..<holeCount, from: scores) : nil

        var partial = 0
        var played = 0
        var parForPlayed = 0
        var parForPlayedKnown = true
        for index in 0..<max(0, holeCount) {
            guard scores.indices.contains(index), let score = scores[index] else { continue }
            partial += score
            played += 1
            if pars.indices.contains(index), let par = pars[index] {
                parForPlayed += par
            } else {
                parForPlayedKnown = false
            }
        }

        var relativeToPar: Int?
        if let total, let coursePar = sum(0..<holeCount, from: pars) {
            relativeToPar = total - coursePar
        }

        let relativeForPlayed: Int? = (played > 0 && parForPlayedKnown) ? partial - parForPlayed : nil

        return ScoreTotals(
            front: front,
            back: back,
            total: total,
            partialTotal: partial,
            holesWithScores: played,
            relativeToPar: relativeToPar,
            relativeToParForHolesPlayed: relativeForPlayed
        )
    }

    /// Formats a relative-to-par figure the way a golfer reads it.
    public static func formatRelativeToPar(_ value: Int?) -> String {
        guard let value else { return "—" }
        if value == 0 { return "E" }
        return value > 0 ? "+\(value)" : "\(value)"
    }

    /// Plausible stroke count for one hole. Used to *validate* a reading, never to invent one:
    /// a value outside this range is discarded, but a missing value is never replaced by one inside it.
    public static let plausibleScoreRange: ClosedRange<Int> = 1...15

    /// Plausible par for one hole.
    public static let plausibleParRange: ClosedRange<Int> = 3...6

    /// Plausible stroke index for one hole.
    public static let plausibleHandicapRange: ClosedRange<Int> = 1...18

    /// Plausible yardage for one hole.
    public static let plausibleYardageRange: ClosedRange<Int> = 40...750
}
