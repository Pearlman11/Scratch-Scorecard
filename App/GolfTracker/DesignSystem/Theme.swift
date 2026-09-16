import SwiftUI
import ScorecardKit

/// The app's visual vocabulary.
///
/// Two constraints drive everything here: the screen is read outdoors in sunlight, and the golfer is
/// correcting numbers with one hand. That means high contrast, generous hit targets, and colour used to
/// mean something — never for decoration.
enum Theme {

    // MARK: - Colour

    /// Deep fairway green. The single accent.
    static let accent = Color(red: 0.05, green: 0.38, blue: 0.22)

    /// Background for the scorecard grid's static (course) rows.
    static func staticRowBackground(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.06) : Color.black.opacity(0.035)
    }

    /// Colour for a parsed value, chosen by how much the golfer should trust it.
    ///
    /// Confidence is communicated with colour *and* a symbol, never colour alone: red-green is the most
    /// common colour-vision deficiency and this app's whole point is distinguishing "read this" from
    /// "trust this".
    static func confidenceTint(_ level: ConfidenceLevel, scheme: ColorScheme) -> Color {
        switch level {
        case .high: return .primary
        case .medium: return scheme == .dark ? Color(white: 0.75) : Color(white: 0.32)
        case .low, .none: return .orange
        }
    }

    // MARK: - Metrics

    /// Minimum tap target, matching Apple's 44pt guidance. Score cells are edited on a course, in wind.
    static let minimumTapTarget: CGFloat = 44
    static let cornerRadius: CGFloat = 12
    static let cardPadding: CGFloat = 16

    /// Monospaced digits so a column of scores lines up whatever the values are.
    static let scoreFont = Font.system(.body, design: .rounded).monospacedDigit().weight(.semibold)
    static let staticCellFont = Font.system(.footnote, design: .rounded).monospacedDigit()
    static let columnHeaderFont = Font.system(.caption2, design: .rounded).weight(.semibold)
}

extension ConfidenceLevel {
    /// A shape that carries the same meaning as the tint, for anyone who cannot rely on colour.
    var symbolName: String? {
        switch self {
        case .high: return nil
        case .medium: return "questionmark.circle"
        case .low: return "exclamationmark.triangle.fill"
        case .none: return "circle.dashed"
        }
    }

    var accessibilityDescription: String {
        switch self {
        case .high: return "read clearly"
        case .medium: return "check this value"
        case .low: return "hard to read, please check"
        case .none: return "not read, please enter"
        }
    }
}

extension ParseWarning.Severity {
    var symbolName: String {
        switch self {
        case .info: return "info.circle"
        case .warning: return "exclamationmark.triangle"
        case .blocking: return "xmark.octagon"
        }
    }

    var tint: Color {
        switch self {
        case .info: return .secondary
        case .warning: return .orange
        case .blocking: return .red
        }
    }
}
