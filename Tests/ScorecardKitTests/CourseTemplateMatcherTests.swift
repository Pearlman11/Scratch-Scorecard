import XCTest
@testable import ScorecardKit

/// Tests for course identification, driven straight from evidence so each signal can be isolated.
final class CourseTemplateMatcherTests: XCTestCase {

    private let matcher = CourseTemplateMatcher()
    private var catalog: [CourseTemplate] { GeorgiaCourseCatalog.templates }

    private func steelCanyonEvidence(
        nameFragments: [String] = ["STEEL CANYON GOLF CLUB"],
        pars: [Int?]? = nil,
        handicaps: [Int?]? = nil,
        yardages: [ObservedYardageRow]? = nil,
        holeCount: Int? = 18,
        totalPar: Int? = 61
    ) -> CourseMatchEvidence {
        CourseMatchEvidence(
            nameFragments: nameFragments,
            detectedHoleCount: holeCount,
            parSequence: pars ?? SteelCanyonTemplate.pars.map { Optional($0) },
            handicapSequence: handicaps ?? SteelCanyonTemplate.handicapIndices.map { Optional($0) },
            yardageSequences: yardages ?? [
                ObservedYardageRow(teeName: "White", values: SteelCanyonTemplate.whiteYardages.map { Optional($0) })
            ],
            totalPar: totalPar
        )
    }

    func testCleanEvidenceIdentifiesSteelCanyonConfidently() {
        let (resolution, ranked) = matcher.match(evidence: steelCanyonEvidence(), templates: catalog)
        guard let candidate = resolution.confidentCandidate else {
            return XCTFail("Clean Steel Canyon evidence must produce a confident match")
        }
        XCTAssertEqual(candidate.template.id, "ga-steel-canyon")
        XCTAssertEqual(ranked.first?.template.id, "ga-steel-canyon")
        XCTAssertGreaterThan(ranked[0].score - ranked[1].score, 0.2, "The winner should be well clear")
    }

    func testParAndHandicapSequencesIdentifyTheCourseWithNoNameAtAll() {
        let (resolution, _) = matcher.match(
            evidence: steelCanyonEvidence(nameFragments: []),
            templates: catalog
        )
        XCTAssertEqual(resolution.confidentCandidate?.template.id, "ga-steel-canyon")
    }

    func testAnUnreadableNameDoesNotCountAgainstTheCourse() {
        // The name is present but resembles nothing. Treating that as a zero would sink a card whose par
        // and stroke-index sequences match perfectly, which is precisely the case this matcher exists for.
        let (resolution, ranked) = matcher.match(
            evidence: steelCanyonEvidence(nameFragments: ["XQZW MNBVC PLKJH"]),
            templates: catalog
        )
        XCTAssertEqual(resolution.confidentCandidate?.template.id, "ga-steel-canyon")
        XCTAssertEqual(ranked.first?.nameScore, 0, "An unrelated string must abstain, not score")
    }

    func testDamagedSequencesStillIdentifyTheCourse() {
        // Five printed values misread across par, stroke index and yardage, plus a damaged name.
        var pars: [Int?] = SteelCanyonTemplate.pars.map { Optional($0) }
        pars[5] = 3          // the par 5 read as a 3
        pars[10] = nil       // one par never read
        var handicaps: [Int?] = SteelCanyonTemplate.handicapIndices.map { Optional($0) }
        handicaps[4] = 12    // 17 read as 12
        handicaps[9] = nil
        var yards: [Int?] = SteelCanyonTemplate.whiteYardages.map { Optional($0) }
        yards[15] = 338      // 333 read as 338
        yards[2] = nil

        let (resolution, _) = matcher.match(
            evidence: steelCanyonEvidence(
                nameFragments: ["STEE CANYQN GOLE CLUB"],
                pars: pars,
                handicaps: handicaps,
                yardages: [ObservedYardageRow(teeName: nil, values: yards)]
            ),
            templates: catalog
        )
        XCTAssertEqual(resolution.confidentCandidate?.template.id, "ga-steel-canyon")
    }

    func testIdentityOnlyCoursesDoNotWinOnHoleCountAlone() {
        // Fourteen catalog entries have no hole data. Matching an 18-hole card against them must produce
        // no score, not a perfect one — the failure this guards against buried the correct course.
        let (_, ranked) = matcher.match(evidence: steelCanyonEvidence(nameFragments: []), templates: catalog)
        for candidate in ranked where candidate.template.id != "ga-steel-canyon" {
            XCTAssertEqual(
                candidate.score, 0, accuracy: 0.001,
                "\(candidate.template.id) scored on no evidence at all"
            )
        }
    }

