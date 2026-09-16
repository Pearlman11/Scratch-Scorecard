import Foundation

/// Everything read off a card that could help identify which course it is.
///
/// Assembled by the parser from the detected table. Deliberately contains no player data: who played and
/// what they shot say nothing about which course this is, and letting scores influence identification
/// would be a route for a template to "confirm" itself against a golfer's handwriting.
/// One yardage row read off the card, with its printed tee name when the label was legible.
public struct ObservedYardageRow: Sendable {
    /// The tee name as printed, e.g. `Black`. `nil` when the label was missing or unreadable — in which
    /// case the tee is identified by matching the yardages themselves, never by assumption.
    public var teeName: String?
    /// Yardage per hole, index 0 == hole 1, `nil` for unread holes.
    public var values: [Int?]

    public init(teeName: String?, values: [Int?]) {
        self.teeName = teeName
        self.values = values
    }
}

public struct CourseMatchEvidence: Sendable {
    /// Text fragments from the card's heading area and any other non-grid text.
    public var nameFragments: [String]
    /// Hole numbers the layout detector found, or `nil` when no grid was reconstructed.
    public var detectedHoleCount: Int?
    /// Par per hole, index 0 == hole 1, `nil` for unread holes.
    public var parSequence: [Int?]
    /// Stroke index per hole, index 0 == hole 1.
    public var handicapSequence: [Int?]
    /// Every yardage row found, with its printed tee name when readable.
    public var yardageSequences: [ObservedYardageRow]
    public var outPar: Int?
    public var inPar: Int?
    public var totalPar: Int?

    public init(
        nameFragments: [String] = [],
        detectedHoleCount: Int? = nil,
        parSequence: [Int?] = [],
        handicapSequence: [Int?] = [],
        yardageSequences: [ObservedYardageRow] = [],
        outPar: Int? = nil,
        inPar: Int? = nil,
        totalPar: Int? = nil
    ) {
        self.nameFragments = nameFragments
        self.detectedHoleCount = detectedHoleCount
        self.parSequence = parSequence
        self.handicapSequence = handicapSequence
        self.yardageSequences = yardageSequences
        self.outPar = outPar
        self.inPar = inPar
        self.totalPar = totalPar
    }
}

/// One course's score against the evidence, with every signal kept separately.
///
/// The breakdown is preserved rather than collapsed into a single number so the debug inspector can show
/// *why* a course won, and so an ambiguous result can explain itself to the golfer.
public struct CourseMatchCandidate: Sendable, Identifiable {
    public var id: String { template.id }
    public var template: CourseTemplate

    public var nameScore: Double
    public var nameFragment: String?
    public var parResult: SequenceSimilarity.Result
    public var handicapResult: SequenceSimilarity.Result
    /// Best-scoring tee on this template, with that tee's yardage agreement.
    public var bestTeeName: String?
    public var teeResult: SequenceSimilarity.Result
    public var holeCountMatches: Bool?
    public var totalParScore: Double?

    /// Weighted combination, `0...1`.
    public var score: Double
    /// Sum of the weights that had evidence behind them. A course judged on its name alone is scored, but
    /// the low evidence weight is reported so the caller can refuse to act on it.
    public var evidenceWeight: Double

    public init(
        template: CourseTemplate,
        nameScore: Double,
        nameFragment: String?,
        parResult: SequenceSimilarity.Result,
        handicapResult: SequenceSimilarity.Result,
        bestTeeName: String?,
        teeResult: SequenceSimilarity.Result,
        holeCountMatches: Bool?,
        totalParScore: Double?,
        score: Double,
        evidenceWeight: Double
    ) {
        self.template = template
        self.nameScore = nameScore
        self.nameFragment = nameFragment
        self.parResult = parResult
        self.handicapResult = handicapResult
        self.bestTeeName = bestTeeName
        self.teeResult = teeResult
        self.holeCountMatches = holeCountMatches
        self.totalParScore = totalParScore
        self.score = score
        self.evidenceWeight = evidenceWeight
    }
}

/// What the matcher concluded.
public enum CourseMatchResolution: Sendable {
    /// One course clearly fits.
    case confident(CourseMatchCandidate)
    /// Several courses fit comparably well, or the best fit is not strong enough to act on alone.
    /// The golfer picks. The app must not choose for them.
    case ambiguous([CourseMatchCandidate])
    /// Nothing fits. The golfer picks from the full Georgia catalog.
    case noMatch

