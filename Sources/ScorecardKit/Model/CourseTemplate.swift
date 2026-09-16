import Foundation

/// How much of a template's hole-level data has been checked against an authoritative source.
///
/// The catalog deliberately ships courses whose hole data is *absent*. Fabricated pars and yardages would
/// poison the matcher — a wrong template that scores well is worse than no template at all, because it
/// would confidently overwrite correctly-read printed values.
public enum TemplateVerificationStatus: String, Codable, Sendable, CaseIterable {
    /// Hole-by-hole data checked against the physical scorecard or the operator's published card.
    case verified
    /// Some hole-level data present and checked, some missing.
    case partial
    /// Hole-level data present but not checked against an authoritative source.
    case unverified
    /// Course identity only. No hole-level data. The matcher may still match on name.
    case needsVerification
    /// Built from a scan the golfer confirmed on the review screen.
    case userConfirmed
}

/// A set of tees on one layout.
public struct TeeSetTemplate: Codable, Hashable, Sendable, Identifiable {
    public var id: String { name }
    /// Display name as printed on the card, e.g. `Black`, `White`, `Red`, `Championship`.
    public var name: String
    /// A colour hint for the UI, lowercased, when the tee is named for a colour.
    public var colorName: String?
    /// Yardage per hole, index 0 == hole 1. `nil` entries mean "not known", never "zero".
    public var yardages: [Int?]
    public var courseRating: Double?
    public var slopeRating: Int?

    public init(
        name: String,
        colorName: String? = nil,
        yardages: [Int?] = [],
        courseRating: Double? = nil,
        slopeRating: Int? = nil
    ) {
        self.name = name
        self.colorName = colorName
        self.yardages = yardages
        self.courseRating = courseRating
        self.slopeRating = slopeRating
    }

    public func yardage(forHole holeNumber: Int) -> Int? {
        let index = holeNumber - 1
        guard yardages.indices.contains(index) else { return nil }
        return yardages[index]
    }

    /// Sum of the holes in `range` (1-based, inclusive). `nil` when any hole in the range is unknown, so a
    /// partial template can never present a misleadingly small total.
    public func total(holes range: ClosedRange<Int>) -> Int? {
        var sum = 0
        for hole in range {
            guard let yards = yardage(forHole: hole) else { return nil }
            sum += yards
        }
        return sum
    }

    public var totalYardage: Int? {
        guard !yardages.isEmpty else { return nil }
        return total(holes: 1...yardages.count)
    }

    public var hasCompleteYardages: Bool {
        !yardages.isEmpty && !yardages.contains(where: { $0 == nil })
    }
}

/// Stable identity of a playable 9- or 18-hole layout.
///
/// A facility may run several layouts (Stone Mountain's Stonemont and Lakemont, Chateau Elan's three
/// courses). Those are modelled as separate `CourseTemplate`s sharing a `facilityName`, because a golfer
/// plays a layout, not a facility, and a scorecard's par sequence identifies a layout.
public struct CourseIdentity: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    /// Full display name, e.g. `Steel Canyon Golf Club`.
    public var name: String
    /// Layout name when the facility has more than one, e.g. `Stonemont`.
    public var layoutName: String?
    public var facilityName: String
    public var city: String
    /// Always `GA` in this MVP. The catalog is Georgia-only by design.
    public var state: String
    /// Alternate spellings and abbreviations that appear on cards, signage or in OCR output.
    public var aliases: [String]

    public init(
        id: String,
        name: String,
        layoutName: String? = nil,
        facilityName: String,
        city: String,
        state: String = "GA",
        aliases: [String] = []
    ) {
        self.id = id
        self.name = name
        self.layoutName = layoutName
        self.facilityName = facilityName
        self.city = city
        self.state = state
        self.aliases = aliases
    }

    /// Name shown in lists: includes the layout when the facility has several.
    public var displayName: String {
        guard let layoutName else { return name }
        return "\(name) — \(layoutName)"
    }

    /// Every string the matcher should try against OCR text.
    public var matchableNames: [String] {
        var names = [name, facilityName]
        if let layoutName {
            names.append(layoutName)
            names.append("\(facilityName) \(layoutName)")
        }
        names.append(contentsOf: aliases)
        return Array(Set(names))
    }
}