    func testAnIdentityOnlyCourseIsIdentifiedByItsNameAlone() {
        // Wolf Creek ships with no pars or yardages; a clearly-read name is still an identification.
        let evidence = CourseMatchEvidence(
            nameFragments: ["WOLF CREEK GOLF CLUB", "ATLANTA, GEORGIA"],
            detectedHoleCount: 18,
            parSequence: [4, 3, 5, 4, 3, 4, 5, 3, 4, 4, 3, 4, 5, 3, 4, 4, 3, 4].map { Optional($0) },
            handicapSequence: [],
            yardageSequences: []
        )
        let (resolution, _) = matcher.match(evidence: evidence, templates: catalog)
        XCTAssertEqual(resolution.confidentCandidate?.template.id, "ga-wolf-creek")
    }

    func testAnUnknownCourseIsNotMatchedToSomethingPlausible() {
        let evidence = CourseMatchEvidence(
            nameFragments: ["PINE NINE GOLF COURSE"],
            detectedHoleCount: 9,
            parSequence: [4, 3, 4, 3, 4, 4, 3, 4, 4].map { Optional($0) },
            handicapSequence: [3, 9, 1, 7, 5, 4, 8, 2, 6].map { Optional($0) },
            yardageSequences: []
        )
        let (resolution, _) = matcher.match(evidence: evidence, templates: catalog)
        XCTAssertNil(resolution.confidentCandidate, "An unknown course must never be confidently matched")
    }

    func testHoleCountMismatchPenalisesAMatch() {
        // Steel Canyon's own sequences, but only nine holes were detected.
        let nineHoleEvidence = CourseMatchEvidence(
            nameFragments: [],
            detectedHoleCount: 9,
            parSequence: Array(SteelCanyonTemplate.pars.prefix(9)).map { Optional($0) },
            handicapSequence: Array(SteelCanyonTemplate.handicapIndices.prefix(9)).map { Optional($0) },
            yardageSequences: []
        )
        let penalised = matcher.score(template: SteelCanyonTemplate.template, evidence: nineHoleEvidence)
        XCTAssertEqual(penalised.holeCountMatches, false)

        var full = nineHoleEvidence
        full.detectedHoleCount = 18
        let unpenalised = matcher.score(template: SteelCanyonTemplate.template, evidence: full)
        XCTAssertLessThan(penalised.score, unpenalised.score)
    }

    func testTwoEquallyGoodMatchesAreReportedAsAmbiguous() {
        // A deliberately cloned template: identical hole data, a different name. Nothing can separate them
        // on sequence evidence, so the golfer must choose.
        var clone = SteelCanyonTemplate.template
        clone.identity = CourseIdentity(
            id: "ga-test-twin",
            name: "Twin Canyon Golf Club",
            facilityName: "Twin Canyon Golf Club",
            city: "Sandy Springs"
        )
        let templates = [SteelCanyonTemplate.template, clone]
        let (resolution, _) = matcher.match(
            evidence: steelCanyonEvidence(nameFragments: []),
            templates: templates
        )
        guard case .ambiguous(let candidates) = resolution else {
            return XCTFail("Two indistinguishable courses must be reported as ambiguous")
        }
        XCTAssertEqual(candidates.count, 2)
    }

    func testTheBestTeeIsReportedAlongsideTheMatch() {
        let evidence = steelCanyonEvidence(
            yardages: [ObservedYardageRow(teeName: nil, values: SteelCanyonTemplate.redYardages.map { Optional($0) })]
        )
        let candidate = matcher.score(template: SteelCanyonTemplate.template, evidence: evidence)
        XCTAssertEqual(candidate.bestTeeName, "Red")
        XCTAssertEqual(candidate.teeResult.exactCount, 18)
    }

    func testSequenceComparisonAbstainsRatherThanScoringZeroWhenNothingWasRead() {
        let result = SequenceSimilarity.compare(observed: [nil, nil, nil], expected: [4, 4, 3])
        XCTAssertEqual(result.comparedCount, 0)
        XCTAssertEqual(result.score, 0)
        XCTAssertEqual(result.coverage, 0)
    }

    func testCoverageWeightsPartialSequences() {
        // One hole agreeing is not evidence; eighteen agreeing is.
        var sparse = [Int?](repeating: nil, count: 18)
        sparse[0] = 4
        let sparseResult = SequenceSimilarity.compare(observed: sparse, expected: SteelCanyonTemplate.template.pars)
        let fullResult = SequenceSimilarity.compare(
            observed: SteelCanyonTemplate.pars.map { Optional($0) },
            expected: SteelCanyonTemplate.template.pars
        )
        XCTAssertEqual(sparseResult.score, 1.0, "The one hole read did agree")
        XCTAssertLessThan(sparseResult.weightedScore, 0.1, "But it carries almost no weight")
        XCTAssertEqual(fullResult.weightedScore, 1.0, accuracy: 0.001)
    }
}
