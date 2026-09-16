import XCTest
@testable import ScorecardKit

/// Tests for the table reconstruction, independent of any course or template.
final class LayoutReconstructionTests: XCTestCase {

    func testHoleHeaderYieldsEighteenColumnsAndAggregateColumns() throws {
        let card = ScorecardFixtureBuilder.steelCanyonCard(scores: ParserTestSupport.steelCanyonScores)
        let table = ParserTestSupport.table(card)

        XCTAssertEqual(table.sections.count, 1)
        guard let section = table.sections.first else { return XCTFail("no section detected") }
        XCTAssertEqual(section.holeColumns.count, 18)
        XCTAssertEqual(section.holeNumbers, Array(1...18))
        XCTAssertNotNil(section.aggregateColumn(.out))
        XCTAssertNotNil(section.aggregateColumn(.inward))
        XCTAssertNotNil(section.aggregateColumn(.total))
    }

    func testColumnsAreOrderedAndNonOverlapping() {
        let card = ScorecardFixtureBuilder.steelCanyonCard(scores: ParserTestSupport.steelCanyonScores)
        let table = ParserTestSupport.table(card)
        guard let section = table.sections.first else { return XCTFail("no section") }

        let byPosition = section.holeColumns.sorted { $0.centerX < $1.centerX }
        XCTAssertEqual(byPosition.map(\.holeNumber), Array(1...18), "Columns must run left to right in hole order")
        for index in 1..<byPosition.count {
            XCTAssertLessThanOrEqual(
                byPosition[index - 1].maxX, byPosition[index].minX + 1e-9,
                "Columns \(byPosition[index - 1].holeNumber) and \(byPosition[index].holeNumber) overlap"
            )
        }
    }

    func testRolesAreAssignedFromPrintedLabels() {
        let card = ScorecardFixtureBuilder.steelCanyonCard(scores: ParserTestSupport.steelCanyonScores)
        let table = ParserTestSupport.table(card)

        XCTAssertEqual(table.rows(withRole: { $0 == .par }).count, 1)
        XCTAssertEqual(table.rows(withRole: { $0 == .handicap }).count, 1)
        XCTAssertEqual(table.rows(withRole: { if case .yardage = $0 { return true }; return false }).count, 3)
        XCTAssertEqual(table.playerRows.count, 1)

        let teeNames = table.rows.compactMap { row -> String? in
            if case .yardage(let name) = row.role { return name }
            return nil
        }
        XCTAssertEqual(Set(teeNames), ["Black", "White", "Red"])
    }

    func testAnUnlabelledParRowIsStillIdentifiedAsPar() {
        var card = ScorecardFixtureBuilder.steelCanyonCard(scores: ParserTestSupport.steelCanyonScores)
        card.rows[3] = ScorecardFixtureBuilder.Row
            .printed(label: nil, values: SteelCanyonTemplate.template.pars)
            .withTotals(out: 31, inward: 30, total: 61)

        let table = ParserTestSupport.table(card)
        XCTAssertEqual(
            table.rows(withRole: { $0 == .par }).count, 1,
            "With no label, print quality and position must still separate par from a golfer's row"
        )
        XCTAssertEqual(table.playerRows.count, 1, "The handwritten row must not be promoted to par")
    }

    func testAnUnlabelledStrokeIndexRowIsIdentifiedByItsPermutation() {
        var card = ScorecardFixtureBuilder.steelCanyonCard(scores: ParserTestSupport.steelCanyonScores)
        card.rows[4] = ScorecardFixtureBuilder.Row
            .printed(label: nil, values: SteelCanyonTemplate.template.handicapIndices)

        let table = ParserTestSupport.table(card)
        XCTAssertEqual(table.rows(withRole: { $0 == .handicap }).count, 1)
    }

    func testStackedNinesProduceTwoSectionsCoveringAllHoles() {
        let card = ScorecardFixtureBuilder.steelCanyonCard(
            scores: ParserTestSupport.steelCanyonScores,
            layout: .stackedNines
        )
        let table = ParserTestSupport.table(card)

        XCTAssertEqual(table.sections.count, 2)
        XCTAssertEqual(table.sections[0].holeNumbers, Array(1...9))
        XCTAssertEqual(table.sections[1].holeNumbers, Array(10...18))
        XCTAssertEqual(table.allHoleNumbers, Array(1...18))
    }

    func testSkewIsEstimatedAndRemoved() {
        let card = ScorecardFixtureBuilder.steelCanyonCard(
            scores: ParserTestSupport.steelCanyonScores,
            skewDegrees: 5.0
        )
        let table = ParserTestSupport.table(card)
        let degrees = table.skewRadians * 180 / .pi

        XCTAssertEqual(degrees, 5.0, accuracy: 1.2, "Estimated skew should track the applied rotation")
        XCTAssertEqual(table.sections.first?.holeColumns.count, 18)
    }

    func testNineHoleCardProducesNineColumns() {
        let table = ParserTestSupport.table(ParserTestSupport.nineHoleCard())
        XCTAssertEqual(table.detectedHoleCount, 9)
        XCTAssertEqual(table.sections.first?.holeNumbers, Array(1...9))
        XCTAssertNotNil(table.sections.first?.aggregateColumn(.out))
    }

    func testNoTextProducesNoTable() {
        let table = ScorecardLayoutDetector().detectTable(from: [])
        XCTAssertTrue(table.rows.isEmpty)
        XCTAssertTrue(table.sections.isEmpty)
        XCTAssertEqual(table.detectedHoleCount, 0)
    }

    func testTextWithNoHoleHeaderProducesNoSections() {
        let observations = [
            TextObservation(text: "RECEIPT", rect: CardRect(x: 0.1, y: 0.1, width: 0.2, height: 0.03), confidence: 0.9),
            TextObservation(text: "TOTAL", rect: CardRect(x: 0.1, y: 0.2, width: 0.2, height: 0.03), confidence: 0.9),
            TextObservation(text: "$42.00", rect: CardRect(x: 0.5, y: 0.2, width: 0.2, height: 0.03), confidence: 0.9)
        ]
        let table = ScorecardLayoutDetector().detectTable(from: observations)
        XCTAssertTrue(table.sections.isEmpty)
    }

    func testRowClustererGroupsAcrossTheFullWidthOfTheCard() {
        let card = ScorecardFixtureBuilder.steelCanyonCard(scores: ParserTestSupport.steelCanyonScores)
        let table = ParserTestSupport.table(card)
        guard let parRow = table.rows(withRole: { $0 == .par }).first else { return XCTFail("no par row") }

        // Label + 18 holes + OUT + IN + TOT.
        XCTAssertEqual(parRow.observations.count, 22)
        XCTAssertLessThan(parRow.rect.minX, 0.05, "The row must include its label in the left gutter")
        XCTAssertGreaterThan(parRow.rect.maxX, 0.9, "The row must reach the card's right edge")
    }
}
