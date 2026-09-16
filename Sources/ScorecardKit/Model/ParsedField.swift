import Foundation

/// Where a value came from. Provenance is kept for every meaningful field because the product rule
/// "never turn uncertainty into fake data" is only enforceable if the origin of each value survives all
/// the way to the review screen.
public enum FieldProvenance: String, Codable, Sendable, CaseIterable {
    /// Restored from a verified `CourseTemplate` after the course was confidently identified.
    /// **Only ever valid for static course data.** Never for a player's score.
    case verifiedCourseTemplate
    /// Read directly from the photograph by on-device OCR.
    case ocr
    /// Not read directly, but implied by the reconstructed table (e.g. a hole number implied by its column).
    case inferredFromLayout
    /// Returned by an optional remote multimodal parser.
    case multimodalFallback
    /// Derived arithmetically from a subtotal the golfer wrote on their own card.
    ///
    /// When a nine has exactly one unreadable score and the golfer wrote an OUT or IN total, that total
    /// determines the missing stroke count exactly. This is still the golfer's own data — their
    /// handwriting, just in a different cell — which is why it is permitted for a score where
    /// `verifiedCourseTemplate` is not. Kept distinct from `.ocr` so the review screen can say where the
    /// number came from, and so a wrong subtotal is traceable rather than indistinguishable from a read.
    case solvedFromSubtotal
    /// Typed or corrected by the golfer. Always wins.
    case userEdited
    /// No value.
    case none

    /// Whether a value of this provenance is allowed to be a player's score.
    ///
    /// This is the single enforcement point for the product's hardest rule: a template knows what par is,
    /// but it can never know what the golfer shot.
    public var isPermittedForPlayerScore: Bool {
        switch self {
        case .ocr, .multimodalFallback, .solvedFromSubtotal, .userEdited, .none:
            return true
        case .verifiedCourseTemplate, .inferredFromLayout:
            return false
        }
    }
}

/// A coarse confidence bucket used for UI decisions.
public enum ConfidenceLevel: String, Codable, Sendable, Comparable, CaseIterable {
    case none
    case low
    case medium
    case high

    public static func < (lhs: ConfidenceLevel, rhs: ConfidenceLevel) -> Bool {
        let order: [ConfidenceLevel] = [.none, .low, .medium, .high]
        guard let l = order.firstIndex(of: lhs), let r = order.firstIndex(of: rhs) else { return false }
        return l < r
    }

    public init(score: Double) {
        switch score {
        case ..<0.01: self = .none
        case ..<0.55: self = .low
        case ..<0.82: self = .medium
        default: self = .high
        }
    }
}

/// A parsed value carrying its own confidence and provenance.
///
/// `value` is optional on purpose: a missing value is a legitimate, representable outcome and is always
/// preferred over a guess.
public struct ParsedField<Value: Codable & Hashable & Sendable>: Codable, Hashable, Sendable {
    public var value: Value?
    /// `0...1`.
    public var confidence: Double
    public var provenance: FieldProvenance
    /// The raw OCR string this value was read from, kept for the debug inspector and the review screen.
    public var rawText: String?

    public init(value: Value?, confidence: Double, provenance: FieldProvenance, rawText: String? = nil) {
        self.value = value
        self.confidence = max(0, min(1, confidence))
        self.provenance = provenance
        self.rawText = rawText
    }

    /// An explicitly empty field.
    public static var empty: ParsedField<Value> {
        ParsedField(value: nil, confidence: 0, provenance: .none)
    }

    public static func ocr(_ value: Value?, confidence: Double, rawText: String? = nil) -> ParsedField<Value> {
        ParsedField(value: value, confidence: confidence, provenance: .ocr, rawText: rawText)
    }

    public static func template(_ value: Value) -> ParsedField<Value> {
        ParsedField(value: value, confidence: 1.0, provenance: .verifiedCourseTemplate)
    }

    public static func layout(_ value: Value, confidence: Double = 0.9) -> ParsedField<Value> {
        ParsedField(value: value, confidence: confidence, provenance: .inferredFromLayout)
    }

    public static func userEdited(_ value: Value?) -> ParsedField<Value> {
        ParsedField(value: value, confidence: 1.0, provenance: .userEdited)
    }

    /// A value the golfer's own written subtotal determines exactly.
    ///
    /// Confidence is high but deliberately short of 1.0: the arithmetic is certain only if the subtotal
    /// itself was read correctly, so this stays distinguishable from a value the golfer typed.
    public static func solvedFromSubtotal(_ value: Value, confidence: Double = 0.93) -> ParsedField<Value> {
        ParsedField(value: value, confidence: confidence, provenance: .solvedFromSubtotal)
    }

    public var level: ConfidenceLevel {
        value == nil ? .none : ConfidenceLevel(score: confidence)
    }

    /// True when the field should be surfaced for human confirmation.
    public var requiresReview: Bool {
        if provenance == .userEdited { return false }
        if value == nil { return true }
        return confidence < 0.82
    }

    public var hasValue: Bool { value != nil }
}
