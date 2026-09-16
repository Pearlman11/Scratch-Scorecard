import Foundation
import SwiftData
import ScorecardKit

/// Saves, loads and deletes rounds, keeping the database and the image files on disk in step.
@MainActor
final class RoundRepository {

    private let context: ModelContext
    private let imageStore: ScorecardImageStore
    private let courseRepository: CourseRepository

    init(context: ModelContext, imageStore: ScorecardImageStore = .shared) {
        self.context = context
        self.imageStore = imageStore
        self.courseRepository = CourseRepository(context: context)
    }

    // MARK: - Saving

    /// Turns a reviewed parse plus its photograph into a saved round.
    ///
    /// Static values are copied onto each `HoleScore` rather than referenced, so the round still renders
    /// correctly years later even if the course's template is corrected or the course record is removed.
    @discardableResult
    func saveRound(
        from scorecard: ParsedScorecard,
        course: Course?,
        processedImage: ProcessedScorecardImage?,
        datePlayed: Date,
        playerName: String?,
        notes: String? = nil
    ) async throws -> Round {
        let round = Round(
            datePlayed: datePlayed,
            course: course,
            layoutName: scorecard.candidateLayoutName ?? course?.layoutName,
            teeName: scorecard.candidateTee,
            holeCount: scorecard.holeCount,
            parserConfidence: scorecard.overallConfidence,
            parserName: scorecard.parserName,
            parserVersion: scorecard.parserVersion,
            appliedTemplateID: scorecard.appliedTemplateID,
            appliedTemplateVersion: scorecard.appliedTemplateVersion,
            playerName: playerName
        )
        round.notes = notes
        context.insert(round)

        for hole in scorecard.holes.sorted(by: { $0.holeNumber < $1.holeNumber }) {
            let holeScore = HoleScore(
                holeNumber: hole.holeNumber,
                strokes: hole.playerScore.value,
                par: hole.par.value,
                handicapIndex: hole.handicapIndex.value,
                yardage: hole.yardage.value,
                scoreProvenance: hole.playerScore.provenance,
                scoreConfidence: hole.playerScore.confidence
            )
            holeScore.round = round
            context.insert(holeScore)
            round.holeScores.append(holeScore)
        }

        // The photograph is written before the round is committed, so a crash can leave an orphaned file
        // (cleaned up later) rather than a round pointing at nothing.
        if let processedImage {
            let stored = try await imageStore.store(processedImage)
            let reference = ScorecardImageRef(
                originalFilename: stored.originalFilename,
                normalizedFilename: stored.normalizedFilename,
                pixelWidth: stored.pixelWidth,
                pixelHeight: stored.pixelHeight
            )
            reference.round = round
            context.insert(reference)
            round.scorecardImage = reference
        }

        round.recalculateTotals()

        // Saving a round at a course marks it played, whether or not the golfer ever scratched it.
        if let course {
            try courseRepository.recordVisitForSavedRound(course)
            if course.holeCount == 0 { course.holeCount = scorecard.holeCount }
        }

        try context.save()
        return round
    }

    // MARK: - Editing

    /// Applies an edited score to a saved round and recomputes its totals.
    func updateScore(_ strokes: Int?, forHole holeNumber: Int, in round: Round) throws {
        guard let holeScore = round.holeScores.first(where: { $0.holeNumber == holeNumber }) else { return }
        holeScore.strokes = strokes
        holeScore.scoreProvenanceRaw = FieldProvenance.userEdited.rawValue
        holeScore.scoreConfidence = 1.0
        round.recalculateTotals()
        try context.save()
    }

    // MARK: - Deleting

    /// Deletes a round and the photograph it owned.
    ///
    /// The file is removed before the record, because the record is the only thing that knows the
    /// filename — dropping it first would leak the image permanently.
    func delete(_ round: Round) async throws {
        let original = round.scorecardImage?.originalFilename
        let normalized = round.scorecardImage?.normalizedFilename
        await imageStore.delete(originalFilename: original, normalizedFilename: normalized)
        context.delete(round)
        try context.save()
    }

    // MARK: - Fetching

    func allRounds() throws -> [Round] {
        try context.fetch(FetchDescriptor<Round>(sortBy: [SortDescriptor(\.datePlayed, order: .reverse)]))
    }

    func rounds(atCourse course: Course) -> [Round] {
        course.roundsNewestFirst
    }

    /// Looks for a round that already covers this card.
    ///
    /// Re-photographing the same scorecard is an easy mistake — the golfer scans it, then scans it again
    /// from Photos to check something. The same course, the same day and the same total is a duplicate
    /// worth flagging, but the golfer decides: two rounds on one day at one course is also perfectly real.
    func findPossibleDuplicate(
        course: Course?,
        datePlayed: Date,
        totalScore: Int?
    ) throws -> Round? {
        guard let course else { return nil }
        let dayStart = Calendar.current.startOfDay(for: datePlayed)
        guard let dayEnd = Calendar.current.date(byAdding: .day, value: 1, to: dayStart) else { return nil }
        let courseID = course.catalogID

        // The date range is narrowed in the query; the course is matched in Swift. Optional chaining
        // through a to-one relationship inside `#Predicate` is not reliably supported, and a predicate
        // that fails to compile down to a query is worse than fetching one day of rounds.
        let descriptor = FetchDescriptor<Round>(predicate: #Predicate { round in
            round.datePlayed >= dayStart && round.datePlayed < dayEnd
        })
        let sameDay = try context.fetch(descriptor).filter { $0.course?.catalogID == courseID }
        guard let totalScore else { return sameDay.first }
        return sameDay.first { $0.totalScore == totalScore } ?? sameDay.first
    }

    // MARK: - Summary

    struct Summary {
        var roundsPlayed: Int
        var coursesPlayed: Int
        var averageScore: Double?
        var bestScore: Int?
        var bestScoreCourseName: String?
    }

    /// Basic history summary. Deliberately shallow — the scan experience is the product, not the stats.
    func summary() throws -> Summary {
        let rounds = try allRounds()
        let completed = rounds.compactMap { round -> (Round, Int)? in
            guard let total = round.totalScore else { return nil }
            return (round, total)
        }
        let courseIDs = Set(rounds.compactMap { $0.course?.catalogID })
        let best = completed.min { $0.1 < $1.1 }

        return Summary(
            roundsPlayed: rounds.count,
            coursesPlayed: courseIDs.count,
            averageScore: completed.isEmpty
                ? nil
                : Double(completed.map { $0.1 }.reduce(0, +)) / Double(completed.count),
            bestScore: best?.1,
            bestScoreCourseName: best?.0.course?.displayName
        )
    }

    // MARK: - Maintenance

    /// Removes image files no live round points at.
    func cleanUpOrphanedImages() async throws {
        let references = try context.fetch(FetchDescriptor<ScorecardImageRef>())
        var referenced = Set<String>()
        for reference in references {
            referenced.insert(reference.originalFilename)
            if let normalized = reference.normalizedFilename { referenced.insert(normalized) }
        }
        await imageStore.deleteOrphans(keeping: referenced)
    }
}
