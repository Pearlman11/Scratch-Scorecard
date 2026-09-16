import XCTest
@testable import ScorecardKit

final class NumericOCRTests: XCTestCase {

    func testLettersStandingInForDigitsAreRecovered() {
        XCTAssertTrue(NumericOCR.integerCandidates(from: "33B").contains(333))
        XCTAssertTrue(NumericOCR.integerCandidates(from: "l71").contains(171))
        XCTAssertTrue(NumericOCR.integerCandidates(from: "S").contains(5))
        XCTAssertTrue(NumericOCR.integerCandidates(from: "9A").contains(94))
        XCTAssertTrue(NumericOCR.integerCandidates(from: "1O0").contains(100))
    }

    func testGroupingSeparatorsAreIgnored() {
        XCTAssertEqual(NumericOCR.bestInteger(from: "3,842")?.value, 3842)
        XCTAssertEqual(NumericOCR.bestInteger(from: " 171 ")?.value, 171)
    }

    func testRowLabelsAreNeverReadAsNumbers() {
        // "OUT" maps glyph-for-glyph onto 007 and "TOT" onto 707; reading either as a number would put a
        // summary column's label into a hole's cell.
        for label in ["OUT", "IN", "PAR", "TOT", "TOTAL", "HCP", "HOLE"] {
            XCTAssertTrue(
                NumericOCR.integerCandidates(from: label).isEmpty,
                "\(label) must not be read as a number"
            )
        }
    }

    func testAnAmbiguousSingleLetterIsNotReadAsADigit() {
        // A lone "B" is far more likely a tee abbreviation than the score 8.
        XCTAssertTrue(NumericOCR.integerCandidates(from: "B").isEmpty)
        // A lone letter that stands for exactly one digit is still read: handwriting really does do this.
        XCTAssertEqual(NumericOCR.integerCandidates(from: "S").first, 5)
    }

    func testPlausibleRangeSelectsAmongCandidatesButFlagsWhenNothingFits() {
        // "B" expands to 8 and 3; constrained to a par range only 3 survives.
        let inRange = NumericOCR.bestInteger(from: "B3", plausibleRange: 30...40)
        XCTAssertEqual(inRange?.value, 33)

        // Nothing in range: reported with a maximal penalty so the caller drops it.
        let outOfRange = NumericOCR.bestInteger(from: "88", plausibleRange: 1...15)
        XCTAssertEqual(outOfRange?.penalty, 1.0)
    }

    func testPenaltyGrowsWithGlyphSubstitution() throws {
        let clean = try XCTUnwrap(NumericOCR.bestInteger(from: "333"))
        let damaged = try XCTUnwrap(NumericOCR.bestInteger(from: "33B"))
        XCTAssertEqual(clean.penalty, 0)
        XCTAssertGreaterThan(damaged.penalty, 0)
        // "B" resembles an 8 more than a 3, so the unconstrained best reading of "33B" is 338. Recovering
        // the true 333 is the template's job, not the tokeniser's — but 333 must stay on the candidate list.
        XCTAssertEqual(damaged.value, 338)
        XCTAssertTrue(NumericOCR.integerCandidates(from: "33B").contains(333))
    }

    func testSimilarityScoring() {
        XCTAssertEqual(NumericOCR.similarity(observedText: "333", expected: 333), 1.0)
        XCTAssertEqual(NumericOCR.similarity(observedText: "33B", expected: 333), 1.0, "A letter is a clean read of its digit")
        XCTAssertEqual(NumericOCR.similarity(observed: 4, expected: 4), 1.0)
        // One confused digit out of three: two agree outright, the third is a known confusion pair.
        XCTAssertEqual(NumericOCR.similarity(observed: 338, expected: 333), 2.5 / 3.0, accuracy: 0.001)
        XCTAssertEqual(NumericOCR.similarity(observed: 17, expected: 12), 0.75, accuracy: 0.001)
        XCTAssertEqual(NumericOCR.similarity(observed: 500, expected: 4), 0, accuracy: 0.001)
    }

    func testALengthMismatchScoresFarBelowADigitSwap() {
        let swapped = NumericOCR.similarity(observed: 338, expected: 333)
        let dropped = NumericOCR.similarity(observed: 33, expected: 333)
        XCTAssertEqual(dropped, 1.0 / 3.0, accuracy: 0.001)
        XCTAssertGreaterThan(swapped, dropped, "Losing a digit is a bigger error than confusing one")
    }

    func testNameNormalisation() {
        XCTAssertEqual(TextNormalizer.normalizeLabel("H.C.P."), "HCP")
        XCTAssertEqual(TextNormalizer.normalizeName("Bear's Best Atlanta"), "bear s best atlanta")
        XCTAssertEqual(TextNormalizer.significantNameTokens("Steel Canyon Golf Club"), ["steel", "canyon"])
        XCTAssertEqual(TextNormalizer.significantNameTokens("Golf Club"), ["golf", "club"], "Falls back when all tokens are generic")
    }

    func testFuzzyNameMatchingSeparatesRealFromCoincidentalMatches() {
        // Genuine matches, including badly damaged ones, sit well above the 0.62 floor.
        XCTAssertGreaterThan(FuzzyText.similarity("STEEL CANYON GOLF CLUB", "Steel Canyon Golf Club"), 0.99)
        XCTAssertGreaterThan(FuzzyText.similarity("STEE CANYQN GOLE CLUB", "Steel Canyon Golf Club"), 0.75)
        XCTAssertGreaterThan(FuzzyText.similarity("5TEEL CANYON", "Steel Canyon Golf Club"), 0.70)
        XCTAssertGreaterThan(FuzzyText.similarity("BEARS BEST ATLANTA", "Bear's Best Atlanta"), 0.90)

        // Coincidental overlap between unrelated Georgia courses stays below it.
        XCTAssertLessThan(FuzzyText.similarity("WOLF CREEK GOLF CLUB", "Sugar Creek Golf Course"), 0.62)
        XCTAssertLessThan(FuzzyText.similarity("STEEL CANYON GOLF CLUB", "Stone Mountain Golf Club"), 0.62)
        XCTAssertLessThan(FuzzyText.similarity("SANDY SPRINGS, GEORGIA", "Steel Canyon Golf Club"), 0.40)
    }

    func testFragmentsAreJoinedBeforeComparison() {
        // Vision routinely splits a heading across observations; neither half alone resembles the name.
        let result = FuzzyText.bestSimilarity(
            observedFragments: ["STEEL", "CANYON", "GOLF CLUB"],
            candidateNames: ["Steel Canyon Golf Club"]
        )
        XCTAssertGreaterThan(result.score, 0.9)
    }

    func testCardRectConversionFromVisionCoordinates() {
        // Vision's origin is bottom-left; everything in this kit reads top-down.
        let rect = CardRect.fromBottomLeftOrigin(x: 0.1, y: 0.8, width: 0.2, height: 0.05)
        XCTAssertEqual(rect.minY, 0.15, accuracy: 1e-9, "A box near the top in Vision is near y=0 here")
        XCTAssertEqual(rect.minX, 0.1, accuracy: 1e-9)
    }
}