    public var confidentCandidate: CourseMatchCandidate? {
        if case .confident(let candidate) = self { return candidate }
        return nil
    }
}

public protocol CourseTemplateMatching: Sendable {
    func match(evidence: CourseMatchEvidence, templates: [CourseTemplate]) -> (resolution: CourseMatchResolution, ranked: [CourseMatchCandidate])
}

/// Scores every catalog template against the evidence and decides whether any of them wins.
public struct CourseTemplateMatcher: CourseTemplateMatching {

    public struct Configuration: Sendable {
        /// Weights for the four signals that can *identify* a course. They are normalized by the weight
        /// actually used, so a course whose template has no hole data is judged on the signals available
        /// rather than penalised for the catalog's gaps.
        public var nameWeight: Double
        public var parWeight: Double
        public var handicapWeight: Double
        public var yardageWeight: Double

        /// Name similarity below this is treated as *no evidence* rather than as evidence against.
        ///
        /// A course name is the most fragile thing on a card — small stylised type, often inside a logo —
        /// and a card whose name Vision could not read at all must still be identifiable from its par and
        /// stroke-index sequences. Scoring an unreadable name as zero would sink exactly the cards this
        /// matcher exists to rescue. Measured separation on real names is wide: genuine matches score 0.78
        /// and up even when badly damaged, unrelated Georgia courses that share a word ("Wolf Creek" vs
        /// "Sugar Creek") top out around 0.58.
        public var nameMatchFloor: Double

        /// Minimum combined score to declare a confident match.
        public var confidentThreshold: Double
        /// Minimum score to be worth offering as a possibility at all.
        public var candidateThreshold: Double
        /// If the runner-up is within this margin of the winner, the result is ambiguous rather than
        /// confident. Two courses that fit equally well must go to the golfer, never to a coin flip.
        public var ambiguityMargin: Double
        /// Fraction of the total weight that must be backed by real evidence before a confident match is
        /// allowed, unless the name alone was read clearly (see `strongNameScore`).
        public var minimumEvidenceWeight: Double
        /// A name match this good is identification on its own, which is what lets the app confidently
        /// recognise the fourteen catalog courses that ship with no hole data at all.
        public var strongNameScore: Double
        /// Multiplier applied when the card's hole count contradicts the template's.
        public var holeCountMismatchPenalty: Double

        public init(
            nameWeight: Double = 0.30,
            parWeight: Double = 0.28,
            handicapWeight: Double = 0.20,
            yardageWeight: Double = 0.14,
            nameMatchFloor: Double = 0.62,
            confidentThreshold: Double = 0.72,
            candidateThreshold: Double = 0.34,
            ambiguityMargin: Double = 0.07,
            minimumEvidenceWeight: Double = 0.40,
            strongNameScore: Double = 0.85,
            holeCountMismatchPenalty: Double = 0.55
        ) {
            self.nameWeight = nameWeight
            self.parWeight = parWeight
            self.handicapWeight = handicapWeight
            self.yardageWeight = yardageWeight
            self.nameMatchFloor = nameMatchFloor
            self.confidentThreshold = confidentThreshold
            self.candidateThreshold = candidateThreshold
            self.ambiguityMargin = ambiguityMargin
            self.minimumEvidenceWeight = minimumEvidenceWeight
            self.strongNameScore = strongNameScore
            self.holeCountMismatchPenalty = holeCountMismatchPenalty
        }

        var totalSignalWeight: Double {
            nameWeight + parWeight + handicapWeight + yardageWeight
        }
    }

    public var configuration: Configuration

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    public func match(
        evidence: CourseMatchEvidence,
        templates: [CourseTemplate]
    ) -> (resolution: CourseMatchResolution, ranked: [CourseMatchCandidate]) {
        let ranked = templates
            .map { score(template: $0, evidence: evidence) }
            .sorted { $0.score > $1.score }

        guard let best = ranked.first, best.score >= configuration.candidateThreshold else {
            return (.noMatch, ranked)
        }

        let plausible = ranked.filter { $0.score >= configuration.candidateThreshold }
        let runnerUp = plausible.dropFirst().first

        let isolated = runnerUp.map { best.score - $0.score > configuration.ambiguityMargin } ?? true
        // Either several independent signals agree, or the course's own name was read clearly.
        let wellEvidenced = best.evidenceWeight >= configuration.minimumEvidenceWeight
            || best.nameScore >= configuration.strongNameScore
        let strong = best.score >= configuration.confidentThreshold

        if strong && isolated && wellEvidenced {
            return (.confident(best), ranked)
        }
        return (.ambiguous(Array(plausible.prefix(5))), ranked)
    }

