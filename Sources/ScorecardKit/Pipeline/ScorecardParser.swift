import Foundation

/// Input to a parse that starts from already-recognized text.
///
/// The parser is defined over *observations*, not images. That boundary is what makes the hard part of this
/// product testable: layout reconstruction, course matching and score extraction can all be exercised
/// against hand-built fixtures with realistic OCR damage, on any platform, without running Vision.
public struct ScorecardParseRequest: Sendable {
    public var observations: [TextObservation]
    /// Templates the matcher may consider. The app passes the Georgia catalog plus learned templates.
    public var templates: [CourseTemplate]
    /// Set when the golfer has already told us the course, e.g. after correcting a wrong match.
    /// Identification is then skipped and this template is used directly.
    public var forcedTemplateID: String?
    /// Set when the golfer has already chosen a tee.
    public var forcedTeeName: String?
    /// Collect the debug report. Off by default so normal scans do not pay for it.
    public var collectsDebugReport: Bool

    public init(
        observations: [TextObservation],
        templates: [CourseTemplate],
        forcedTemplateID: String? = nil,
        forcedTeeName: String? = nil,
        collectsDebugReport: Bool = false
    ) {
        self.observations = observations
        self.templates = templates
        self.forcedTemplateID = forcedTemplateID
        self.forcedTeeName = forcedTeeName
        self.collectsDebugReport = collectsDebugReport
    }
}

/// A finished parse plus its optional debug report.
public struct ScorecardParseOutcome: Sendable {
    public var scorecard: ParsedScorecard
    public var debugReport: ParserDebugReport?

    public init(scorecard: ParsedScorecard, debugReport: ParserDebugReport? = nil) {
        self.scorecard = scorecard
        self.debugReport = debugReport
    }
}

/// Parses recognized text into a scorecard.
///
/// Expressed as a protocol so the Vision-backed path, a fixture-backed test path and a future remote
/// multimodal path are interchangeable, and so the app depends on the capability rather than on Vision.
public protocol ScorecardParsing: Sendable {
    func parse(_ request: ScorecardParseRequest) async throws -> ScorecardParseOutcome
}

public enum ScorecardParsingError: Error, LocalizedError, Sendable {
    case noTextRecognized
    case imageUnreadable(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .noTextRecognized:
            return "No text could be read from this photo. Try again with more even lighting and the whole card in frame."
        case .imageUnreadable(let detail):
            return "This image could not be processed: \(detail)"
        case .cancelled:
            return "Scanning was cancelled."
        }
    }
}
