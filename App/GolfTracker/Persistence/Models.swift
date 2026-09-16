import Foundation
import SwiftData
import ScorecardKit

// MARK: - Course

/// A playable layout, and the map pin that represents it.
///
/// One record per *layout*, not per facility: Stone Mountain's Stonemont and Lakemont are separate courses
/// here because a golfer plays a layout and a scorecard identifies a layout.
@Model
final class Course {
    /// Matches the seed catalog's template ID, so a scan can resolve straight to a stored course.
    @Attribute(.unique) var catalogID: String
    var name: String
    var layoutName: String?
    var facilityName: String
    var city: String
    var state: String
    var holeCount: Int
    /// Resolved by `MKLocalSearch` and validated against Georgia's bounds. Never hand-typed.
    var latitude: Double?
    var longitude: Double?
    /// Set when the golfer marks the course played on the map without saving a round.
    var manuallyMarkedPlayedAt: Date?

    @Relationship(deleteRule: .cascade, inverse: \Round.course)
    var rounds: [Round] = []

    @Relationship(deleteRule: .cascade, inverse: \StoredCourseTemplate.course)
    var storedTemplate: StoredCourseTemplate?

    init(
        catalogID: String,
        name: String,
        layoutName: String? = nil,
        facilityName: String,
        city: String,
        state: String = "GA",
        holeCount: Int = 0,
        latitude: Double? = nil,
        longitude: Double? = nil
    ) {
        self.catalogID = catalogID
        self.name = name
        self.layoutName = layoutName
        self.facilityName = facilityName
        self.city = city
        self.state = state
        self.holeCount = holeCount
        self.latitude = latitude
        self.longitude = longitude
    }

    var displayName: String {
        guard let layoutName else { return name }
        return "\(name) — \(layoutName)"
    }

    /// Whether the map should show this course as scratched off.
    ///
    /// Playing a round marks a course played automatically; scratching it by hand does the same without a
    /// round. The two are kept as separate facts so a manual scratch never fabricates a round, and a round
    /// is never lost by un-scratching.
    var isPlayed: Bool {
        manuallyMarkedPlayedAt != nil || !rounds.isEmpty
    }

    var hasCoordinates: Bool { latitude != nil && longitude != nil }

    var roundsNewestFirst: [Round] {
        rounds.sorted { $0.datePlayed > $1.datePlayed }
    }

    var bestRound: Round? {
        rounds.filter { $0.totalScore != nil }.min { ($0.totalScore ?? .max) < ($1.totalScore ?? .max) }
    }
}

// MARK: - Template

/// A course's hole-level data, stored so learned templates survive relaunches.
///
/// The authoritative shape of a template is `ScorecardKit.CourseTemplate`, a value type. This record wraps
/// an encoded copy rather than re-modelling every field as SwiftData properties: the matcher consumes the
/// value type, and keeping one definition means a template cannot drift between the two representations.
@Model
final class StoredCourseTemplate {
    var catalogID: String
    var verificationRaw: String
    var templateVersion: Int
    var updatedAt: Date
    /// JSON-encoded `CourseTemplate`.
    var payload: Data
    var course: Course?

    init(template: CourseTemplate, course: Course?) throws {
        self.catalogID = template.id
        self.verificationRaw = template.verification.rawValue
        self.templateVersion = template.templateVersion
        self.updatedAt = Date()
        self.payload = try JSONEncoder().encode(template)
        self.course = course
    }

    func decoded() throws -> CourseTemplate {
        try JSONDecoder().decode(CourseTemplate.self, from: payload)
    }

    func update(with template: CourseTemplate) throws {
        payload = try JSONEncoder().encode(template)
        verificationRaw = template.verification.rawValue
        templateVersion = template.templateVersion
        updatedAt = Date()
    }
}

// MARK: - Round

/// A saved round.
@Model
final class Round {
    @Attribute(.unique) var id: UUID
    var datePlayed: Date
    var createdAt: Date
    var updatedAt: Date

    var course: Course?
    /// Layout name at the time of saving, kept even if the course record later changes.
    var layoutName: String?
    var teeName: String?

    var frontNineScore: Int?
    var backNineScore: Int?
    var totalScore: Int?
    var scoreRelativeToPar: Int?
    var coursePar: Int?
    var holeCount: Int

    /// `0...1` from the parse this round was created from.
    var parserConfidence: Double
    var parserName: String
    var parserVersion: String
    /// The template ID and version the static data came from, so a later template correction is traceable.
    var appliedTemplateID: String?
    var appliedTemplateVersion: Int?
    var playerName: String?
    var notes: String?

    @Relationship(deleteRule: .cascade, inverse: \HoleScore.round)
    var holeScores: [HoleScore] = []

    @Relationship(deleteRule: .cascade, inverse: \ScorecardImageRef.round)
    var scorecardImage: ScorecardImageRef?

    init(
        id: UUID = UUID(),
        datePlayed: Date,
        course: Course?,
        layoutName: String? = nil,
        teeName: String?,
        holeCount: Int,
        parserConfidence: Double,
        parserName: String,
        parserVersion: String,
        appliedTemplateID: String? = nil,
        appliedTemplateVersion: Int? = nil,
        playerName: String? = nil
    ) {
        self.id = id
        self.datePlayed = datePlayed
        self.createdAt = Date()
        self.updatedAt = Date()
        self.course = course
        self.layoutName = layoutName
        self.teeName = teeName
        self.holeCount = holeCount
        self.parserConfidence = parserConfidence
        self.parserName = parserName
        self.parserVersion = parserVersion
        self.appliedTemplateID = appliedTemplateID
        self.appliedTemplateVersion = appliedTemplateVersion
        self.playerName = playerName
    }

