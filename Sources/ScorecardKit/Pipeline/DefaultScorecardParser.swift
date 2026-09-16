import Foundation

/// The parsing engine.
///
/// Runs, in order: layout reconstruction, static-data extraction, course identification, template-assisted
/// repair of static data, player-score extraction, and confidence evaluation. Each stage is a separate,
/// separately-testable type; this one owns only the orchestration and the rules about what a stage's output
/// is allowed to do to another stage's.
///
/// The rule that shapes the whole pipeline: **course identification runs on static data only, and template
/// repair applies to static data only.** Scores are extracted afterwards and never touched by a template.
public struct DefaultScorecardParser: ScorecardParsing {

    public var layoutDetector: ScorecardLayoutDetecting
    public var staticExtractor: StaticCourseDataExtractor
    public var matcher: CourseTemplateMatching
    public var scoreExtractor: PlayerScoreExtractor
    public var evaluator: ParsingConfidenceEvaluator
    public var parserName: String

    public init(
        layoutDetector: ScorecardLayoutDetecting = ScorecardLayoutDetector(),
        staticExtractor: StaticCourseDataExtractor = StaticCourseDataExtractor(),
        matcher: CourseTemplateMatching = CourseTemplateMatcher(),
        scoreExtractor: PlayerScoreExtractor = PlayerScoreExtractor(),
        evaluator: ParsingConfidenceEvaluator = ParsingConfidenceEvaluator(),
        parserName: String = "DefaultScorecardParser"
    ) {
        self.layoutDetector = layoutDetector
        self.staticExtractor = staticExtractor
        self.matcher = matcher
        self.scoreExtractor = scoreExtractor
        self.evaluator = evaluator
        self.parserName = parserName
    }

