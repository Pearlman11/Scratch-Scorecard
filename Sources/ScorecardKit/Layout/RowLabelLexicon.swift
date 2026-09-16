import Foundation

/// The semantic meaning of a reconstructed table row.
///
/// The split between static course data and player data is encoded here rather than discovered later,
/// because "which row is this?" is the decision that everything downstream depends on. A par row read as a
/// player row would put a template's par into a golfer's score.
public enum ScorecardRowRole: Hashable, Codable, Sendable {
    /// The row carrying hole numbers `1...9` or `1...18`.
    case holeHeader
    /// Printed par per hole.
    case par
    /// Printed stroke index per hole (the "HCP" column).
    case handicap
    /// Printed yardages for one tee set. `teeName` is the label as printed, when readable.
    case yardage(teeName: String?)
    /// A golfer's scores. `name` is the written name when readable.
    case playerScores(name: String?)
    /// A row of ratings/slope or other per-tee metadata with no per-hole values.
    case metadata
    case unknown

    /// True when the row holds printed course data that a verified template may correct.
    public var isStaticCourseData: Bool {
        switch self {
        case .holeHeader, .par, .handicap, .yardage:
            return true
        case .playerScores, .metadata, .unknown:
            return false
        }
    }

    public var isPlayerData: Bool {
        if case .playerScores = self { return true }
        return false
    }
}

/// Label synonyms seen on real scorecards.
///
/// Matching is done on `TextNormalizer.normalizeLabel` output (uppercase, alphanumerics only), so `HCP.`,
/// `H-CAP` and `S.I.` all collapse onto entries here without needing a row per punctuation variant.
public enum RowLabelLexicon {

    public static let holeSynonyms: Set<String> = [
        "HOLE", "HOLES", "HOLENO", "HOLENUMBER", "HOLE1", "H"
    ]

    public static let parSynonyms: Set<String> = [
        "PAR", "PARS", "MENSPAR", "PARMEN", "MENPAR", "LADIESPAR", "WOMENSPAR", "PARWOMEN"
    ]

    /// The printed "HCP" column: the hole's stroke index.
    /// Never the golfer's personal handicap index, which this app does not model.
    public static let handicapSynonyms: Set<String> = [
        "HCP", "HDCP", "HDP", "HCAP", "HANDICAP", "HANDICAPS", "SI", "STROKEINDEX",
        "STROKE", "INDEX", "MENSHCP", "HCPMEN", "MENHCP", "HANDICAPMEN", "STROKE INDEX"
    ]

    public static let outSynonyms: Set<String> = [
        "OUT", "FRONT", "FRONT9", "FRONTNINE", "FRONT9TOTAL", "OUT9", "FRONTTOTAL"
    ]

    public static let inSynonyms: Set<String> = [
        "IN", "BACK", "BACK9", "BACKNINE", "BACK9TOTAL", "IN9", "BACKTOTAL"
    ]

    public static let totalSynonyms: Set<String> = [
        "TOT", "TOTAL", "TOTALS", "TTL", "GROSS", "GROSSSCORE", "TOTALSCORE", "GRANDTOTAL"
    ]

    /// Tee names, mapped to a colour hint where the name is a colour.
    public static let teeNames: [String: String?] = [
        "BLACK": "black", "BLUE": "blue", "WHITE": "white", "RED": "red", "GOLD": "gold",
        "GREEN": "green", "SILVER": "silver", "BRONZE": "bronze", "COPPER": "copper",
        "ORANGE": "orange", "YELLOW": "yellow", "PURPLE": "purple", "MAROON": "maroon",
        "CHAMPIONSHIP": nil, "CHAMP": nil, "TIPS": nil, "TOURNAMENT": nil, "PRO": nil,
        "MENS": nil, "MEN": nil, "REGULAR": nil, "MIDDLE": nil,
        "SENIOR": nil, "SENIORS": nil, "LADIES": nil, "LADY": nil, "WOMENS": nil, "WOMEN": nil,
        "FORWARD": nil, "JUNIOR": nil, "EXECUTIVE": nil
    ]

    /// Words that decorate a tee label without identifying it, e.g. `BLUE TEES`, `MENS TEE`.
    static let teeDecorations: Set<String> = ["TEE", "TEES", "YARDS", "YARDAGE", "YDS", "YD", "YARD"]

    public enum LabelMatch: Hashable, Sendable {
        case hole
        case par
        case handicap
        case out
        case inward
        case total
        case tee(name: String, colorName: String?)
    }

    /// Classifies a *single* normalized token.
    public static func match(token: String) -> LabelMatch? {
        if token.isEmpty { return nil }
        if holeSynonyms.contains(token) { return .hole }
        if parSynonyms.contains(token) { return .par }
        if handicapSynonyms.contains(token) { return .handicap }
        if outSynonyms.contains(token) { return .out }
        if inSynonyms.contains(token) { return .inward }
        if totalSynonyms.contains(token) { return .total }
        if let color = teeNames[token] {
            return .tee(name: token.capitalized, colorName: color)
        }
        return nil
    }

    /// Classifies a whole label gutter, which may read `BLUE TEES` or `HCP / SI`.
    ///
    /// Decorations are stripped first so `WHITE TEES` and `WHITE` produce the same tee. Static-data labels
    /// win over tee labels when both appear, because a card that prints `PAR` in a row cannot be a tee row.
    public static func match(labelTokens: [String]) -> LabelMatch? {
        let normalized = labelTokens
            .map(TextNormalizer.normalizeLabel)
            .filter { !$0.isEmpty && !teeDecorations.contains($0) }
        guard !normalized.isEmpty else { return nil }

        var teeMatch: LabelMatch?
        for token in normalized {
            guard let candidate = match(token: token) else { continue }
            if case .tee = candidate {
                if teeMatch == nil { teeMatch = candidate }
            } else {
                return candidate
            }
        }
        if let teeMatch { return teeMatch }

        // Fall back to the joined form so `STROKE INDEX` split across two observations still matches.
        let joined = normalized.joined()
        return match(token: joined)
    }

    /// True when a label gutter looks like a person's name rather than a printed row label.
    ///
    /// Used only as corroboration: an unreadable or blank name never disqualifies a player row, because
    /// golfers routinely leave the name column empty.
    public static func looksLikePlayerName(_ labelTokens: [String]) -> Bool {
        let normalized = labelTokens.map(TextNormalizer.normalizeLabel).filter { !$0.isEmpty }
        guard !normalized.isEmpty else { return false }
        for token in normalized {
            if match(token: token) != nil { return false }
            if teeDecorations.contains(token) { return false }
        }
        // A name is alphabetic and at least two characters long.
        return normalized.contains { $0.count >= 2 && $0.allSatisfy { $0.isLetter } }
    }
}