    var holeScoresInOrder: [HoleScore] {
        holeScores.sorted { $0.holeNumber < $1.holeNumber }
    }

    var isComplete: Bool { totalScore != nil }

    /// Recomputes every total from the stored hole scores.
    ///
    /// Totals are stored rather than derived on read so the rounds list and map can sort and summarise
    /// without loading every hole, but they are always recomputed from the holes — never edited directly.
    func recalculateTotals() {
        let ordered = holeScoresInOrder
        let scores: [Int?] = (1...max(1, holeCount)).map { number in
            ordered.first { $0.holeNumber == number }?.strokes
        }
        let pars: [Int?] = (1...max(1, holeCount)).map { number in
            ordered.first { $0.holeNumber == number }?.par
        }
        let totals = ScoreMath.totals(scores: scores, pars: pars, holeCount: holeCount)
        frontNineScore = totals.front
        backNineScore = totals.back
        totalScore = totals.total
        scoreRelativeToPar = totals.relativeToPar
        coursePar = pars.compactMap { $0 }.count == holeCount ? pars.compactMap { $0 }.reduce(0, +) : nil
        updatedAt = Date()
    }

    var summaryLine: String {
        var parts: [String] = []
        if let totalScore { parts.append("\(totalScore)") }
        if let scoreRelativeToPar { parts.append("(\(ScoreMath.formatRelativeToPar(scoreRelativeToPar)))") }
        if let teeName { parts.append("· \(teeName)") }
        return parts.isEmpty ? "Incomplete round" : parts.joined(separator: " ")
    }
}

// MARK: - Hole score

/// One hole of a saved round.
///
/// Static fields (`par`, `handicapIndex`, `yardage`) are denormalized onto the round on purpose: a round is
/// a historical record, and it must still render correctly if the course's template is later corrected or
/// the course is deleted.
@Model
final class HoleScore {
    var holeNumber: Int
    /// `nil` for a hole not played. A blank hole is data, not a gap to fill.
    var strokes: Int?
    var par: Int?
    var handicapIndex: Int?
    var yardage: Int?
    /// Raw value of `FieldProvenance` for the score, so the history can show what was read versus typed.
    var scoreProvenanceRaw: String
    var scoreConfidence: Double
    var round: Round?

    init(
        holeNumber: Int,
        strokes: Int?,
        par: Int?,
        handicapIndex: Int?,
        yardage: Int?,
        scoreProvenance: FieldProvenance,
        scoreConfidence: Double
    ) {
        self.holeNumber = holeNumber
        self.strokes = strokes
        self.par = par
        self.handicapIndex = handicapIndex
        self.yardage = yardage
        self.scoreProvenanceRaw = scoreProvenance.rawValue
        self.scoreConfidence = scoreConfidence
    }

    var scoreProvenance: FieldProvenance {
        FieldProvenance(rawValue: scoreProvenanceRaw) ?? .none
    }

    var relativeToPar: Int? {
        guard let strokes, let par else { return nil }
        return strokes - par
    }
}

// MARK: - Image reference

/// A pointer to the scorecard photograph on disk.
///
/// The bytes live in the app's Application Support directory and only the filename is stored here. A
/// full-resolution scorecard photo is several megabytes; putting those in the store would make every query
/// that touches a round drag them along, and would make the store unusable to sync later.
@Model
final class ScorecardImageRef {
    @Attribute(.unique) var id: UUID
    /// Filename of the golfer's untouched photograph.
    var originalFilename: String
    /// Filename of the processed image the parser used. Kept for the debug inspector; safe to lose.
    var normalizedFilename: String?
    var capturedAt: Date
    var pixelWidth: Int
    var pixelHeight: Int
    var round: Round?

    init(
        id: UUID = UUID(),
        originalFilename: String,
        normalizedFilename: String?,
        capturedAt: Date = Date(),
        pixelWidth: Int,
        pixelHeight: Int
    ) {
        self.id = id
        self.originalFilename = originalFilename
        self.normalizedFilename = normalizedFilename
        self.capturedAt = capturedAt
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }
}

// MARK: - Course visit

/// A "played" marker that is not a round.
///
/// Rounds and played-state are deliberately separate concepts: a golfer can scratch a course off the map
/// after playing it without a card, and that must never manufacture an empty round in their history.
@Model
final class CourseVisit {
    @Attribute(.unique) var id: UUID
    var courseCatalogID: String
    var visitedAt: Date
    /// How the course came to be marked played.
    var sourceRaw: String

    enum Source: String, Codable {
        case savedRound
        case manualScratch
    }

    init(id: UUID = UUID(), courseCatalogID: String, visitedAt: Date = Date(), source: Source) {
        self.id = id
        self.courseCatalogID = courseCatalogID
        self.visitedAt = visitedAt
        self.sourceRaw = source.rawValue
    }

    var source: Source { Source(rawValue: sourceRaw) ?? .manualScratch }
}

/// Everything the store persists.
enum GolfTrackerSchema {
    static let models: [any PersistentModel.Type] = [
        Course.self,
        StoredCourseTemplate.self,
        Round.self,
        HoleScore.self,
        ScorecardImageRef.self,
        CourseVisit.self
    ]
}
