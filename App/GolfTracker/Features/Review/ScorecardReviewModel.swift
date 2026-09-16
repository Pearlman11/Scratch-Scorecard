import Foundation
import SwiftUI
import SwiftData
import ScorecardKit

/// State and behaviour behind the review screen.
///
/// Holds the parse as mutable state, applies the golfer's course and tee corrections by re-running the
/// parser against the same observations, and commits the result.
@MainActor
@Observable
final class ScorecardReviewModel {

    var scorecard: ParsedScorecard
    var datePlayed: Date
    var shouldSaveLearnedTemplate = false
    var isSaving = false
    var showingDuplicateWarning = false
    var duplicateMessage = ""
    var showingSaveError = false
    var saveErrorMessage = ""

    /// Where the optional AI read of the handwriting has got to.
    var remotePhase: RemotePhase = .idle
    var showingRemoteConsent = false

    let templates: [CourseTemplate]
    private let scan: ScorecardScanResult
    private let remoteSettings: RemoteParserSettings
    private var modelContext: ModelContext?

    init(
        scan: ScorecardScanResult,
        templates: [CourseTemplate],
        remoteSettings: RemoteParserSettings = .shared
    ) {
        self.scan = scan
        self.scorecard = scan.scorecard
        self.templates = templates
        self.remoteSettings = remoteSettings
        // A scorecard is almost always scanned the day it was played, and the golfer can change it.
        self.datePlayed = Date()
    }