    public func parse(_ request: ScorecardParseRequest) async throws -> ScorecardParseOutcome {
        guard !request.observations.isEmpty else {
            throw ScorecardParsingError.noTextRecognized
        }

        var warnings: [ParseWarning] = []

        // 1. Rebuild the table.
        let table = layoutDetector.detectTable(from: request.observations)
        guard !table.sections.isEmpty, table.detectedHoleCount > 0 else {
            let scorecard = ParsedScorecard(
                warnings: [ParseWarning(
                    kind: .noScorecardTableDetected,
                    severity: .blocking,
                    detail: "No hole-number row was found, so the card's grid could not be reconstructed."
                )],
                overallConfidence: 0,
                quality: .failed,
                parserName: parserName
            )
            return ScorecardParseOutcome(
                scorecard: scorecard,
                debugReport: request.collectsDebugReport ? debugReport(request: request, table: table, staticData: nil, ranked: [], appliedTemplate: nil, appliedTee: nil) : nil
            )
        }

        // 2. Pull out the printed course data.
        let staticData = staticExtractor.extract(from: table)
        let holeCount = staticData.holeCount

        // 3. Identify the course from static data alone.
        let evidence = CourseMatchEvidence(
            nameFragments: staticData.nameFragments,
            detectedHoleCount: holeCount,
            parSequence: staticData.pars,
            handicapSequence: staticData.handicapIndices,
            yardageSequences: staticData.yardageRows,
            outPar: staticData.outPar,
            inPar: staticData.inPar,
            totalPar: staticData.totalPar
        )

        var appliedTemplate: CourseTemplate?
        var courseConfidence = 0.0
        var alternateIDs: [String] = []
        var ranked: [CourseMatchCandidate] = []
        var matchedTeeName: String?

        if let forcedID = request.forcedTemplateID,
           let forced = request.templates.first(where: { $0.id == forcedID }) {
            // The golfer named the course. That is stronger than any signal we could compute.
            appliedTemplate = forced
            courseConfidence = 1.0
            ranked = [matcherCandidate(for: forced, evidence: evidence)]
        } else {
            let outcome = matcher.match(evidence: evidence, templates: request.templates)
            ranked = outcome.ranked
            switch outcome.resolution {
            case .confident(let candidate):
                appliedTemplate = candidate.template
                courseConfidence = candidate.score
                matchedTeeName = candidate.bestTeeName
            case .ambiguous(let candidates):
                alternateIDs = candidates.map(\.template.id)
                courseConfidence = candidates.first?.score ?? 0
                warnings.append(ParseWarning(
                    kind: candidates.count > 1 ? .multipleCourseMatches : .courseMatchLowConfidence,
                    severity: .warning,
                    detail: candidates.count > 1
                        ? "Several Georgia courses fit this card. Pick the right one: \(candidates.prefix(3).map(\.template.identity.displayName).joined(separator: ", "))."
                        : "The course could not be identified confidently. Confirm it before saving."
                ))
            case .noMatch:
                courseConfidence = 0
                warnings.append(ParseWarning(
                    kind: staticData.nameFragments.isEmpty ? .courseNameUnreadable : .courseNotInCatalog,
                    severity: .warning,
                    detail: staticData.nameFragments.isEmpty
                        ? "The course name could not be read. Choose the course by hand."
                        : "This card does not match any course in the Georgia catalog. Choose the course by hand."
                ))
            }
        }

        // 4. Choose the tee. See `resolveTee` — a card that prints three tees cannot say which was played.
        var teeName = request.forcedTeeName ?? matchedTeeName
        var teeConfidence = request.forcedTeeName == nil ? 0.0 : 1.0
        if let template = appliedTemplate {
            let resolution = resolveTee(
                template: template,
                staticData: staticData,
                forcedTeeName: request.forcedTeeName,
                matcherSuggestion: matchedTeeName
            )
            teeName = resolution.teeName
            teeConfidence = resolution.confidence
            if let extra = resolution.warning { warnings.append(extra) }
        } else if teeName == nil, let printed = staticData.yardageRows.compactMap(\.teeName).first {
            teeName = printed
            teeConfidence = 0.7
        }

        // 5. Build the holes: OCR first, template repair second, and only for static fields.
        var holes = buildHoles(holeCount: holeCount, staticData: staticData, teeName: teeName)
        if let template = appliedTemplate, template.mayRestoreStaticData {
            let repaired = applyTemplate(template, teeName: teeName, to: holes)
            holes = repaired.holes
            if repaired.correctedCount > 0 {
                warnings.append(ParseWarning(
                    kind: .templateFilledStaticData,
                    severity: .info,
                    detail: "\(repaired.correctedCount) printed course value\(repaired.correctedCount == 1 ? "" : "s") were filled or corrected from the verified \(template.identity.displayName) card."
                ))
            }
        }

        // 6. Extract the golfers' scores. This happens after template repair and is entirely unaffected by
        //    it — pars are passed only so an impossible reading can be rejected.
        let players = scoreExtractor.extractPlayers(
            from: table,
            holeCount: holeCount,
            pars: holes.map(\.par.value)
        )

        var scorecard = ParsedScorecard(
            candidateCourse: appliedTemplate?.identity,
            candidateLayoutName: appliedTemplate?.identity.layoutName,
            candidateTee: teeName,
            teeConfidence: teeConfidence,
            courseConfidence: courseConfidence,
            alternateCourseIDs: alternateIDs,
            appliedTemplateID: appliedTemplate?.id,
            appliedTemplateVersion: appliedTemplate?.templateVersion,
            holeCount: holeCount,
            holes: holes,
            detectedPlayers: players,
            selectedPlayerID: players.count == 1 ? players[0].id : nil,
            parserName: parserName
        )
        // A single detected row is adopted automatically; with several, the golfer says which one is theirs
        // and the card's scores stay empty until they do.
        if let onlyPlayer = players.first, players.count == 1 {
            scorecard.selectPlayer(id: onlyPlayer.id)
        }

        let assessment = evaluator.evaluate(
            holes: scorecard.holes,
            holeCount: holeCount,
            players: players,
            courseConfidence: courseConfidence,
            courseResolved: appliedTemplate != nil,
            existingWarnings: warnings
        )
        scorecard.warnings = assessment.warnings
        scorecard.overallConfidence = assessment.overallConfidence
        scorecard.quality = assessment.quality

        return ScorecardParseOutcome(
            scorecard: scorecard,
            debugReport: request.collectsDebugReport
                ? debugReport(request: request, table: table, staticData: staticData, ranked: ranked, appliedTemplate: appliedTemplate, appliedTee: teeName)
                : nil
        )
    }