    // MARK: - Scoring

    func score(template: CourseTemplate, evidence: CourseMatchEvidence) -> CourseMatchCandidate {
        var weightedTotal = 0.0
        var usedWeight = 0.0

        // 1. Name. Abstains below the floor rather than contributing a zero — see `nameMatchFloor`.
        let nameMatch = FuzzyText.bestSimilarity(
            observedFragments: evidence.nameFragments,
            candidateNames: template.identity.matchableNames
        )
        let nameScore = nameMatch.score >= configuration.nameMatchFloor ? nameMatch.score : 0
        if nameScore > 0 {
            weightedTotal += nameScore * configuration.nameWeight
            usedWeight += configuration.nameWeight
        }

        // 2. Par sequence.
        let parResult = SequenceSimilarity.compare(observed: evidence.parSequence, expected: template.pars)
        if parResult.comparedCount >= 5 {
            weightedTotal += parResult.weightedScore * configuration.parWeight
            usedWeight += configuration.parWeight
        }

        // 3. Stroke index sequence.
        let handicapResult = SequenceSimilarity.compare(observed: evidence.handicapSequence, expected: template.handicapIndices)
        if handicapResult.comparedCount >= 5 {
            weightedTotal += handicapResult.weightedScore * configuration.handicapWeight
            usedWeight += configuration.handicapWeight
        }

        // 4. Yardages: best pairing of any observed row with any of the template's tees.
        var bestTeeName: String?
        var bestTeeResult = SequenceSimilarity.Result.none
        for observedRow in evidence.yardageSequences {
            for tee in template.teeSets {
                let result = SequenceSimilarity.compareYardages(observed: observedRow.values, expected: tee.yardages)
                guard result.comparedCount >= 4 else { continue }
                // A printed tee name that agrees breaks ties between tees with similar yardages.
                var adjusted = result
                if let printed = observedRow.teeName,
                   FuzzyText.similarity(printed, tee.name) >= 0.7 {
                    adjusted.score = min(1, result.score + 0.08)
                }
                if adjusted.weightedScore > bestTeeResult.weightedScore {
                    bestTeeResult = adjusted
                    bestTeeName = tee.name
                }
            }
        }
        if bestTeeResult.comparedCount >= 4 {
            weightedTotal += bestTeeResult.weightedScore * configuration.yardageWeight
            usedWeight += configuration.yardageWeight
        }

        // Normalize by the weight actually used.
        var score = usedWeight > 0 ? weightedTotal / usedWeight : 0

        // 5. Hole count and total par are *modifiers*, never standalone signals.
        //
        // This distinction is load-bearing. Normalizing by a signal that every 18-hole course satisfies
        // gave the fourteen identity-only catalog entries — which have no hole data whatsoever — a perfect
        // score against any 18-hole card, burying the one course that actually matched.
        var holeCountMatches: Bool?
        if let detected = evidence.detectedHoleCount, template.isHoleCountKnown {
            let matches = detected == template.holeCount
            holeCountMatches = matches
            if !matches { score *= configuration.holeCountMismatchPenalty }
        }

        var totalParScore: Double?
        if let observedTotal = evidence.totalPar, let expectedTotal = template.totalPar,
           let comparison = SequenceSimilarity.compareTotal(observed: observedTotal, expected: expectedTotal) {
            totalParScore = comparison
            // Agreement nudges up, disagreement nudges down. Corroboration, not identification.
            score = max(0, min(1, score + (comparison - 0.5) * 0.08))
        }

        return CourseMatchCandidate(
            template: template,
            nameScore: nameScore,
            nameFragment: nameScore > 0 ? nameMatch.fragment : nil,
            parResult: parResult,
            handicapResult: handicapResult,
            bestTeeName: bestTeeName,
            teeResult: bestTeeResult,
            holeCountMatches: holeCountMatches,
            totalParScore: totalParScore,
            score: score,
            evidenceWeight: configuration.totalSignalWeight > 0 ? usedWeight / configuration.totalSignalWeight : 0
        )
    }
}
