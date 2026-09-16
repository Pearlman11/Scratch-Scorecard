import Foundation

/// One hole as parsed from a card. Every field carries its own confidence and provenance.
public struct ParsedHole: Codable, Hashable, Sendable, Identifiable {
    public var id: Int { holeNumber }
    public var holeNumber: Int
    public var yardage: ParsedField<Int>
    public var par: ParsedField<Int>
    /// The hole's stroke index — the "HCP" column printed beside the hole.
    /// Not the golfer's personal handicap index, which this app does not model.
    public var handicapIndex: ParsedField<Int>
    /// The golfer's score. May legitimately be `nil`: an unread or unplayed hole is data, not an error.
    public var playerScore: ParsedField<Int>

    public init(
        holeNumber: Int,
        yardage: ParsedField<Int> = .empty,
        par: ParsedField<Int> = .empty,
        handicapIndex: ParsedField<Int> = .empty,
        playerScore: ParsedField<Int> = .empty
    ) {
        self.holeNumber = holeNumber
        self.yardage = yardage
        self.par = par
        self.handicapIndex = handicapIndex
        self.playerScore = playerScore
    }

    /// True when the golfer should look at this hole's score before saving.
    public var scoreNeedsReview: Bool { playerScore.requiresReview }

    public var relativeToPar: Int? {
        guard let score = playerScore.value, let par = par.value else { return nil }
        return score - par
    }
}

/// A row of scores attributed to one golfer.
public struct DetectedPlayer: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    /// Name as written on the card, when legible.
    public var name: String?
    /// Fallback label, e.g. `Player 2`, used when the name could not be read.
    public var fallbackLabel: String
    /// Which detected row these scores came from, for the debug inspector.
    public var sourceRowIndex: Int?
    /// Score per hole, index 0 == hole 1.
    public var scores: [ParsedField<Int>]
    /// How confident the parser is that this row is a golfer's scores at all.
    public var rowConfidence: Double

    public init(
        id: UUID = UUID(),
        name: String? = nil,
        fallbackLabel: String,
        sourceRowIndex: Int? = nil,
        scores: [ParsedField<Int>],
        rowConfidence: Double
    ) {
        self.id = id
        self.name = name
        self.fallbackLabel = fallbackLabel
        self.sourceRowIndex = sourceRowIndex
        self.scores = scores
        self.rowConfidence = rowConfidence
    }

    public var displayName: String { name ?? fallbackLabel }

    public var holesWithScores: Int {
        scores.filter { $0.hasValue }.count
    }

    public var scoreValues: [Int?] { scores.map(\.value) }
}

/// Overall quality of a parse, used to decide how much of the review screen to pre-open.
public enum ParseQuality: String, Codable, Sendable {
    /// Course identified, static data complete, most scores read confidently.
    case readyToReview
    /// Usable, but several values need the golfer's attention.
    case needsAttention
    /// Structure recovered but the course is unknown or scores are largely missing.
    case needsManualEntry
    /// Nothing usable was recovered.
    case failed
}

/// The parser's output. A single strongly-typed value carrying the parse, its confidence, and everything
/// needed to review and correct it.
public struct ParsedScorecard: Codable, Sendable {
    public var id: UUID

    // Course identification.
    public var candidateCourse: CourseIdentity?
    /// The layout name when the facility has several, e.g. `Stonemont`.
    public var candidateLayoutName: String?
    public var candidateTee: String?
    /// How confident the parser is in `candidateTee`. Low is common and expected: a card prints every tee
    /// it offers, so the tee is usually a provisional default the golfer confirms in one tap.
    public var teeConfidence: Double
    public var courseConfidence: Double
    /// Set when identification was ambiguous. The golfer chooses; the app must not choose for them.
    public var alternateCourseIDs: [String]
    /// The template used to restore static data, if any.
    public var appliedTemplateID: String?
    public var appliedTemplateVersion: Int?

    // Content.
    public var holeCount: Int
    public var holes: [ParsedHole]
    public var detectedPlayers: [DetectedPlayer]
    /// Which detected player the golfer said is them. `nil` until chosen when there is more than one.
    public var selectedPlayerID: UUID?

