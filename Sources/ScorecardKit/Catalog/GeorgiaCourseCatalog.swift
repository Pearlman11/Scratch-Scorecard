import Foundation

/// The Georgia-only seed catalog for v1.
///
/// ## Data-integrity policy
///
/// Only Steel Canyon ships with hole-level data, because only Steel Canyon has been transcribed from a
/// physical card. Every other entry is an **identity record**: name, facility, city, state and aliases,
/// with `verification == .needsVerification` and empty `pars`, `handicapIndices` and `teeSets`.
///
/// Inventing pars or yardages here would be actively harmful, not merely sloppy: `CourseTemplateMatcher`
/// treats par and stroke-index sequences as fingerprints, so a fabricated sequence would let the wrong
/// course win a match and then *overwrite correctly-read printed values* with fiction. Absent data simply
/// makes those signals abstain.
///
/// Identity-only records are still useful — they give the map its pins, they let the golfer pick a course
/// by hand, they let the name signal identify a card on its own, and after the first confirmed scan the
/// app can promote a scanned card into a `.userConfirmed` template (see `LearnedTemplateBuilder`).
///
/// Coordinates are deliberately absent: they are resolved at runtime with `MKLocalSearch`, validated
/// against Georgia's bounding box and cached, rather than hand-typed from memory.
public enum GeorgiaCourseCatalog {

    /// Bounding box used to reject a geocode that clearly did not land in Georgia.
    ///
    /// These are Georgia's actual extents, deliberately *unpadded*. An earlier version padded the box by a
    /// few tenths of a degree, which pushed its southern edge past the Florida line and quietly admitted
    /// Jacksonville — a city with plenty of golf courses that are emphatically not in this catalog.
    ///
    /// ## What this check can and cannot do
    ///
    /// Georgia is not a rectangle, so no bounding box can be exact. This one still contains Tallahassee
    /// and Greenville, South Carolina, which sit in corners the box cannot cut off. It is therefore a
    /// coarse backstop against a geocode landing in another region entirely, **not** the primary
    /// safeguard. That is `CourseLocationResolver`, which additionally requires the search result's own
    /// name to resemble the course it was looking for — the check that actually distinguishes "the right
    /// course" from "somewhere nearby with the right shape".
    public static let georgiaLatitudeRange: ClosedRange<Double> = 30.355...35.001
    public static let georgiaLongitudeRange: ClosedRange<Double> = -85.605...(-80.751)

    public static func isWithinGeorgia(latitude: Double, longitude: Double) -> Bool {
        georgiaLatitudeRange.contains(latitude) && georgiaLongitudeRange.contains(longitude)
    }

    /// Every seeded layout. Steel Canyon first; the rest are identity-only.
    public static let templates: [CourseTemplate] = [SteelCanyonTemplate.template] + identityOnlyTemplates

    /// Builds an identity-only record. `holeCount: 0` means "unknown", never "zero".
    private static func identityOnly(
        id: String,
        name: String,
        layoutName: String? = nil,
        facilityName: String? = nil,
        city: String,
        aliases: [String] = [],
        holeCount: Int = 0
    ) -> CourseTemplate {
        CourseTemplate(
            identity: CourseIdentity(
                id: id,
                name: name,
                layoutName: layoutName,
                facilityName: facilityName ?? name,
                city: city,
                state: "GA",
                aliases: aliases
            ),
            holeCount: holeCount,
            pars: [],
            handicapIndices: [],
            teeSets: [],
            verification: .needsVerification,
            source: "Course identity only. Hole data not yet transcribed from an authoritative scorecard.",
            templateVersion: 1
        )
    }