    // MARK: - Hole construction

    /// Builds holes from what OCR actually read. No template is involved at this stage.
    func buildHoles(holeCount: Int, staticData: ExtractedStaticData, teeName: String?) -> [ParsedHole] {
        // Pick the yardage row for the chosen tee; with no tee chosen, the first row read is used and its
        // values are marked as OCR so the review screen can still show them.
        var yardageIndex: Int?
        if let teeName {
            yardageIndex = staticData.yardageRows.firstIndex {
                guard let printed = $0.teeName else { return false }
                return FuzzyText.similarity(printed, teeName) >= 0.7
            }
        }
        if yardageIndex == nil, !staticData.yardageRows.isEmpty {
            yardageIndex = 0
        }

        return (1...max(1, holeCount)).map { holeNumber in
            let index = holeNumber - 1
            var hole = ParsedHole(holeNumber: holeNumber)

            if staticData.pars.indices.contains(index), let par = staticData.pars[index] {
                hole.par = .ocr(
                    par,
                    confidence: staticData.parConfidences[index] ?? 0.5,
                    rawText: staticData.parRawText[index]
                )
            }
            if staticData.handicapIndices.indices.contains(index), let handicap = staticData.handicapIndices[index] {
                hole.handicapIndex = .ocr(
                    handicap,
                    confidence: staticData.handicapConfidences[index] ?? 0.5,
                    rawText: staticData.handicapRawText[index]
                )
            }
            if let yardageIndex,
               staticData.yardageRows.indices.contains(yardageIndex),
               staticData.yardageRows[yardageIndex].values.indices.contains(index),
               let yards = staticData.yardageRows[yardageIndex].values[index] {
                hole.yardage = .ocr(
                    yards,
                    confidence: staticData.yardageConfidences[yardageIndex][index] ?? 0.5,
                    rawText: staticData.yardageRawText[yardageIndex][index]
                )
            }
            return hole
        }
    }

    /// Repairs and completes static fields from a verified template.
    ///
    /// This is the payoff for identifying the course: a yardage OCR read as `33B` becomes `333` because the
    /// template says hole 16 from the White tees is 333 yards, and a par cell lost to a crease is filled in.
    ///
    /// Three constraints keep it honest:
    /// - It touches `yardage`, `par` and `handicapIndex` only. There is no branch here that can reach a score.
    /// - It runs only for a template whose data is verified (`mayRestoreStaticData`).
    /// - It never overwrites a value the golfer typed.
    func applyTemplate(
        _ template: CourseTemplate,
        teeName: String?,
        to holes: [ParsedHole]
    ) -> (holes: [ParsedHole], correctedCount: Int) {
        let tee = teeName.flatMap { template.teeSet(named: $0) }
        var corrected = 0
        var result = holes

        for index in result.indices {
            let holeNumber = result[index].holeNumber

            if let par = template.par(forHole: holeNumber), result[index].par.provenance != .userEdited {
                if result[index].par.value != par { corrected += 1 }
                result[index].par = .template(par)
            }
            if let handicap = template.handicapIndex(forHole: holeNumber), result[index].handicapIndex.provenance != .userEdited {
                if result[index].handicapIndex.value != handicap { corrected += 1 }
                result[index].handicapIndex = .template(handicap)
            }
            if let tee, let yards = tee.yardage(forHole: holeNumber), result[index].yardage.provenance != .userEdited {
                if result[index].yardage.value != yards { corrected += 1 }
                result[index].yardage = .template(yards)
            }
        }
        return (result, corrected)
    }

