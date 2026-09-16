import SwiftUI
import SwiftData
import ScorecardKit

/// Every round saved, newest first, groupable by course or date.
struct RoundsView: View {

    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Round.datePlayed, order: .reverse) private var rounds: [Round]

    @State private var grouping: Grouping = .date
    @State private var selectedCourseID: String?

    enum Grouping: String, CaseIterable, Identifiable {
        case date = "Date"
        case course = "Course"
        var id: String { rawValue }
    }

    private var filteredRounds: [Round] {
        guard let selectedCourseID else { return rounds }
        return rounds.filter { $0.course?.catalogID == selectedCourseID }
    }

    private var coursesWithRounds: [Course] {
        var seen = Set<String>()
        var result: [Course] = []
        for round in rounds {
            guard let course = round.course, seen.insert(course.catalogID).inserted else { continue }
            result.append(course)
        }
        return result.sorted { $0.name < $1.name }
    }

    var body: some View {
        NavigationStack {
            Group {
                if rounds.isEmpty {
                    ContentUnavailableView {
                        Label("No rounds yet", systemImage: "list.clipboard")
                    } description: {
                        Text("Scan a scorecard and your rounds will appear here.")
                    }
                } else {
                    list
                }
            }
            .navigationTitle("Rounds")
            .toolbar {
                if !rounds.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Picker("Group by", selection: $grouping) {
                                ForEach(Grouping.allCases) { option in
                                    Text(option.rawValue).tag(option)
                                }
                            }
                            Divider()
                            Picker("Course", selection: $selectedCourseID) {
                                Text("All courses").tag(String?.none)
                                ForEach(coursesWithRounds) { course in
                                    Text(course.displayName).tag(String?.some(course.catalogID))
                                }
                            }
                        } label: {
                            Image(systemName: "line.3.horizontal.decrease.circle")
                        }
                        .accessibilityLabel("Filter and grouping")
                    }
                }
            }
        }
    }

    private var list: some View {
        List {
            summarySection
            switch grouping {
            case .date:
                ForEach(groupedByMonth, id: \.key) { group in
                    Section(group.key) {
                        ForEach(group.value) { round in
                            roundLink(round)
                        }
                    }
                }
            case .course:
                ForEach(groupedByCourse, id: \.key) { group in
                    Section(group.key) {
                        ForEach(group.value) { round in
                            roundLink(round, showsCourseName: false)
                        }
                    }
                }
            }
        }
    }

    private func roundLink(_ round: Round, showsCourseName: Bool = true) -> some View {
        NavigationLink {
            RoundDetailView(round: round)
        } label: {
            RoundRow(round: round, showsCourseName: showsCourseName)
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                delete(round)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    // MARK: - Summary

    @ViewBuilder
    private var summarySection: some View {
        if let summary = try? RoundRepository(context: modelContext).summary(), summary.roundsPlayed > 0 {
            Section {
                HStack(spacing: 0) {
                    summaryTile("Rounds", "\(summary.roundsPlayed)")
                    Divider()
                    summaryTile("Courses", "\(summary.coursesPlayed)")
                    Divider()
                    summaryTile("Average", summary.averageScore.map { String(format: "%.1f", $0) } ?? "—")
                    Divider()
                    summaryTile("Best", summary.bestScore.map(String.init) ?? "—")
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
            }
        }
    }

    private func summaryTile(_ title: String, _ value: String) -> some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.title3.monospacedDigit().weight(.semibold))
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Grouping

    private var groupedByMonth: [(key: String, value: [Round])] {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM yyyy"
        let grouped = Dictionary(grouping: filteredRounds) { formatter.string(from: $0.datePlayed) }
        // Dictionary order is undefined, so groups are re-ordered by the newest round each contains.
        return grouped
            .map { (key: $0.key, value: $0.value.sorted { $0.datePlayed > $1.datePlayed }) }
            .sorted { ($0.value.first?.datePlayed ?? .distantPast) > ($1.value.first?.datePlayed ?? .distantPast) }
    }

    private var groupedByCourse: [(key: String, value: [Round])] {
        let grouped = Dictionary(grouping: filteredRounds) { $0.course?.displayName ?? "Unknown course" }
        return grouped
            .map { (key: $0.key, value: $0.value.sorted { $0.datePlayed > $1.datePlayed }) }
            .sorted { $0.key < $1.key }
    }

    private func delete(_ round: Round) {
        Task {
            try? await RoundRepository(context: modelContext).delete(round)
        }
    }
}

/// One row in the rounds list.
struct RoundRow: View {
    let round: Round
    var showsCourseName: Bool = true

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                if showsCourseName {
                    Text(round.course?.displayName ?? "Unknown course")
                        .font(.headline)
                        .lineLimit(1)
                }
                HStack(spacing: 6) {
                    Text(round.datePlayed.formatted(date: .abbreviated, time: .omitted))
                    if let tee = round.teeName {
                        Text("· \(tee)")
                    }
                    if !round.isComplete {
                        Text("· incomplete")
                            .foregroundStyle(.orange)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(round.totalScore.map(String.init) ?? "—")
                    .font(.title3.monospacedDigit().weight(.semibold))
                Text(ScoreMath.formatRelativeToPar(round.scoreRelativeToPar))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}
