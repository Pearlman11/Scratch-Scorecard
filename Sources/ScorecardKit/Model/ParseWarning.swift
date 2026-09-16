import Foundation

/// A machine-readable problem found while parsing. Warnings are data, not strings, so the UI can route
/// each one to the right recovery affordance instead of printing a sentence at the golfer.
public struct ParseWarning: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case noTextDetected
        case noScorecardTableDetected
        case imageLikelyBlurry
        case imageLikelyGlared
        case cardLikelyCropped
        case courseNameUnreadable
        case courseNotInCatalog
        case multipleCourseMatches
        case courseMatchLowConfidence
        case teeNotIdentified
        case multipleTeeMatches
        case noPlayerRowsDetected
        case playerCountNeedsConfirmation
        case someScoresMissing
        case someScoresLowConfidence
        case incompleteRound
        case nineHoleRoundDetected
        case holeCountMismatch
        case parRowNotFound
        case handicapRowNotFound
        case yardageRowNotFound
        case templateFilledStaticData
        case remoteParserUnavailable
        /// A remote reading's scores add up to the subtotals written on the card.
        case remoteParseCorroborated
        /// A remote reading's scores do not add up to the subtotals written on the card.
        case remoteParseContradicted
        /// A remote reading arrived with nothing available to check it against.
        case remoteParseUnverified
        case duplicateRoundSuspected
    }

    public enum Severity: String, Codable, Sendable, Comparable {
        case info
        case warning
        case blocking

        public static func < (lhs: Severity, rhs: Severity) -> Bool {
            let order: [Severity] = [.info, .warning, .blocking]
            guard let l = order.firstIndex(of: lhs), let r = order.firstIndex(of: rhs) else { return false }
            return l < r
        }
    }

    public var id: UUID
    public var kind: Kind
    public var severity: Severity
    /// Human-readable detail for the review screen and the debug inspector.
    public var detail: String
    /// Hole numbers this warning refers to, when applicable.
    public var holeNumbers: [Int]

    public init(
        id: UUID = UUID(),
        kind: Kind,
        severity: Severity,
        detail: String,
        holeNumbers: [Int] = []
    ) {
        self.id = id
        self.kind = kind
        self.severity = severity
        self.detail = detail
        self.holeNumbers = holeNumbers
    }
}