    // MARK: - Tee resolution

    /// What the parser concluded about the tee.
    struct TeeResolution {
        var teeName: String?
        /// `0...1`. Low means "this is a provisional default, ask the golfer".
        var confidence: Double
        var warning: ParseWarning?
    }

    /// Decides which tee the card was played from.
    ///
    /// ## Why this cannot usually be answered from the card
    ///
    /// A scorecard prints *every* tee — Steel Canyon's card carries Black, White and Red yardage rows, and
    /// all three are equally legible. Nothing on the card records which set the golfer actually teed off
    /// from. So matching yardages identifies which tees the course *offers*, not which one was played, and
    /// treating a good yardage match as a tee identification would silently attach the wrong yardages to
    /// every hole of the round.
    ///
    /// The resolution, in order:
    /// 1. The golfer's own choice (including a tee remembered from their last round here) — authoritative.
    /// 2. Exactly one yardage row on the card — then there is no ambiguity to resolve.
    /// 3. Several yardage rows — a provisional middle tee is offered at low confidence with an explicit
    ///    warning, so the review screen asks. The yardages shown are correct *for that tee*; it is the tee
    ///    selection that is uncertain, and switching it refreshes them from the template in one tap.
    /// 4. Nothing matched — no tee, and a warning saying so.
    func resolveTee(
        template: CourseTemplate,
        staticData: ExtractedStaticData,
        forcedTeeName: String?,
        matcherSuggestion: String?
    ) -> TeeResolution {
        if let forcedTeeName {
            return TeeResolution(teeName: forcedTeeName, confidence: 1.0, warning: nil)
        }
        guard !template.teeSets.isEmpty else {
            // The template has no tee data (an identity-only catalog entry). A tee name printed on the card
            // is still the best available answer, and the yardages stay as OCR read them.
            if let printed = staticData.yardageRows.compactMap(\.teeName).first {
                return TeeResolution(teeName: printed, confidence: 0.7, warning: nil)
            }
            return TeeResolution(teeName: nil, confidence: 0, warning: nil)
        }

        // Best yardage agreement for each of the template's tees.
        var perTee: [(name: String, score: Double)] = []
        for tee in template.teeSets {
            var best = 0.0
            for row in staticData.yardageRows {
                let result = SequenceSimilarity.compareYardages(observed: row.values, expected: tee.yardages)
                guard result.comparedCount >= 3 else { continue }
                best = max(best, result.weightedScore)
            }
            perTee.append((tee.name, best))
        }
        let matched = perTee.filter { $0.score >= 0.55 }

        if matched.isEmpty {
            // No yardages matched. A printed label naming one of the template's tees is still usable.
            for row in staticData.yardageRows {
                guard let printed = row.teeName else { continue }
                if let tee = template.teeSets.first(where: { FuzzyText.similarity(printed, $0.name) >= 0.7 }) {
                    return TeeResolution(teeName: tee.name, confidence: 0.55, warning: nil)
                }
            }
            return TeeResolution(
                teeName: matcherSuggestion,
                confidence: matcherSuggestion == nil ? 0 : 0.3,
                warning: ParseWarning(
                    kind: .teeNotIdentified,
                    severity: .warning,
                    detail: "No yardage row on this card could be matched to a tee. Choose the tee you played to fill in yardages."
                )
            )
        }

        if matched.count == 1 {
            return TeeResolution(teeName: matched[0].name, confidence: 0.90, warning: nil)
        }

        // The card prints several tees, as real cards do. Offer the middle set by total length — the most
        // commonly played on a public course — and say plainly that it is a default, not a reading.
        let byLength = matched
            .sorted { lhs, rhs in
                let lhsTotal = template.teeSet(named: lhs.name)?.totalYardage ?? 0
                let rhsTotal = template.teeSet(named: rhs.name)?.totalYardage ?? 0
                return lhsTotal < rhsTotal
            }
        let provisional = byLength[byLength.count / 2].name
        return TeeResolution(
            teeName: provisional,
            confidence: 0.30,
            warning: ParseWarning(
                kind: .multipleTeeMatches,
                severity: .warning,
                detail: "This card prints \(matched.count) sets of tees, so it cannot say which you played. Showing \(provisional) — tap to change."
            )
        )
    }

