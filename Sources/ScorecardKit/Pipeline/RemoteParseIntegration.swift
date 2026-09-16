import Foundation

/// Merges a remote reading into a locally-parsed card.
///
/// The merge is one-directional and narrow on purpose: a remote result may fill a score the local parser
/// left empty, or replace one it read poorly, and nothing else. It cannot touch par, stroke index, yardage
/// or the course — those already come from a verified template or from printed text the local parser read
/// well, and a remote model is not a better source for them.
public enum RemoteParseMerger {

    /// - Parameters:
    ///   - minimumRemoteConfidence: readings below this are ignored entirely.
    ///   - improvementMargin: how much more confident the remote must be before it replaces a value the
    ///     local parser already read.
    ///
    ///     The margin matters because handwritten scores are *never* read confidently by on-device OCR —
    ///     every one of them lands around 0.5. Without a margin, any remote reading clearing the minimum
    ///     would overwrite every score on the card, including the ones the local parser got right, on what
    ///     amounts to a coin flip. The remote has to be clearly better, not nominally better.
    /// - Returns: the merged card and which holes the remote reading actually changed.
    public static func merge(
        payload: RemoteScorecardPayload,
        into scorecard: ParsedScorecard,
        minimumRemoteConfidence: Double = 0.6,
        improvementMargin: Double = 0.15
    ) -> (scorecard: ParsedScorecard, updatedHoles: [Int]) {
        guard let player = payload.players.first else { return (scorecard, []) }
        return merge(
            player: player,
            into: scorecard,
            confidenceCeiling: 1.0,
            minimumRemoteConfidence: minimumRemoteConfidence,
            improvementMargin: improvementMargin
        )
    }

    /// Merges one row, with an audit-derived ceiling on how far it may be believed.
    public static func merge(
        player: RemoteScorecardPayload.Player,
        into scorecard: ParsedScorecard,
        confidenceCeiling: Double,
        minimumRemoteConfidence: Double = 0.6,
        improvementMargin: Double = 0.15
    ) -> (scorecard: ParsedScorecard, updatedHoles: [Int]) {
        var result = scorecard
        var updated: [Int] = []

        for remoteHole in player.holes {
            guard let index = result.holes.firstIndex(where: { $0.holeNumber == remoteHole.holeNumber }) else { continue }
            let existing = result.holes[index].playerScore

            // The golfer's own correction always wins.
            guard existing.provenance != .userEdited else { continue }
            guard let remoteScore = remoteHole.playerScore else { continue }
            guard ScoreMath.plausibleScoreRange.contains(remoteScore) else { continue }
            let remoteConfidence = min(remoteHole.confidence ?? 0.5, confidenceCeiling)
            guard remoteConfidence >= minimumRemoteConfidence else { continue }
            // An empty cell has nothing to lose, so any acceptable reading fills it. Replacing a value the
            // local parser did read requires clearing the margin above.
            if existing.value != nil {
                guard remoteConfidence >= existing.confidence + improvementMargin else { continue }
            }

            let field = ParsedField(
                value: remoteScore,
                confidence: remoteConfidence,
                provenance: .multimodalFallback,
                rawText: existing.rawText
            )
            result.holes[index].playerScore = field
            if let playerIndex = result.detectedPlayers.firstIndex(where: { $0.id == result.selectedPlayer?.id }),
               result.detectedPlayers[playerIndex].scores.indices.contains(remoteHole.holeNumber - 1) {
                result.detectedPlayers[playerIndex].scores[remoteHole.holeNumber - 1] = field
            }
            updated.append(remoteHole.holeNumber)
        }
        return (result, updated)
    }

