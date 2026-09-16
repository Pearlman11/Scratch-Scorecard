import Foundation

/// The first fully verified template, transcribed from the physical Steel Canyon scorecard.
///
/// Steel Canyon is an executive-length course: par 61, with twelve par 3s. That makes it an unusually good
/// regression fixture, because a parser that quietly assumes "par is 70-72" or "a par row averages 4"
/// breaks here immediately.
public enum SteelCanyonTemplate {

    public static let identity = CourseIdentity(
        id: "ga-steel-canyon",
        name: "Steel Canyon Golf Club",
        layoutName: nil,
        facilityName: "Steel Canyon Golf Club",
        city: "Sandy Springs",
        state: "GA",
        aliases: ["Steel Canyon", "Steel Canyon GC", "Steelcanyon"]
    )

    /// Par by hole, index 0 == hole 1. Front nine 31, back nine 30, total 61.
    public static let pars: [Int] = [
        4, 4, 3, 3, 3, 5, 3, 3, 3,
        3, 4, 3, 3, 3, 4, 4, 3, 3
    ]

    /// Stroke index by hole (the printed "HCP" column), index 0 == hole 1.
    /// A permutation of 1...18, which is what makes it such a strong fingerprint.
    public static let handicapIndices: [Int] = [
        3, 5, 15, 9, 17, 1, 11, 7, 13,
        12, 4, 16, 18, 8, 6, 2, 14, 10
    ]

    // MARK: - Yardages
    //
    // Corrected against a photograph of the physical card (print date 10/2025). Four values in the
    // originally supplied numbers did not match it: Black 14 (was 213), White 14 (was 170), Red 3 (was 94)
    // and Red 11 (was 227). The card's own printed subtotals confirm which is right — every tee's front
    // plus back equals its printed total using the values below, and does not using the old ones. The
    // giveaway was that the old White 14 (170) is the card's *Black* 14: a row-shifted transcription.
    //
    // This mattered: a verified template is allowed to overwrite a yardage the parser read off a card, so
    // wrong template data does not sit harmlessly in a catalog — it actively replaces correct readings
    // with incorrect ones. `SteelCanyonTemplateTests` now re-derives every printed subtotal from these
    // arrays, so a future transcription error fails the suite instead of shipping.

    /// Black tee yardages by hole. Front 2,021 + back 1,778 = 3,799.
    public static let blackYardages: [Int] = [
        317, 279, 121, 187, 123, 501, 155, 185, 153,
        137, 293, 138, 95, 170, 301, 351, 140, 153
    ]

    /// White tee yardages by hole. Front 1,811 + back 1,564 = 3,375.
    public static let whiteYardages: [Int] = [
        289, 257, 100, 171, 103, 486, 135, 145, 125,
        113, 254, 127, 89, 148, 270, 333, 114, 116
    ]

    /// Red tee yardages by hole. Front 1,457 + back 1,245 = 2,702.
    public static let redYardages: [Int] = [
        262, 214, 67, 105, 86, 397, 92, 115, 119,
        90, 122, 115, 71, 117, 233, 316, 98, 83
    ]

    public static let template: CourseTemplate = CourseTemplate(
        identity: identity,
        holeCount: 18,
        pars: pars.map { Optional($0) },
        handicapIndices: handicapIndices.map { Optional($0) },
        teeSets: [
            TeeSetTemplate(name: "Black", colorName: "black", yardages: blackYardages.map { Optional($0) }),
            TeeSetTemplate(name: "White", colorName: "white", yardages: whiteYardages.map { Optional($0) }),
            TeeSetTemplate(name: "Red", colorName: "red", yardages: redYardages.map { Optional($0) })
        ],
        verification: .verified,
        source: "Physical Steel Canyon Golf Club scorecard, print date 10/2025",
        templateVersion: 2
    )
}
