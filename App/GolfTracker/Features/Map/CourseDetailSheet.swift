import SwiftUI
import SwiftData
import ScorecardKit

/// What a course looks like when you tap its pin.
///
/// Unplayed, it offers the scratch panel. Played, it shows every round saved there, newest first. The two
/// states are one sheet rather than two screens because the transition between them is the whole point of
/// the feature.
struct CourseDetailSheet: View {

    @Bindable var course: Course

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var showingScratchConfirmation = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                if course.isPlayed {
                    playedContent
                } else {
                    unplayedContent
                }
            }
            .navigationTitle(course.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
                if course.manuallyMarkedPlayedAt != nil && course.rounds.isEmpty {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Undo") { clearManualMark() }
                    }
                }
            }
            .alert("Mark as played?", isPresented: $showingScratchConfirmation) {
                Button("Mark as played") { markPlayed() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This scratches \(course.displayName) off your Georgia map. You can still scan a scorecard for it later.")
            }
            .alert(
                "Something went wrong",
                isPresented: Binding(
                    get: { errorMessage != nil },
                    set: { if !$0 { errorMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
        .presentationDetents(course.isPlayed ? [.medium, .large] : [.medium])
        .presentationDragIndicator(.visible)
    }

    // MARK: - Unplayed

    private var unplayedContent: some View {
        VStack(spacing: 20) {
            VStack(spacing: 4) {
                Text(course.layoutName ?? " ")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(course.city + ", GA")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            ScratchRevealView {
                // Underneath the foil: what the golfer is revealing.
                ZStack {
                    RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                        .fill(Theme.accent.gradient)
                    VStack(spacing: 6) {
                        Image(systemName: "flag.fill")
                            .font(.system(size: 34))
                        Text("Played")
                            .font(.title3.bold())
                    }
                    .foregroundStyle(.white)
                }
            } cover: {
                ZStack {
                    RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                        .fill(Color(.systemGray3).gradient)
                    VStack(spacing: 6) {
                        Image(systemName: "hand.draw")
                            .font(.system(size: 26))
                        Text("Scratch to mark as played")
                            .font(.footnote.weight(.medium))
                    }
                    .foregroundStyle(.secondary)
                }
            } onComplete: {
                showingScratchConfirmation = true
            }
            .frame(height: 150)
            .padding(.horizontal, Theme.cardPadding)

            Text("Or scan a scorecard from this course — saving a round marks it played automatically.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Theme.cardPadding)

            Spacer(minLength: 0)
        }
        .padding(.top, 16)
    }

    // MARK: - Played

    private var playedContent: some View {
        List {
            Section {
                HStack(spacing: 14) {
                    ZStack {
                        Circle().fill(Theme.accent).frame(width: 44, height: 44)
                        Image(systemName: "flag.fill").foregroundStyle(.white)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Played")
                            .font(.headline)
                        Text(playedSummary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
            }

            if course.rounds.isEmpty {
                Section {
                    Text("Scratched off the map, but no scorecard saved here yet.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else {
                Section("Rounds here") {
                    ForEach(course.roundsNewestFirst) { round in
                        NavigationLink {
                            RoundDetailView(round: round)
                        } label: {
                            RoundRow(round: round, showsCourseName: false)
                        }
                    }
                }
            }
        }
    }

    private var playedSummary: String {
        if course.rounds.isEmpty {
            guard let date = course.manuallyMarkedPlayedAt else { return "Marked by hand" }
            return "Marked by hand on \(date.formatted(date: .abbreviated, time: .omitted))"
        }
        let count = course.rounds.count
        var summary = "\(count) round\(count == 1 ? "" : "s") saved"
        if let best = course.bestRound?.totalScore {
            summary += " · best \(best)"
        }
        return summary
    }

    // MARK: - Actions

    private func markPlayed() {
        do {
            try CourseRepository(context: modelContext).markPlayedManually(course)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func clearManualMark() {
        do {
            try CourseRepository(context: modelContext).clearManualPlayedMark(course)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