    private func matcherCandidate(for template: CourseTemplate, evidence: CourseMatchEvidence) -> CourseMatchCandidate {
        CourseTemplateMatcher().score(template: template, evidence: evidence)
    }

    // MARK: - Debug

    func debugReport(
        request: ScorecardParseRequest,
        table: DetectedTable,
        staticData: ExtractedStaticData?,
        ranked: [CourseMatchCandidate],
        appliedTemplate: CourseTemplate?,
        appliedTee: String?
    ) -> ParserDebugReport {
        var rowSummaries: [ParserDebugReport.RowSummary] = []
        for row in table.rows {
            let cells: [String]
            if let section = table.section(for: row) {
                cells = TableCellReader.holeCells(in: row, section: section).map { $0.isEmpty ? "·" : $0.text }
            } else {
                cells = row.observations.map(\.trimmed)
            }
            rowSummaries.append(ParserDebugReport.RowSummary(
                index: row.index,
                rect: row.rect,
                role: row.role.debugDescription,
                roleConfidence: row.roleConfidence,
                labelText: row.labelText,
                meanOCRConfidence: row.meanConfidence,
                heightUniformity: row.heightUniformity,
                sectionIndex: row.sectionIndex,
                cellTexts: cells
            ))
        }

        var columnSummaries: [ParserDebugReport.ColumnSummary] = []
        for section in table.sections {
            for column in section.holeColumns {
                columnSummaries.append(ParserDebugReport.ColumnSummary(
                    sectionIndex: section.index,
                    label: "H\(column.holeNumber)",
                    minX: column.minX,
                    maxX: column.maxX,
                    centerX: column.centerX,
                    isInterpolated: column.isInterpolated
                ))
            }
            for column in section.aggregateColumns {
                columnSummaries.append(ParserDebugReport.ColumnSummary(
                    sectionIndex: section.index,
                    label: column.kind.rawValue.uppercased(),
                    minX: column.minX,
                    maxX: column.maxX,
                    centerX: column.centerX,
                    isInterpolated: false
                ))
            }
        }

        return ParserDebugReport(
            observations: request.observations,
            deskewedObservations: table.rows.flatMap(\.observations),
            skewDegrees: table.skewRadians * 180 / .pi,
            medianTextHeight: table.medianTextHeight,
            rows: rowSummaries,
            columns: columnSummaries,
            courseCandidates: ranked.prefix(8).map { candidate in
                ParserDebugReport.CourseCandidateSummary(
                    templateID: candidate.template.id,
                    displayName: candidate.template.identity.displayName,
                    totalScore: candidate.score,
                    nameScore: candidate.nameScore,
                    matchedFragment: candidate.nameFragment,
                    parScore: candidate.parResult.score,
                    parCompared: candidate.parResult.comparedCount,
                    handicapScore: candidate.handicapResult.score,
                    handicapCompared: candidate.handicapResult.comparedCount,
                    bestTeeName: candidate.bestTeeName,
                    teeScore: candidate.teeResult.score,
                    teeCompared: candidate.teeResult.comparedCount,
                    holeCountMatches: candidate.holeCountMatches,
                    evidenceWeight: candidate.evidenceWeight
                )
            },
            playerRowIndices: table.playerRows.map(\.index),
            nameFragments: staticData?.nameFragments ?? [],
            extractedPars: staticData?.pars ?? [],
            extractedHandicaps: staticData?.handicapIndices ?? [],
            extractedYardageRows: staticData?.yardageRows ?? [],
            appliedTemplateID: appliedTemplate?.id,
            appliedTeeName: appliedTee
        )
    }
}