    // Quality.
    public var warnings: [ParseWarning]
    public var overallConfidence: Double
    public var quality: ParseQuality

    // Provenance of the parse itself.
    public var parserName: String
    public var parserVersion: String
    public var parsedAt: Date

    public init(
        id: UUID = UUID(),
        candidateCourse: CourseIdentity? = nil,
        candidateLayoutName: String? = nil,
        candidateTee: String? = nil,
        teeConfidence: Double = 0,
        courseConfidence: Double = 0,
        alternateCourseIDs: [String] = [],
        appliedTemplateID: String? = nil,
        appliedTemplateVersion: Int? = nil,
        holeCount: Int = 0,
        holes: [ParsedHole] = [],
        detectedPlayers: [DetectedPlayer] = [],
        selectedPlayerID: UUID? = nil,
        warnings: [ParseWarning] = [],
        overallConfidence: Double = 0,
        quality: ParseQuality = .failed,
        parserName: String = "VisionScorecardParser",
        parserVersion: String = ParserVersion.current,
        parsedAt: Date = Date()
    ) {
        self.id = id
        self.candidateCourse = candidateCourse
        self.candidateLayoutName = candidateLayoutName
        self.candidateTee = candidateTee
        self.teeConfidence = teeConfidence
        self.courseConfidence = courseConfidence
        self.alternateCourseIDs = alternateCourseIDs
        self.appliedTemplateID = appliedTemplateID
        self.appliedTemplateVersion = appliedTemplateVersion
        self.holeCount = holeCount
        self.holes = holes
        self.detectedPlayers = detectedPlayers
        self.selectedPlayerID = selectedPlayerID
        self.warnings = warnings
        self.overallConfidence = overallConfidence
        self.quality = quality
        self.parserName = parserName
        self.parserVersion = parserVersion
        self.parsedAt = parsedAt
    }

    public var selectedPlayer: DetectedPlayer? {
        guard let selectedPlayerID else { return detectedPlayers.count == 1 ? detectedPlayers.first : nil }
        return detectedPlayers.first { $0.id == selectedPlayerID }
    }

    public var pars: [Int?] { holes.map(\.par.value) }
    public var scores: [Int?] { holes.map(\.playerScore.value) }

    public var totals: ScoreTotals {
        ScoreMath.totals(scores: scores, pars: pars, holeCount: holeCount)
    }

    /// Hole numbers whose score the golfer should check before saving.
    public var holesNeedingReview: [Int] {
        holes.filter(\.scoreNeedsReview).map(\.holeNumber)
    }

    public func warnings(ofKind kind: ParseWarning.Kind) -> [ParseWarning] {
        warnings.filter { $0.kind == kind }
    }

    public var hasBlockingWarning: Bool {
        warnings.contains { $0.severity == .blocking }
    }

    /// True when the golfer should confirm the tee before saving.
    public var teeNeedsConfirmation: Bool {
        candidateTee == nil || teeConfidence < 0.6
    }

    /// Replaces one hole's score and marks it as the golfer's own edit.
    ///
    /// Edits always land with `.userEdited` provenance, which is what makes them immune to any later
    /// template application and removes them from the review list.
    public mutating func setScore(_ value: Int?, forHole holeNumber: Int) {
        guard let index = holes.firstIndex(where: { $0.holeNumber == holeNumber }) else { return }
        holes[index].playerScore = .userEdited(value)
        if let playerIndex = detectedPlayers.firstIndex(where: { $0.id == selectedPlayer?.id }),
           detectedPlayers[playerIndex].scores.indices.contains(holeNumber - 1) {
            detectedPlayers[playerIndex].scores[holeNumber - 1] = .userEdited(value)
        }
    }

    /// Adopts a detected player's scores as the golfer's own.
    public mutating func selectPlayer(id: UUID) {
        guard let player = detectedPlayers.first(where: { $0.id == id }) else { return }
        selectedPlayerID = id
        for index in holes.indices {
            let holeIndex = holes[index].holeNumber - 1
            holes[index].playerScore = player.scores.indices.contains(holeIndex)
                ? player.scores[holeIndex]
                : .empty
        }
    }
}

public enum ParserVersion {
    public static let current = "1.0.0"
}
