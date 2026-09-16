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

    func testGeorgiaBoundsRejectCoordinatesOutsideTheState() {
        // Sandy Springs, roughly.
        XCTAssertTrue(GeorgiaCourseCatalog.isWithinGeorgia(latitude: 33.95, longitude: -84.37))
        // Nashville, Charlotte, Jacksonville and Birmingham are all outside.
        XCTAssertFalse(GeorgiaCourseCatalog.isWithinGeorgia(latitude: 36.16, longitude: -86.78))
        XCTAssertFalse(GeorgiaCourseCatalog.isWithinGeorgia(latitude: 35.23, longitude: -80.84))
        XCTAssertFalse(GeorgiaCourseCatalog.isWithinGeorgia(latitude: 30.33, longitude: -81.65))
        XCTAssertFalse(GeorgiaCourseCatalog.isWithinGeorgia(latitude: 33.52, longitude: -86.81))
    }

    func testEveryCourseHasMatchableAliases() {
        for template in catalog {
            XCTAssertFalse(template.identity.matchableNames.isEmpty)
            XCTAssertTrue(template.identity.matchableNames.contains(template.identity.name))
        }
    }
}
