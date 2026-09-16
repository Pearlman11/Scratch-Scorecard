import SwiftUI
import SwiftData
import ScorecardKit

/// A saved round: the digital scorecard and the original photograph, side by side.
///
/// Both are the point. The digital card is what the app is for; the photograph is what makes it
/// trustworthy — any figure can be checked against the card the golfer actually wrote on.
struct RoundDetailView: View {

    @Bindable var round: Round

    @Environment(\.modelContext) private var modelContext
    @State private var mode: Mode = .digital
    @State private var originalImage: UIImage?
    @State private var isEditing = false

    enum Mode: String, CaseIterable, Identifiable {
        case digital = "Digital Card"
        case photo = "Original Photo"
        var id: String { rawValue }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                summaryCard

                Picker("View", selection: $mode) {
                    ForEach(Mode.allCases) { option in
                        Text(option.rawValue).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(originalImage == nil && mode == .digital)

                switch mode {
                case .digital:
                    SavedScorecardGrid(round: round, isEditing: isEditing) { hole, strokes in
                        try? RoundRepository(context: modelContext).updateScore(strokes, forHole: hole, in: round)
                    }
                case .photo:
                    photoSection
                }

                provenanceCard
            }
            .padding(Theme.cardPadding)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(round.course?.name ?? "Round")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(isEditing ? "Done" : "Edit Scores") {
                    withAnimation { isEditing.toggle() }
                }
            }
        }
        .task { await loadImage() }
    }

    // MARK: - Sections

    private var summaryCard: some View {
        VStack(spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(round.course?.displayName ?? "Unknown course")
                        .font(.headline)
                    Text(round.datePlayed.formatted(date: .long, time: .omitted))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(round.totalScore.map(String.init) ?? "—")
                        .font(.largeTitle.monospacedDigit().bold())
                    Text(ScoreMath.formatRelativeToPar(round.scoreRelativeToPar))
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            HStack(spacing: 0) {
                statTile("OUT", round.frontNineScore.map(String.init))
                if round.holeCount > 9 {
                    statTile("IN", round.backNineScore.map(String.init))
                }
                statTile("PAR", round.coursePar.map(String.init))
                statTile("TEES", round.teeName ?? "—")
            }
        }
        .padding(Theme.cardPadding)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
    }

    private func statTile(_ title: String, _ value: String?) -> some View {
        VStack(spacing: 3) {
            Text(value ?? "—")
                .font(.body.monospacedDigit().weight(.medium))
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var photoSection: some View {
        if let originalImage {
            Image(uiImage: originalImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
                .accessibilityLabel("Original scorecard photograph")
        } else {
            ContentUnavailableView(
                "No photo attached",
                systemImage: "photo",
                description: Text("This round was saved without a scorecard photograph.")
            )
            .frame(height: 200)
        }
    }

    /// How this round's numbers came to be, in plain language.
    ///
    /// Worth a card of its own: months later, "did I type this or did the app read it?" is a real question,
    /// and the answer is the difference between trusting the number and checking the photo.
    private var provenanceCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("How this card was made")
                .font(.headline)

            provenanceRow(
                "Scores",
                describeScoreProvenance()
            )
            if let templateID = round.appliedTemplateID {
                provenanceRow(
                    "Course data",
                    "Filled from the saved \(round.course?.name ?? templateID) card" +
                        (round.appliedTemplateVersion.map { " (version \($0))" } ?? "")
                )
            } else {
                provenanceRow("Course data", "Read from the photo only")
            }
            provenanceRow(
                "Scan confidence",
                "\(Int((round.parserConfidence * 100).rounded()))% · \(round.parserName) \(round.parserVersion)"
            )
            if let playerName = round.playerName {
                provenanceRow("Player row", playerName)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.cardPadding)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
    }

    private func provenanceRow(_ title: String, _ detail: String) -> some View {
        HStack(alignment: .top) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .leading)
            Text(detail)
                .font(.caption)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private func describeScoreProvenance() -> String {
        let scores = round.holeScoresInOrder.filter { $0.strokes != nil }
        let edited = scores.filter { $0.scoreProvenance == .userEdited }.count
        let read = scores.count - edited
        if scores.isEmpty { return "No scores recorded" }
        if edited == 0 { return "\(read) read from the photo" }
        if read == 0 { return "\(edited) entered by you" }
        return "\(read) read from the photo, \(edited) corrected by you"
    }

    private func loadImage() async {
        guard let filename = round.scorecardImage?.originalFilename else { return }
        originalImage = await ScorecardImageStore.shared.loadImage(named: filename)
    }
}

/// The saved round's grid. Read-only until the golfer taps Edit Scores.
///
/// Mirrors the review screen's layout so a round looks the same the day it is saved and a year later.
private struct SavedScorecardGrid: View {
    let round: Round
    let isEditing: Bool
    let onScoreChanged: (Int, Int?) -> Void

    @Environment(\.colorScheme) private var colorScheme

    private var nines: [(title: String, holes: [HoleScore])] {
        let ordered = round.holeScoresInOrder
        guard round.holeCount > 9 else { return [("OUT", ordered)] }
        return [
            ("OUT", ordered.filter { $0.holeNumber <= 9 }),
            ("IN", ordered.filter { $0.holeNumber > 9 })
        ]
    }

    var body: some View {
        VStack(spacing: 14) {
            ForEach(nines.indices, id: \.self) { nineIndex in
                let nine = nines[nineIndex]
                ScrollView(.horizontal, showsIndicators: false) {
                    VStack(spacing: 1) {
                        staticRow(
                            label: "HOLE",
                            nine: nine,
                            values: nine.holes.map { "\($0.holeNumber)" },
                            aggregate: nine.title,
                            isHeader: true
                        )
                        staticRow(
                            label: "YDS",
                            nine: nine,
                            values: nine.holes.map { text($0.yardage) },
                            aggregate: text(sum(nine.holes) { $0.yardage })
                        )
                        staticRow(
                            label: "PAR",
                            nine: nine,
                            values: nine.holes.map { text($0.par) },
                            aggregate: text(sum(nine.holes) { $0.par })
                        )
                        staticRow(
                            label: "HCP",
                            nine: nine,
                            values: nine.holes.map { text($0.handicapIndex) },
                            aggregate: "—"
                        )
                        scoreRow(nine: nine)
                    }
                    .padding(.horizontal, 2)
                }
            }
        }
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
    }

    /// A read-only row of printed course data.
    private func staticRow(
        label: String,
        nine: (title: String, holes: [HoleScore]),
        values: [String],
        aggregate: String,
        isHeader: Bool = false
    ) -> some View {
        HStack(spacing: 1) {
            rowLabel(label, height: 28)
            ForEach(nine.holes.indices, id: \.self) { index in
                let value = values.indices.contains(index) ? values[index] : "—"
                Text(value)
                    .font(isHeader ? Theme.columnHeaderFont : Theme.staticCellFont)
                    .foregroundStyle(value == "—" ? Color.secondary : (isHeader ? Color.secondary : Color.primary))
                    .frame(width: 42, height: 28)
                    .background(Theme.staticRowBackground(colorScheme))
                    .accessibilityLabel("\(label) hole \(nine.holes[index].holeNumber)")
                    .accessibilityValue(value)
            }
            Text(aggregate)
                .font(isHeader ? Theme.columnHeaderFont : Theme.staticCellFont)
                .foregroundStyle(.secondary)
                .frame(width: 50, height: 28)
                .background(Theme.staticRowBackground(colorScheme))
        }
    }

    private func scoreRow(nine: (title: String, holes: [HoleScore])) -> some View {
        HStack(spacing: 1) {
            rowLabel("SCORE", height: Theme.minimumTapTarget)
            ForEach(nine.holes, id: \.holeNumber) { holeScore in
                scoreCell(holeScore)
                    .frame(width: 42, height: Theme.minimumTapTarget)
                    .background(Color(.tertiarySystemGroupedBackground))
            }
            Text(text(sum(nine.holes) { $0.strokes }))
                .font(Theme.scoreFont)
                .frame(width: 50, height: Theme.minimumTapTarget)
                .background(Theme.accent.opacity(colorScheme == .dark ? 0.28 : 0.12))
        }
    }

    private func rowLabel(_ label: String, height: CGFloat) -> some View {
        Text(label)
            .font(Theme.columnHeaderFont)
            .foregroundStyle(.secondary)
            .frame(width: 46, height: height, alignment: .leading)
            .padding(.leading, 10)
    }

    @ViewBuilder
    private func scoreCell(_ holeScore: HoleScore) -> some View {
        if isEditing {
            TextField("", text: Binding(
                get: { holeScore.strokes.map(String.init) ?? "" },
                set: { newText in
                    let trimmed = newText.trimmingCharacters(in: .whitespaces)
                    if trimmed.isEmpty {
                        onScoreChanged(holeScore.holeNumber, nil)
                        return
                    }
                    // Out-of-range entries are rejected rather than clamped, matching the review screen.
                    guard let value = Int(trimmed), ScoreMath.plausibleScoreRange.contains(value) else { return }
                    onScoreChanged(holeScore.holeNumber, value)
                }
            ))
            .keyboardType(.numberPad)
            .multilineTextAlignment(.center)
            .font(Theme.scoreFont)
            .textFieldStyle(.plain)
            .accessibilityLabel("Hole \(holeScore.holeNumber) score")
        } else {
            Text(text(holeScore.strokes))
                .font(Theme.scoreFont)
                .foregroundStyle(holeScore.strokes == nil ? Color.secondary : .primary)
                .accessibilityLabel("Hole \(holeScore.holeNumber)")
                .accessibilityValue(holeScore.strokes.map { "\($0) strokes" } ?? "no score")
        }
    }

    private func text(_ value: Int?) -> String {
        value.map(String.init) ?? "—"
    }

    /// Sums a nine, returning `nil` if any hole in it is missing — a partial sum shown as a nine-hole
    /// total would be indistinguishable from a real one.
    private func sum(_ holes: [HoleScore], value: (HoleScore) -> Int?) -> Int? {
        var total = 0
        for hole in holes {
            guard let holeValue = value(hole) else { return nil }
            total += holeValue
        }
        return total
    }
}