/// The static, printed truth about a golf course layout.
///
/// A template supplies course *metadata* only. There is intentionally nowhere in this type to put a score.
public struct CourseTemplate: Codable, Hashable, Sendable, Identifiable {
    public var id: String { identity.id }
    public var identity: CourseIdentity
    public var holeCount: Int
    /// Par per hole, index 0 == hole 1. `nil` means unknown.
    public var pars: [Int?]
    /// Stroke index (the "HCP" column printed beside each hole) per hole, index 0 == hole 1.
    /// This is the *hole's* difficulty ranking, not the golfer's handicap index.
    public var handicapIndices: [Int?]
    public var teeSets: [TeeSetTemplate]
    public var verification: TemplateVerificationStatus
    /// Where the data came from, e.g. `Physical scorecard, 2024`.
    public var source: String?
    /// Bumped whenever the hole data changes, so stored rounds can record what they were parsed against.
    public var templateVersion: Int
    /// Cached geocode, filled in at runtime by `MKLocalSearch`. Never hand-typed.
    public var latitude: Double?
    public var longitude: Double?

    public init(
        identity: CourseIdentity,
        holeCount: Int,
        pars: [Int?] = [],
        handicapIndices: [Int?] = [],
        teeSets: [TeeSetTemplate] = [],
        verification: TemplateVerificationStatus,
        source: String? = nil,
        templateVersion: Int = 1,
        latitude: Double? = nil,
        longitude: Double? = nil
    ) {
        self.identity = identity
        self.holeCount = holeCount
        self.pars = pars
        self.handicapIndices = handicapIndices
        self.teeSets = teeSets
        self.verification = verification
        self.source = source
        self.templateVersion = templateVersion
        self.latitude = latitude
        self.longitude = longitude
    }

    /// `holeCount == 0` is the explicit encoding of "we do not know how many holes this layout has".
    /// The catalog seeds identity-only records this way rather than assuming 18, and the matcher skips the
    /// hole-count signal when it is unknown instead of penalising a course for our own missing data.
    public var isHoleCountKnown: Bool { holeCount > 0 }

    public func par(forHole holeNumber: Int) -> Int? {
        let index = holeNumber - 1
        guard pars.indices.contains(index) else { return nil }
        return pars[index]
    }

    public func handicapIndex(forHole holeNumber: Int) -> Int? {
        let index = holeNumber - 1
        guard handicapIndices.indices.contains(index) else { return nil }
        return handicapIndices[index]
    }

    public func teeSet(named name: String) -> TeeSetTemplate? {
        let target = TextNormalizer.normalizeName(name)
        return teeSets.first { TextNormalizer.normalizeName($0.name) == target }
    }

    /// Par for a 1-based inclusive hole range, or `nil` if any hole in the range is unknown.
    public func totalPar(holes range: ClosedRange<Int>) -> Int? {
        var sum = 0
        for hole in range {
            guard let value = par(forHole: hole) else { return nil }
            sum += value
        }
        return sum
    }

    public var frontNinePar: Int? {
        guard holeCount >= 9 else { return nil }
        return totalPar(holes: 1...9)
    }

    public var backNinePar: Int? {
        guard holeCount >= 18 else { return nil }
        return totalPar(holes: 10...18)
    }

    public var totalPar: Int? {
        guard holeCount > 0 else { return nil }
        return totalPar(holes: 1...holeCount)
    }

    /// True when the template has enough hole data to restore static values after a match.
    public var hasUsableHoleData: Bool {
        guard holeCount > 0, pars.count == holeCount else { return false }
        return !pars.contains(where: { $0 == nil })
    }

    /// Whether this template is trustworthy enough to *overwrite* an OCR reading of a printed value.
    public var mayRestoreStaticData: Bool {
        switch verification {
        case .verified, .partial, .userConfirmed:
            return hasUsableHoleData || !teeSets.isEmpty
        case .unverified, .needsVerification:
            return false
        }
    }
}
