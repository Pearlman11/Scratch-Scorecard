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

    /// Black tee yardages by hole. Total 3,842.
    public static let blackYardages: [Int] = [
        317, 279, 121, 187, 123, 501, 155, 185, 153,
        137, 293, 138, 95, 213, 301, 351, 140, 153
    ]

    /// White tee yardages by hole. Total 3,397.
    public static let whiteYardages: [Int] = [
        289, 257, 100, 171, 103, 486, 135, 145, 125,
        113, 254, 127, 89, 170, 270, 333, 114, 116
    ]

    /// Red tee yardages by hole. Total 2,834.
    public static let redYardages: [Int] = [
        262, 214, 94, 105, 86, 397, 92, 115, 119,
        90, 227, 115, 71, 117, 233, 316, 98, 83
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
        source: "Physical Steel Canyon Golf Club scorecard",
        templateVersion: 1
    )
}