    /// Turns remote rows into `DetectedPlayer`s on a card where local OCR found none.
    ///
    /// This is the case the remote parser exists for. Vision's recognizer is trained on print, and on a
    /// pencil-written card it can return every printed row while detecting *no* handwriting whatsoever —
    /// leaving the app with a perfect course template and an empty grid. There is nothing for the merge
    /// above to improve on, because there is no row to improve.
    public static func adoptPlayers(
        from payload: RemoteScorecardPayload,
        into scorecard: ParsedScorecard,
        confidenceCeilings: [Double]
    ) -> (scorecard: ParsedScorecard, adopted: [DetectedPlayer]) {
        var result = scorecard
        var adopted: [DetectedPlayer] = []

        for (offset, player) in payload.players.enumerated() {
            let ceiling = confidenceCeilings.indices.contains(offset) ? confidenceCeilings[offset] : RemoteConfidencePolicy.unverifiedCeiling
            let scores: [ParsedField<Int>] = (1...max(scorecard.holeCount, 1)).map { holeNumber in
                guard let hole = player.hole(holeNumber),
                      let score = hole.playerScore,
                      ScoreMath.plausibleScoreRange.contains(score) else { return .empty }
                return ParsedField(
                    value: score,
                    confidence: min(hole.confidence ?? 0.5, ceiling),
                    provenance: .multimodalFallback
                )
            }
            // A row the model returned nothing legible for is not a golfer, it is an empty line on the card.
            guard scores.contains(where: \.hasValue) else { continue }

            let trimmedName = player.name?.trimmingCharacters(in: .whitespacesAndNewlines)
            adopted.append(DetectedPlayer(
                name: (trimmedName?.isEmpty == false) ? trimmedName : nil,
                fallbackLabel: "Player \(result.detectedPlayers.count + adopted.count + 1)",
                sourceRowIndex: nil,
                scores: scores,
                rowConfidence: min(ceiling, 0.9),
                writtenOut: subtotalField(player.writtenOut, ceiling: ceiling),
                writtenIn: subtotalField(player.writtenIn, ceiling: ceiling),
                writtenTotal: subtotalField(player.writtenTotal, ceiling: ceiling)
            ))
        }

        result.detectedPlayers.append(contentsOf: adopted)
        return (result, adopted)
    }

    private static func subtotalField(_ value: Int?, ceiling: Double) -> ParsedField<Int> {
        guard let value else { return .empty }
        return ParsedField(value: value, confidence: min(0.85, ceiling), provenance: .multimodalFallback)
    }
}

/// Runs a remote reading through the audit, the merge and the card's own arithmetic, in that order.
///
/// This is the single entry point the app calls, and the order is the point of it:
///
/// 1. **Audit** each returned row against the subtotals written beside it (`RemoteScoreAudit`). A model's
///    answer is checked before it is used, not after.
/// 2. **Adopt or merge**, capped at whatever confidence the audit justifies. On a card where local OCR
///    found no handwriting at all, the rows are adopted wholesale; where it found some, the remote may
///    only fill gaps and replace weak reads.
/// 3. **Solve** with `ScoreChecksumSolver`, exactly as for a local parse. The arithmetic gets the last
///    word — including the power to overwrite a contradicted remote reading, since the audit has already
///    pushed those below the solver's overwrite threshold.
/// 4. **Re-evaluate** confidence and quality from the merged card, so the review screen reflects what is
///    actually there rather than what the first pass found.
public enum RemoteParseIntegrator {

    /// One row's audit result, for the review screen to explain.
    public struct RowAudit: Sendable {
        public var playerName: String
        public var verdict: RemoteScoreAudit.Verdict

        public init(playerName: String, verdict: RemoteScoreAudit.Verdict) {
            self.playerName = playerName
            self.verdict = verdict
        }
    }

    public struct Outcome: Sendable {
        public var scorecard: ParsedScorecard
        /// Holes whose score the remote reading changed.
        public var updatedHoles: [Int]
        /// Rows created from the remote reading because local OCR found none.
        public var adoptedPlayerIDs: [UUID]
        public var audits: [RowAudit]

        /// Whether the remote reading actually contributed anything.
        public var changedAnything: Bool { !updatedHoles.isEmpty || !adoptedPlayerIDs.isEmpty }
    }

    /// Warnings this pass owns, cleared before it re-adds its own so a second run does not stack them up.
    private static let ownedWarningKinds: Set<ParseWarning.Kind> = [
        .parRowNotFound, .handicapRowNotFound, .yardageRowNotFound,
        .playerCountNeedsConfirmation, .noPlayerRowsDetected,
        .someScoresMissing, .someScoresLowConfidence,
        .nineHoleRoundDetected, .holeCountMismatch, .cardLikelyCropped,
        .incompleteRound, .remoteParserUnavailable
    ]

