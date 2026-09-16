import Foundation
import XCTest
@testable import ScorecardKit

/// Shared helpers for the parser tests.
///
/// Every test here runs against synthetic OCR observations rather than stored images. That is a deliberate
/// choice, not a shortcut: a test needs to say "hole 16's yardage was misread as `33B` and the stroke index
/// for hole 5 came back as `l7`", and no recognizer can be asked for that. Building the observations
/// directly makes the failure modes addressable one at a time.
enum ParserTestSupport {

    /// A realistic round at Steel Canyon: a few over par on an executive course.
    static let steelCanyonScores: [Int?] = [
        5, 4, 3, 4, 3, 6, 3, 4, 3,
        4, 5, 3, 3, 4, 5, 4, 3, 4
    ]

    /// The full Georgia catalog, which is what the app hands the matcher.
    static var catalog: [CourseTemplate] { GeorgiaCourseCatalog.templates }

    static func parse(
        _ card: ScorecardFixtureBuilder.Card,
        templates: [CourseTemplate]? = nil,
        forcedTemplateID: String? = nil,
        forcedTeeName: String? = nil,
        collectsDebugReport: Bool = false
    ) async throws -> ParsedScorecard {
        try await outcome(
            card,
            templates: templates,
            forcedTemplateID: forcedTemplateID,
            forcedTeeName: forcedTeeName,
            collectsDebugReport: collectsDebugReport
        ).scorecard
    }

    static func outcome(
        _ card: ScorecardFixtureBuilder.Card,
        templates: [CourseTemplate]? = nil,
        forcedTemplateID: String? = nil,
        forcedTeeName: String? = nil,
        collectsDebugReport: Bool = false
    ) async throws -> ScorecardParseOutcome {
        let parser = DefaultScorecardParser()
        let request = ScorecardParseRequest(
            observations: ScorecardFixtureBuilder.build(card),
            templates: templates ?? catalog,
            forcedTemplateID: forcedTemplateID,
            forcedTeeName: forcedTeeName,
            collectsDebugReport: collectsDebugReport
        )
        return try await parser.parse(request)
    }

    static func table(_ card: ScorecardFixtureBuilder.Card) -> DetectedTable {
        ScorecardLayoutDetector().detectTable(from: ScorecardFixtureBuilder.build(card))
    }

    /// A clean nine-hole card for a course that is deliberately *not* in the Georgia catalog.
    static func nineHoleCard(
        playerScores: [Int?] = [5, 3, 6, 4, 5, 4, 3, 5, 4],
        courseName: String = "PINE NINE GOLF COURSE"
    ) -> ScorecardFixtureBuilder.Card {
        ScorecardFixtureBuilder.Card(
            titleLines: [courseName],
            holeNumbers: Array(1...9),
            rows: [
                ScorecardFixtureBuilder.Row
                    .printed(label: "WHITE", values: [310, 145, 402, 168, 355, 290, 175, 388, 330].map { Optional($0) })
                    .withTotals(out: 2563, inward: nil, total: 2563),
                ScorecardFixtureBuilder.Row
                    .printed(label: "PAR", values: [4, 3, 4, 3, 4, 4, 3, 4, 4].map { Optional($0) })
                    .withTotals(out: 33, inward: nil, total: 33),
                ScorecardFixtureBuilder.Row
                    .printed(label: "HCP", values: [3, 9, 1, 7, 5, 4, 8, 2, 6].map { Optional($0) }),
                ScorecardFixtureBuilder.Row.handwritten(label: "SAM", values: playerScores)
            ],
            layout: .singleBand
        )
    }

    /// Finds the row the detector assigned a given role.
    static func rows(in table: DetectedTable, matching predicate: (ScorecardRowRole) -> Bool) -> [DetectedRow] {
        table.rows.filter { predicate($0.role) }
    }
}

extension ParsedScorecard {
    /// Scores keyed by hole number, for readable assertions.
    var scoresByHole: [Int: Int?] {
        Dictionary(uniqueKeysWithValues: holes.map { ($0.holeNumber, $0.playerScore.value) })
    }
}
