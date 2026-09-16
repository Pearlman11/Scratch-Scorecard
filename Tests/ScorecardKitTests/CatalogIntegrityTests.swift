import XCTest
@testable import ScorecardKit

/// Guards the data-integrity policy of the seed catalog.
///
/// The policy is the point: shipping fourteen Georgia courses with *no* hole data is a deliberate choice,
/// and these tests fail if someone later "helpfully" fills those arrays in from memory. A fabricated par
/// sequence is not a harmless placeholder — the matcher treats par sequences as fingerprints, so a made-up
/// one would let the wrong course win a match and then overwrite correctly-read printed values with fiction.
final class CatalogIntegrityTests: XCTestCase {

    private var catalog: [CourseTemplate] { GeorgiaCourseCatalog.templates }

    func testCatalogIsGeorgiaOnly() {
        for template in catalog {
            XCTAssertEqual(template.identity.state, "GA", "\(template.identity.name) is not in Georgia")
        }
    }

    func testCatalogContainsTheExpectedSeedCourses() {
        let names = Set(catalog.map(\.identity.facilityName))
        let expected = [
            "Steel Canyon Golf Club", "Bobby Jones Golf Course", "Charlie Yates Golf Course",
            "North Fulton Golf Course", "Alfred \"Tup\" Holmes Golf Course", "Browns Mill Golf Course",
            "Sugar Creek Golf Course", "Wolf Creek Golf Club", "Cobblestone Golf Course",
            "Heritage Golf Links", "University of Georgia Golf Course", "Bear's Best Atlanta",
            "Lanier Islands Legacy Golf Course", "Stone Mountain Golf Club", "Chateau Elan Golf Club"
        ]
        for name in expected {
            XCTAssertTrue(names.contains(name), "Missing seed course: \(name)")
        }
    }

    func testTemplateIDsAreUnique() {
        let ids = catalog.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "Duplicate template IDs would make matches non-deterministic")
    }

    func testMultiLayoutFacilitiesAreModelledOneLayoutPerRecord() {
        let stoneMountain = catalog.filter { $0.identity.facilityName == "Stone Mountain Golf Club" }
        XCTAssertEqual(stoneMountain.count, 2)
        XCTAssertEqual(Set(stoneMountain.compactMap(\.identity.layoutName)), ["Stonemont", "Lakemont"])
        XCTAssertTrue(stoneMountain.allSatisfy { $0.identity.displayName.contains("—") })

        let chateauElan = catalog.filter { $0.identity.facilityName == "Chateau Elan Golf Club" }
        XCTAssertGreaterThanOrEqual(chateauElan.count, 2)
        XCTAssertEqual(Set(chateauElan.map(\.id)).count, chateauElan.count)
    }

    func testOnlySteelCanyonShipsWithHoleLevelData() {
        for template in catalog where template.id != "ga-steel-canyon" {
            XCTAssertTrue(
                template.pars.isEmpty,
                "\(template.id) has par data that was never transcribed from an authoritative card"
            )
            XCTAssertTrue(template.handicapIndices.isEmpty, "\(template.id) has invented stroke indices")
            XCTAssertTrue(template.teeSets.isEmpty, "\(template.id) has invented tee sets")
            XCTAssertEqual(template.verification, .needsVerification)
            XCTAssertFalse(
                template.mayRestoreStaticData,
                "\(template.id) must never be allowed to overwrite a value read off a card"
            )
        }
    }

    func testNoCoordinatesAreHandTyped() {
        // Coordinates are resolved at runtime with MKLocalSearch and validated against Georgia's bounds,
        // never typed from memory.
        for template in catalog {
            XCTAssertNil(template.latitude, "\(template.id) has a hand-typed latitude")
            XCTAssertNil(template.longitude, "\(template.id) has a hand-typed longitude")
        }
    }

    func testUnknownHoleCountsAreRepresentedExplicitly() {
        // Bobby Jones and Charlie Yates are non-standard layouts, so even their hole count is left unknown
        // rather than assumed to be 18.
        let bobbyJones = catalog.first { $0.id == "ga-bobby-jones" }
        XCTAssertEqual(bobbyJones?.holeCount, 0)
        XCTAssertEqual(bobbyJones?.isHoleCountKnown, false)

        let steelCanyon = catalog.first { $0.id == "ga-steel-canyon" }
        XCTAssertEqual(steelCanyon?.isHoleCountKnown, true)
    }

    func testGeorgiaBoundsAcceptCoursesAcrossTheWholeState() {
        // Corners and edges of the real catalog's geography, so tightening the box can never start
        // rejecting a course the app actually ships.
        let inGeorgia: [(String, Double, Double)] = [
            ("Sandy Springs", 33.95, -84.37),
            ("Atlanta", 33.75, -84.39),
            ("Athens", 33.95, -83.38),
            ("Braselton", 34.11, -83.76),
            ("Valdosta, near the Florida line", 30.83, -83.28),
            ("St Marys, the south-east corner", 30.73, -81.55),
            ("Tybee Island, the eastern edge", 32.00, -80.85),
            ("Columbus, the western edge", 32.46, -84.99)
        ]
        for (name, latitude, longitude) in inGeorgia {
            XCTAssertTrue(
                GeorgiaCourseCatalog.isWithinGeorgia(latitude: latitude, longitude: longitude),
                "\(name) should be inside Georgia"
            )
        }
    }

    func testGeorgiaBoundsRejectNearbyCitiesOutsideTheState() {
        // Jacksonville is the case that matters: it sits just south of the Florida line, and an earlier
        // padded box admitted it.
        let outsideGeorgia: [(String, Double, Double)] = [
            ("Jacksonville FL", 30.33, -81.65),
            ("Nashville TN", 36.16, -86.78),
            ("Charlotte NC", 35.23, -80.84),
            ("Birmingham AL", 33.52, -86.81),
            ("Chattanooga TN", 35.05, -85.31)
        ]
        for (name, latitude, longitude) in outsideGeorgia {
            XCTAssertFalse(
                GeorgiaCourseCatalog.isWithinGeorgia(latitude: latitude, longitude: longitude),
                "\(name) should be outside Georgia"
            )
        }
    }

    func testTheBoundingBoxIsCoarseAndIsNotTheOnlySafeguard() {
        // Georgia is not a rectangle, so its corners contain neighbouring cities and no box can exclude
        // them. Asserting this pins down a known limitation rather than leaving it to be rediscovered:
        // the real protection is the name check in CourseLocationResolver, which requires a search result
        // to resemble the course it was looking for.
        XCTAssertTrue(
            GeorgiaCourseCatalog.isWithinGeorgia(latitude: 30.44, longitude: -84.28),
            "Tallahassee sits in the box's south-west corner — the box alone cannot exclude it"
        )
        XCTAssertTrue(
            GeorgiaCourseCatalog.isWithinGeorgia(latitude: 34.85, longitude: -82.39),
            "Greenville SC sits in the box's north-east corner"
        )
        // The name check is what separates these from a real match.
        XCTAssertLessThan(FuzzyText.similarity("Tallahassee Municipal Golf Course", "Steel Canyon Golf Club"), 0.5)
    }

    func testEveryCourseHasMatchableAliases() {
        for template in catalog {
            XCTAssertFalse(template.identity.matchableNames.isEmpty)
            XCTAssertTrue(template.identity.matchableNames.contains(template.identity.name))
        }
    }
}