    public static func integrate(
        payload: RemoteScorecardPayload,
        into scorecard: ParsedScorecard
    ) -> Outcome {
        var result = scorecard
        var audits: [RowAudit] = []
        var updatedHoles: [Int] = []
        var adoptedIDs: [UUID] = []

        guard !payload.players.isEmpty, result.holeCount > 0 else {
            result.warnings.append(ParseWarning(
                kind: .noPlayerRowsDetected,
                severity: .warning,
                detail: "The photo was read, but no handwritten score row was found in it. Enter your scores directly.",
                holeNumbers: []
            ))
            return Outcome(scorecard: result, updatedHoles: [], adoptedPlayerIDs: [], audits: [])
        }

        // 1. Audit every returned row before any of it is believed.
        var ceilings: [Double] = []
        for player in payload.players {
            let local = matchingLocalPlayer(for: player, in: result)
            let verdict = RemoteScoreAudit.audit(player: player, against: local, holeCount: result.holeCount)
            ceilings.append(RemoteConfidencePolicy.ceiling(for: verdict))
            audits.append(RowAudit(
                playerName: displayName(for: player, fallbackIndex: audits.count + 1),
                verdict: verdict
            ))
        }

        // 2. Adopt or merge.
        if result.detectedPlayers.isEmpty {
            let (withPlayers, adopted) = RemoteParseMerger.adoptPlayers(
                from: payload,
                into: result,
                confidenceCeilings: ceilings
            )
            result = withPlayers
            adoptedIDs = adopted.map(\.id)
            if adopted.count == 1, let only = adopted.first {
                result.selectPlayer(id: only.id)
                updatedHoles = result.holes.filter { $0.playerScore.hasValue }.map(\.holeNumber)
            }
            // With more than one row the app must not pick for the golfer. The scores sit on the detected
            // rows until they say which is theirs, and the evaluator's roster prompt does the asking.
        } else {
            let index = selectedRemoteIndex(payload: payload, scorecard: result)
            let (merged, changed) = RemoteParseMerger.merge(
                player: payload.players[index],
                into: result,
                confidenceCeiling: ceilings[index]
            )
            result = merged
            updatedHoles = changed
            result = fillMissingSubtotals(in: result, from: payload.players[index], ceiling: ceilings[index])
        }

        // 3. The card's own arithmetic gets the last word.
        var checksumSupport = ParsingConfidenceEvaluator.ChecksumSupport.unavailable
        if let player = result.selectedPlayer {
            let solved = ScoreChecksumSolver().solve(
                holes: result.holes,
                writtenOut: player.writtenOut,
                writtenIn: player.writtenIn,
                writtenTotal: player.writtenTotal,
                holeCount: result.holeCount
            )
            result.holes = solved.holes
            result.checksumSolvedHoles = solved.solvedHoles
            result.warnings.append(contentsOf: solved.warnings)
            checksumSupport = solved.checksumSupport
            if let playerIndex = result.detectedPlayers.firstIndex(where: { $0.id == player.id }) {
                for hole in result.holes where result.detectedPlayers[playerIndex].scores.indices.contains(hole.holeNumber - 1) {
                    result.detectedPlayers[playerIndex].scores[hole.holeNumber - 1] = hole.playerScore
                }
            }
        }

        // 4. Say what happened, then re-score the card from what is now on it.
        //
        // The first pass's own findings are dropped before the evaluator runs again, because they describe
        // a card that no longer exists: "no handwritten score row was recognised" is exactly the warning
        // this pass was run to answer, and leaving it beside eighteen freshly-read scores would be worse
        // than useless. The evaluator re-derives every one of them from the merged card.
        result.warnings.removeAll { ownedWarningKinds.contains($0.kind) }
        result.warnings.append(contentsOf: auditWarnings(audits))

        let assessment = ParsingConfidenceEvaluator().evaluate(
            holes: result.holes,
            holeCount: result.holeCount,
            players: result.detectedPlayers,
            courseConfidence: result.courseConfidence,
            courseResolved: result.candidateCourse != nil,
            checksumSupport: checksumSupport,
            existingWarnings: result.warnings
        )
        result.warnings = assessment.warnings
        result.overallConfidence = assessment.overallConfidence
        result.quality = assessment.quality

        return Outcome(
            scorecard: result,
            updatedHoles: updatedHoles.sorted(),
            adoptedPlayerIDs: adoptedIDs,
            audits: audits
        )
    }

    // MARK: - Row pairing

