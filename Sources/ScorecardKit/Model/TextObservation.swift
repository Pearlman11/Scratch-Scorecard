import Foundation

/// Which recognition pass produced an observation.
///
/// The parser runs more than one OCR configuration over the same card because the two kinds of text on a
/// scorecard want opposite settings: course names benefit from language correction, while a yardage of
/// `171` gets "corrected" into a word by the very same setting. Keeping the source lets downstream code
/// prefer the right pass per token instead of averaging two passes into mush.
public enum OCRPass: String, Codable, Sendable, CaseIterable {
    /// Full-card pass with language correction on. Best for course names, tee names, row labels.
    case languageCorrected
    /// Full-card pass with language correction off. Best for digits.
    case numeric
    /// A targeted re-read of a single cropped cell, usually a low-confidence handwritten score.
    case targetedCell
    /// Supplied by a test fixture or a debug import.
    case synthetic
}

/// One recognized piece of text plus everything spatial we know about it.
///
/// A scorecard is a table, so the *position* of a token carries as much meaning as its characters: `3` in
/// the par row and `3` in a player row are the same string and completely different facts. Nothing in this
/// kit is allowed to reduce OCR output to a bag of strings.
public struct TextObservation: Hashable, Codable, Sendable, Identifiable {
    public var id: UUID
    /// The recognized string, exactly as OCR produced it (never cleaned up in place).
    public var text: String
    /// Bounding box in normalized card space, top-left origin.
    public var rect: CardRect
    /// Vision's own confidence for the top candidate, `0...1`.
    public var confidence: Double
    public var pass: OCRPass
    /// Lower-ranked candidates from the same recognition, best first. Used to recover from a
    /// misread when the top candidate disagrees with strong structural evidence.
    public var alternativeTexts: [String]

    public init(
        id: UUID = UUID(),
        text: String,
        rect: CardRect,
        confidence: Double,
        pass: OCRPass = .synthetic,
        alternativeTexts: [String] = []
    ) {
        self.id = id
        self.text = text
        self.rect = rect
        self.confidence = confidence
        self.pass = pass
        self.alternativeTexts = alternativeTexts
    }

    /// Whitespace-trimmed text.
    public var trimmed: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Uppercased, punctuation-stripped text for label matching.
    public var normalizedLabel: String {
        TextNormalizer.normalizeLabel(text)
    }

    /// True when the token is made mostly of digits (letters that are common digit misreads count).
    public var looksNumeric: Bool {
        let candidates = NumericOCR.integerCandidates(from: trimmed)
        return !candidates.isEmpty
    }

    public func rotated(by radians: Double, around pivot: (x: Double, y: Double)) -> TextObservation {
        var copy = self
        copy.rect = rect.rotatingCenter(by: radians, around: pivot)
        return copy
    }
}

public enum TextNormalizer {
    /// Uppercases and strips everything that is not a letter or digit.
    ///
    /// Scorecards print labels as `HCP.`, `H'CAP`, `S.I.` and so on; comparing raw strings would need a
    /// synonym entry per punctuation variant.
    public static func normalizeLabel(_ raw: String) -> String {
        let upper = raw.uppercased()
        let filtered = upper.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
        return String(String.UnicodeScalarView(filtered))
    }

    /// Lowercases, strips diacritics and collapses runs of non-alphanumerics into single spaces.
    /// Used for course-name comparison, where `Bear's Best` and `Bears Best` must match.
    public static func normalizeName(_ raw: String) -> String {
        let folded = raw.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US"))
        var out = ""
        var lastWasSpace = true
        for scalar in folded.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                out.unicodeScalars.append(scalar)
                lastWasSpace = false
            } else if !lastWasSpace {
                out.append(" ")
                lastWasSpace = true
            }
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    /// Words that carry no identifying signal when comparing golf course names.
    static let courseNameStopWords: Set<String> = [
        "golf", "club", "course", "links", "the", "at", "of", "and", "cc",
        "country", "gc", "g", "c", "national", "resort"
    ]

    /// Significant tokens of a course name, stop words removed. Falls back to all tokens when the name is
    /// made entirely of stop words (e.g. a literal "Golf Club" heading).
    public static func significantNameTokens(_ raw: String) -> [String] {
        let tokens = normalizeName(raw).split(separator: " ").map(String.init)
        let significant = tokens.filter { !courseNameStopWords.contains($0) && $0.count > 1 }
        return significant.isEmpty ? tokens : significant
    }
}