    private static let identityOnlyTemplates: [CourseTemplate] = [
        // Bobby Jones and Charlie Yates are non-standard layouts at the Atlanta Memorial Park complex, so
        // even their hole count is left unknown rather than assumed to be 18.
        identityOnly(
            id: "ga-bobby-jones",
            name: "Bobby Jones Golf Course",
            city: "Atlanta",
            aliases: ["Bobby Jones", "Bobby Jones GC", "Bobby Jones Golf Club"]
        ),
        identityOnly(
            id: "ga-charlie-yates",
            name: "Charlie Yates Golf Course",
            city: "Atlanta",
            aliases: ["Charlie Yates", "Charlie Yates GC"]
        ),
        identityOnly(
            id: "ga-north-fulton",
            name: "North Fulton Golf Course",
            city: "Atlanta",
            aliases: ["North Fulton", "North Fulton GC", "Chastain Park"],
            holeCount: 18
        ),
        identityOnly(
            id: "ga-tup-holmes",
            name: "Alfred \"Tup\" Holmes Golf Course",
            city: "Atlanta",
            aliases: ["Tup Holmes", "Alfred Tup Holmes", "Holmes Golf Course", "Alfred Holmes"],
            holeCount: 18
        ),
        identityOnly(
            id: "ga-browns-mill",
            name: "Browns Mill Golf Course",
            city: "Atlanta",
            aliases: ["Browns Mill", "Brown's Mill", "Browns Mill GC"],
            holeCount: 18
        ),
        identityOnly(
            id: "ga-sugar-creek",
            name: "Sugar Creek Golf Course",
            city: "Atlanta",
            aliases: ["Sugar Creek", "Sugar Creek GC"],
            holeCount: 18
        ),
        identityOnly(
            id: "ga-wolf-creek",
            name: "Wolf Creek Golf Club",
            city: "Atlanta",
            aliases: ["Wolf Creek", "Wolf Creek GC"],
            holeCount: 18
        ),
        identityOnly(
            id: "ga-cobblestone",
            name: "Cobblestone Golf Course",
            city: "Acworth",
            aliases: ["Cobblestone", "Cobblestone GC"],
            holeCount: 18
        ),
        identityOnly(
            id: "ga-heritage-golf-links",
            name: "Heritage Golf Links",
            city: "Tucker",
            aliases: ["Heritage Golf Links", "Heritage GC", "Heritage"],
            holeCount: 18
        ),
        identityOnly(
            id: "ga-uga",
            name: "University of Georgia Golf Course",
            city: "Athens",
            aliases: ["UGA Golf Course", "Georgia Golf Course", "University of Georgia"],
            holeCount: 18
        ),
        identityOnly(
            id: "ga-bears-best",
            name: "Bear's Best Atlanta",
            city: "Suwanee",
            aliases: ["Bears Best", "Bear's Best", "Bears Best Atlanta"],
            holeCount: 18
        ),
        identityOnly(
            id: "ga-lanier-islands-legacy",
            name: "Lanier Islands Legacy Golf Course",
            city: "Buford",
            aliases: ["Legacy on Lanier", "Lanier Islands Legacy", "Lanier Islands", "Legacy Golf Course"],
            holeCount: 18
        ),

        // Multi-layout facilities are modelled one layout per record, because a scorecard identifies a
        // layout (through its par and stroke-index sequences), not a facility.
        identityOnly(
            id: "ga-stone-mountain-stonemont",
            name: "Stone Mountain Golf Club",
            layoutName: "Stonemont",
            facilityName: "Stone Mountain Golf Club",
            city: "Stone Mountain",
            aliases: ["Stonemont", "Stone Mountain Stonemont"],
            holeCount: 18
        ),
        identityOnly(
            id: "ga-stone-mountain-lakemont",
            name: "Stone Mountain Golf Club",
            layoutName: "Lakemont",
            facilityName: "Stone Mountain Golf Club",
            city: "Stone Mountain",
            aliases: ["Lakemont", "Stone Mountain Lakemont"],
            holeCount: 18
        ),
        identityOnly(
            id: "ga-chateau-elan-chateau",
            name: "Chateau Elan Golf Club",
            layoutName: "Chateau",
            facilityName: "Chateau Elan Golf Club",
            city: "Braselton",
            aliases: ["Chateau Elan", "Chateau Course", "Chateau Elan Chateau"],
            holeCount: 18
        ),
        identityOnly(
            id: "ga-chateau-elan-woodlands",
            name: "Chateau Elan Golf Club",
            layoutName: "Woodlands",
            facilityName: "Chateau Elan Golf Club",
            city: "Braselton",
            aliases: ["Woodlands", "Woodlands Course", "Chateau Elan Woodlands"],
            holeCount: 18
        )
    ]

    public static func template(withID id: String) -> CourseTemplate? {
        templates.first { $0.id == id }
    }
}

/// Supplies templates to the matcher. The app implements this by concatenating the Georgia seed catalog
/// with templates the golfer has confirmed, so learned data participates in matching on equal footing.
public protocol CourseTemplateProviding: Sendable {
    func availableTemplates() -> [CourseTemplate]
}

/// The seed-only provider. Used directly by tests and as the app's fallback.
public struct SeedCourseTemplateProvider: CourseTemplateProviding {
    public init() {}
    public func availableTemplates() -> [CourseTemplate] {
        GeorgiaCourseCatalog.templates
    }
}

/// A provider built from an explicit list. Used by the app to merge seeded and learned templates, and by
/// tests to isolate the matcher against a controlled candidate set.
public struct StaticCourseTemplateProvider: CourseTemplateProviding {
    public var templates: [CourseTemplate]
    public init(templates: [CourseTemplate]) {
        self.templates = templates
    }
    public func availableTemplates() -> [CourseTemplate] { templates }
}