    /// Pairs a remote row with the local row for the same golfer, by name when both read one.
    ///
    /// Falls back to `nil` rather than to positional order: pairing the wrong two rows would check a row's
    /// sums against another golfer's subtotal, which would report a contradiction that is not there.
    private static func matchingLocalPlayer(
        for player: RemoteScorecardPayload.Player,
        in scorecard: ParsedScorecard
    ) -> DetectedPlayer? {
        if scorecard.detectedPlayers.count == 1 { return scorecard.detectedPlayers.first }
        guard let name = player.name, !name.isEmpty else { return nil }
        let scored = scorecard.detectedPlayers.compactMap { local -> (DetectedPlayer, Double)? in
            guard let localName = local.name, !localName.isEmpty else { return nil }
            return (local, FuzzyText.similarity(name, localName))
        }
        guard let best = scored.max(by: { $0.1 < $1.1 }), best.1 >= 0.7 else { return nil }
        return best.0
    }

    /// Which remote row corresponds to the golfer's selected local row.
    private static func selectedRemoteIndex(payload: RemoteScorecardPayload, scorecard: ParsedScorecard) -> Int {
        guard payload.players.count > 1, let selected = scorecard.selectedPlayer, let name = selected.name, !name.isEmpty else {
            return 0
        }
        let scored = payload.players.enumerated().compactMap { offset, player -> (Int, Double)? in
            guard let remoteName = player.name, !remoteName.isEmpty else { return nil }
            return (offset, FuzzyText.similarity(name, remoteName))
        }
        guard let best = scored.max(by: { $0.1 < $1.1 }), best.1 >= 0.7 else { return 0 }
        return best.0
    }

    /// Adds subtotals the remote read and the local parser missed, so the checksum solver has something to
    /// work with. An existing local reading is never replaced.
    private static func fillMissingSubtotals(
        in scorecard: ParsedScorecard,
        from player: RemoteScorecardPayload.Player,
        ceiling: Double
    ) -> ParsedScorecard {
        var result = scorecard
        guard let selected = result.selectedPlayer,
              let index = result.detectedPlayers.firstIndex(where: { $0.id == selected.id }) else { return result }

        func fill(_ field: inout ParsedField<Int>, with value: Int?) {
            guard !field.hasValue, let value else { return }
            field = ParsedField(value: value, confidence: min(0.85, ceiling), provenance: .multimodalFallback)
        }
        fill(&result.detectedPlayers[index].writtenOut, with: player.writtenOut)
        fill(&result.detectedPlayers[index].writtenIn, with: player.writtenIn)
        fill(&result.detectedPlayers[index].writtenTotal, with: player.writtenTotal)
        return result
    }

    // MARK: - Reporting

    private static func displayName(for player: RemoteScorecardPayload.Player, fallbackIndex: Int) -> String {
        if let name = player.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty { return name }
        return "Player \(fallbackIndex)"
    }

    private static func auditWarnings(_ audits: [RowAudit]) -> [ParseWarning] {
        var warnings: [ParseWarning] = []
        for audit in audits {
            switch audit.verdict {
            case .corroborated(let checks):
                let labels = checks.map(\.label)
                let distinct = Array(Set(labels)).sorted()
                warnings.append(ParseWarning(
                    kind: .remoteParseCorroborated,
                    severity: .info,
                    detail: "\(audit.playerName)'s scores add up to the \(listing(distinct)) written on the card, so the reading checks out."
                ))
            case .contradicted(let failures):
                guard let first = failures.first else { continue }
                warnings.append(ParseWarning(
                    kind: .remoteParseContradicted,
                    severity: .warning,
                    detail: "\(audit.playerName)'s \(first.label) reads as \(first.sum), but the card says \(first.subtotal). Check that row before saving."
                ))
            case .unverifiable(let reason):
                warnings.append(ParseWarning(
                    kind: .remoteParseUnverified,
                    severity: .info,
                    detail: reason == .noSubtotals
                        ? "\(audit.playerName)'s row has no written totals to check it against, so read the scores over before saving."
                        : "\(audit.playerName)'s row is missing some holes, so it could not be checked against the written totals."
                ))
            }
        }
        return warnings
    }

    private static func listing(_ items: [String]) -> String {
        switch items.count {
        case 0: return "totals"
        case 1: return items[0] + " total"
        case 2: return "\(items[0]) and \(items[1]) totals"
        default: return items.dropLast().joined(separator: ", ") + " and " + items[items.count - 1] + " totals"
        }
    }
}