    func attach(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    var originalImage: UIImage? { scan.processedImage.original }

    var courseDisplayName: String {
        scorecard.candidateCourse?.displayName ?? "Choose a course"
    }

    var courseConfidenceDescription: String? {
        guard scorecard.candidateCourse != nil else { return "Not recognised — pick from the Georgia list" }
        let percent = Int((scorecard.courseConfidence * 100).rounded())
        if scorecard.courseConfidence >= 0.999 { return "You chose this course" }
        return scorecard.courseConfidence >= 0.72
            ? "Recognised, \(percent)% match"
            : "Low confidence, \(percent)% match — please confirm"
    }

    var teeDetailDescription: String? {
        guard scorecard.candidateTee != nil else { return "Needed to fill in yardages" }
        if scorecard.teeConfidence >= 0.999 { return "You chose these tees" }
        if scorecard.teeConfidence < 0.6 {
            return "The card prints several tees — confirm which you played"
        }
        return nil
    }

    var availableTees: [TeeSetTemplate] {
        guard let id = scorecard.candidateCourse?.id,
              let template = templates.first(where: { $0.id == id }) else { return [] }
        return template.teeSets
    }

    var suggestedCourseIDs: [String] {
        if !scorecard.alternateCourseIDs.isEmpty { return scorecard.alternateCourseIDs }
        return scorecard.candidateCourse.map { [$0.id] } ?? []
    }

    /// Blocking problems first, then warnings, then notes.
    var sortedWarnings: [ParseWarning] {
        scorecard.warnings.sorted { $0.severity > $1.severity }
    }

    /// Whether this scan could teach the app a course whose template is still incomplete.
    var canOfferTemplateLearning: Bool {
        guard let id = scorecard.candidateCourse?.id,
              let template = templates.first(where: { $0.id == id }) else { return false }
        guard !template.mayRestoreStaticData else { return false }
        return LearnedTemplateBuilder.canBuildTemplate(from: scorecard)
    }

    // MARK: - Corrections

    /// Re-parses against the golfer's chosen course.
    ///
    /// Re-running the engine rather than patching the result in place is what keeps the two consistent: the
    /// new course's template has to be applied to every static field, the tee re-resolved against its tee
    /// sets, and the confidence re-evaluated. Patching would leave the old course's yardages in place.
    func selectCourse(_ template: CourseTemplate) async {
        await reparse(forcedTemplateID: template.id, forcedTeeName: nil)
    }

    /// Re-parses with the golfer's chosen tee, refreshing every yardage from the template.
    func selectTee(_ teeName: String) async {
        await reparse(
            forcedTemplateID: scorecard.candidateCourse?.id,
            forcedTeeName: teeName
        )
    }

    private func reparse(forcedTemplateID: String?, forcedTeeName: String?) async {
        guard !scan.observations.isEmpty else {
            // Nothing to re-parse from, so apply what we can directly rather than dropping the correction.
            applyCorrectionWithoutReparsing(templateID: forcedTemplateID, teeName: forcedTeeName)
            return
        }

        // Scores the golfer has already fixed must survive a re-parse.
        let edits = scorecard.holes
            .filter { $0.playerScore.provenance == .userEdited }
            .map { ($0.holeNumber, $0.playerScore.value) }
        let previousSelection = scorecard.selectedPlayerID

        let engine = DefaultScorecardParser(parserName: scorecard.parserName)
        let request = ScorecardParseRequest(
            observations: scan.observations,
            templates: templates,
            forcedTemplateID: forcedTemplateID,
            forcedTeeName: forcedTeeName,
            collectsDebugReport: false
        )
        guard let outcome = try? await engine.parse(request) else {
            applyCorrectionWithoutReparsing(templateID: forcedTemplateID, teeName: forcedTeeName)
            return
        }

        var updated = outcome.scorecard
        if let previousSelection, updated.detectedPlayers.contains(where: { $0.id == previousSelection }) {
            updated.selectPlayer(id: previousSelection)
        } else if let matching = matchPlayer(previousSelection, in: updated) {
            updated.selectPlayer(id: matching)
        }
        for (hole, value) in edits {
            updated.setScore(value, forHole: hole)
        }
        scorecard = updated
    }

    /// Player IDs are regenerated on each parse, so a re-parse re-identifies the golfer's row by position.
    private func matchPlayer(_ previousID: UUID?, in updated: ParsedScorecard) -> UUID? {
        guard let previousID,
              let previousIndex = scorecard.detectedPlayers.firstIndex(where: { $0.id == previousID }),
              updated.detectedPlayers.indices.contains(previousIndex) else { return nil }
        return updated.detectedPlayers[previousIndex].id
    }

    /// Fallback used when the observations are not available: apply the template's static data directly.
    private func applyCorrectionWithoutReparsing(templateID: String?, teeName: String?) {
        guard let templateID, let template = templates.first(where: { $0.id == templateID }) else { return }
        scorecard.candidateCourse = template.identity
        scorecard.candidateLayoutName = template.identity.layoutName
        scorecard.courseConfidence = 1.0
        scorecard.alternateCourseIDs = []
        scorecard.appliedTemplateID = template.id
        scorecard.appliedTemplateVersion = template.templateVersion

        if let teeName {
            scorecard.candidateTee = teeName
            scorecard.teeConfidence = 1.0
        }
        guard template.mayRestoreStaticData else { return }

        let tee = scorecard.candidateTee.flatMap { template.teeSet(named: $0) }
        for index in scorecard.holes.indices {
            let number = scorecard.holes[index].holeNumber
            if let par = template.par(forHole: number), scorecard.holes[index].par.provenance != .userEdited {
                scorecard.holes[index].par = .template(par)
            }
            if let handicap = template.handicapIndex(forHole: number), scorecard.holes[index].handicapIndex.provenance != .userEdited {
                scorecard.holes[index].handicapIndex = .template(handicap)
            }
            if let yards = tee?.yardage(forHole: number), scorecard.holes[index].yardage.provenance != .userEdited {
                scorecard.holes[index].yardage = .template(yards)
            }
        }
    }

    func selectPlayer(_ player: DetectedPlayer) {
        scorecard.selectPlayer(id: player.id)
    }

    // MARK: - AI read of the handwriting

    enum RemotePhase: Equatable {
        case idle
        case running
        case finished(String)
        case failed(String)

        var isRunning: Bool { self == .running }
    }

    /// Whether to offer the AI read at all.
    ///
    /// Offered only when a proxy is configured *and* there is something to gain. On a card the local parser
    /// read cleanly there is nothing for a remote model to add, and sending the photo off the phone for no
    /// benefit is not a neutral act.
    var canOfferRemoteParse: Bool {
        guard remoteSettings.isConfigured else { return false }
        if case .running = remotePhase { return false }
        if case .finished = remotePhase { return false }
        return scorecard.holes.contains { $0.playerScore.requiresReview } || scorecard.detectedPlayers.isEmpty
    }

    /// The case for pressing the button, in the words of what is actually wrong with this parse.
    var remoteParseRationale: String {
        if scorecard.detectedPlayers.isEmpty {
            return "No handwriting was recognised on this card. An AI read can usually pick out the pencil that on-device recognition misses."
        }
        let unread = scorecard.holes.filter { $0.playerScore.requiresReview }.count
        return "\(unread) score\(unread == 1 ? " is" : "s are") missing or unclear. An AI read can have another go at them."
    }

    /// Sends the photo for a second reading, then lets the card's own arithmetic check the answer.
    ///
    /// Consent is asked once, in words, before the first photo ever leaves the phone — `showingRemoteConsent`
    /// drives that sheet. Everything else in this app runs on-device, so this is the one place where the
    /// golfer has to actively decide, and it is not a decision to make on their behalf.
    func runRemoteParse() async {
        guard remoteSettings.hasAcceptedPrivacyNotice else {
            showingRemoteConsent = true
            return
        }
        guard let service = remoteSettings.makeService() else {
            remotePhase = .failed("No AI parser is set up. Add its address in Settings.")
            return
        }
        guard let data = ProxiedScorecardVisionService.imageData(for: scan.processedImage.original) else {
            remotePhase = .failed("This photo could not be prepared for sending.")
            return
        }

        remotePhase = .running
        do {
            let payload = try await service.parseScorecard(
                imageData: data,
                holeCount: max(scorecard.holeCount, 18)
            )
            let outcome = RemoteParseIntegrator.integrate(payload: payload, into: scorecard)
            scorecard = outcome.scorecard
            remotePhase = .finished(Self.summary(for: outcome))
        } catch let error as RemoteScorecardVisionError {
            remotePhase = .failed(error.errorDescription ?? "The AI read did not work.")
        } catch {
            remotePhase = .failed(error.localizedDescription)
        }
    }

    /// Records the golfer's consent and immediately does the thing they consented to.
    func acceptRemoteConsentAndRun() async {
        remoteSettings.hasAcceptedPrivacyNotice = true
        showingRemoteConsent = false
        await runRemoteParse()
    }

    private static func summary(for outcome: RemoteParseIntegrator.Outcome) -> String {
        guard outcome.changedAnything else {
            return "The AI read did not find anything the card was missing."
        }
        var parts: [String] = []
        if !outcome.adoptedPlayerIDs.isEmpty {
            let count = outcome.adoptedPlayerIDs.count
            parts.append("found \(count) score row\(count == 1 ? "" : "s")")
        }
        if !outcome.updatedHoles.isEmpty {
            parts.append("filled \(outcome.updatedHoles.count) score\(outcome.updatedHoles.count == 1 ? "" : "s")")
        }
        let corroborated = outcome.audits.filter { $0.verdict.isCorroborated }.count
        if corroborated > 0 {
            parts.append("\(corroborated == 1 ? "which adds" : "\(corroborated) of which add") up to the totals on the card")
        }
        return "AI read: " + parts.joined(separator: ", ") + "."
    }

    // MARK: - Saving

    /// Commits the round. Returns `true` when the screen should close.
    func save(force: Bool) async -> Bool {
        guard let modelContext else { return false }
        guard let identity = scorecard.candidateCourse else { return false }

        isSaving = true
        defer { isSaving = false }

        let courseRepository = CourseRepository(context: modelContext)
        let roundRepository = RoundRepository(context: modelContext)

        do {
            let course = try courseRepository.course(withCatalogID: identity.id)

            if !force,
               let duplicate = try roundRepository.findPossibleDuplicate(
                   course: course,
                   datePlayed: datePlayed,
                   totalScore: scorecard.totals.total
               ) {
                duplicateMessage = "There is already a round saved at \(identity.displayName) on this date\(duplicate.totalScore.map { " with a total of \($0)" } ?? ""). Save this one as well?"
                showingDuplicateWarning = true
                return false
            }

            try await roundRepository.saveRound(
                from: scorecard,
                course: course,
                processedImage: scan.processedImage,
                datePlayed: datePlayed,
                playerName: scorecard.selectedPlayer?.name
            )

            if shouldSaveLearnedTemplate, canOfferTemplateLearning {
                let existing = templates.first { $0.id == identity.id }
                // A failure to learn the template must not lose the round the golfer just saved.
                if let learned = try? LearnedTemplateBuilder.build(from: scorecard, improving: existing) {
                    try? courseRepository.saveLearnedTemplate(learned)
                }
            }
            return true
        } catch {
            saveErrorMessage = error.localizedDescription
            showingSaveError = true
            return false
        }
    }
}
