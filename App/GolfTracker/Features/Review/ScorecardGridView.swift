import SwiftUI
import ScorecardKit

/// The digital scorecard: one compact grid, edited like a scorecard rather than a form.
///
/// The interaction model is the point. A golfer correcting two misread cells out of eighteen should touch
/// exactly those two cells, so the grid is laid out the way the paper card is — holes across, Yards / Par /
/// HCP / Score down — with every score cell directly tappable. Marching the golfer through eighteen
/// separate form fields would be slower than re-entering the card by hand, which would make scanning
/// pointless.
struct ScorecardGridView: View {

    @Binding var scorecard: ParsedScorecard
    /// Called after any edit so the parent can persist or recompute.
    var onScoreChanged: (Int, Int?) -> Void = { _, _ in }

    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var focusedHole: Int?

    /// The card split into nines. A nine-hole card is one block labelled OUT; eighteen holes are two.
    private var holeRanges: [(title: String, holes: [Int])] {
        let all = scorecard.holes.map(\.holeNumber).sorted()
        guard scorecard.holeCount > 9 else {
            return [(title: "OUT", holes: all)]
        }
        return [
            (title: "OUT", holes: all.filter { $0 <= 9 }),
            (title: "IN", holes: all.filter { $0 > 9 })
        ]
    }

    var body: some View {
        VStack(spacing: 20) {
            ForEach(holeRanges.indices, id: \.self) { index in
                let range = holeRanges[index]
                nineHoleBlock(title: range.title, holes: range.holes)
            }
            totalsRow
        }
    }

    // MARK: - One nine

    private func nineHoleBlock(title: String, holes: [Int]) -> some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                VStack(spacing: 1) {
                    gridRow(label: "HOLE", holes: holes, isHeader: true) { hole in
                        Text("\(hole)")
                            .font(Theme.columnHeaderFont)
                            .foregroundStyle(.secondary)
                    } aggregate: {
                        Text(title)
                            .font(Theme.columnHeaderFont)
                            .foregroundStyle(.secondary)
                    }

                    gridRow(label: "YDS", holes: holes) { hole in
                        staticCell(field: scorecard.hole(hole)?.yardage)
                    } aggregate: {
                        aggregateCell(sum(of: holes) { scorecard.hole($0)?.yardage.value })
                    }

                    gridRow(label: "PAR", holes: holes) { hole in
                        staticCell(field: scorecard.hole(hole)?.par)
                    } aggregate: {
                        aggregateCell(sum(of: holes) { scorecard.hole($0)?.par.value })
                    }

                    gridRow(label: "HCP", holes: holes) { hole in
                        staticCell(field: scorecard.hole(hole)?.handicapIndex)
                    } aggregate: {
                        Text("—").font(Theme.staticCellFont).foregroundStyle(.tertiary)
                    }

                    gridRow(label: "SCORE", holes: holes, isScoreRow: true) { hole in
                        scoreCell(hole: hole)
                    } aggregate: {
                        aggregateCell(sum(of: holes) { scorecard.hole($0)?.playerScore.value }, emphasised: true)
                    }
                }
                .padding(.horizontal, 2)
            }
        }
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
    }

    @ViewBuilder
    private func gridRow<Cell: View, Aggregate: View>(
        label: String,
        holes: [Int],
        isHeader: Bool = false,
        isScoreRow: Bool = false,
        @ViewBuilder cell: @escaping (Int) -> Cell,
        @ViewBuilder aggregate: @escaping () -> Aggregate
    ) -> some View {
        HStack(spacing: 1) {
            Text(label)
                .font(Theme.columnHeaderFont)
                .foregroundStyle(.secondary)
                .frame(width: 46, height: rowHeight(isScoreRow: isScoreRow), alignment: .leading)
                .padding(.leading, 10)

            ForEach(holes, id: \.self) { hole in
                cell(hole)
                    .frame(width: cellWidth, height: rowHeight(isScoreRow: isScoreRow))
                    .background(cellBackground(isHeader: isHeader, isScoreRow: isScoreRow))
            }

            aggregate()
                .frame(width: cellWidth + 8, height: rowHeight(isScoreRow: isScoreRow))
                .background(
                    isScoreRow
                        ? Theme.accent.opacity(colorScheme == .dark ? 0.28 : 0.12)
                        : Theme.staticRowBackground(colorScheme)
                )
        }
    }

    private var cellWidth: CGFloat { 42 }

    private func rowHeight(isScoreRow: Bool) -> CGFloat {
        isScoreRow ? Theme.minimumTapTarget : 30
    }

    private func cellBackground(isHeader: Bool, isScoreRow: Bool) -> Color {
        if isScoreRow { return Color(.tertiarySystemGroupedBackground) }
        if isHeader { return Color(.secondarySystemGroupedBackground) }
        return Theme.staticRowBackground(colorScheme)
    }

    // MARK: - Cells

    /// A printed course value. Read-only, because it comes from the card or a verified template — but its
    /// confidence is still shown, so a value the parser is unsure about is visible rather than implied.
    @ViewBuilder
    private func staticCell(field: ParsedField<Int>?) -> some View {
        if let field, let value = field.value {
            Text("\(value)")
                .font(Theme.staticCellFont)
                .foregroundStyle(
                    field.provenance == .verifiedCourseTemplate
                        ? Color.primary
                        : Theme.confidenceTint(field.level, scheme: colorScheme)
                )
                .accessibilityLabel(staticAccessibilityLabel(field: field, value: value))
        } else {
            Text("—")
                .font(Theme.staticCellFont)
                .foregroundStyle(.tertiary)
                .accessibilityLabel("not known")
        }
    }

    private func staticAccessibilityLabel(field: ParsedField<Int>, value: Int) -> String {
        switch field.provenance {
        case .verifiedCourseTemplate: return "\(value), from the verified course card"
        case .ocr: return "\(value), read from the photo, \(field.level.accessibilityDescription)"
        default: return "\(value)"
        }
    }

    /// An editable score. The one thing on this screen the golfer changes.
    private func scoreCell(hole: Int) -> some View {
        let field = scorecard.hole(hole)?.playerScore ?? .empty
        let needsReview = field.requiresReview
        // A score the card's own arithmetic supplied rather than OCR reading the cell. Marked distinctly
        // from "needs review": it is reliable, but it was derived, and the golfer should be able to see
        // which numbers came from where without having to ask.
        let wasSolved = field.provenance == .solvedFromSubtotal

        return ZStack {
            if needsReview {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.orange, lineWidth: 1.5)
                    .padding(2)
            } else if wasSolved {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Theme.accent.opacity(0.65), style: StrokeStyle(lineWidth: 1.5, dash: [3, 2]))
                    .padding(2)
            }
            TextField("", text: scoreBinding(hole: hole))
                .focused($focusedHole, equals: hole)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.center)
                .font(Theme.scoreFont)
                .foregroundStyle(scoreTint(field))
                .textFieldStyle(.plain)
        }
        .contentShape(Rectangle())
        .accessibilityElement()
        .accessibilityLabel("Hole \(hole) score")
        .accessibilityValue(accessibilityValue(for: field, wasSolved: wasSolved))
        .accessibilityHint(needsReview ? "This score was hard to read. Double tap to correct it." : "Double tap to edit")
    }

    private func accessibilityValue(for field: ParsedField<Int>, wasSolved: Bool) -> String {
        guard let value = field.value else { return "empty, \(field.level.accessibilityDescription)" }
        return wasSolved ? "\(value), worked out from the total you wrote" : "\(value)"
    }

    private func scoreTint(_ field: ParsedField<Int>) -> Color {
        if field.provenance == .userEdited { return .primary }
        // Arithmetic from the golfer's own subtotal is trustworthy, so it reads as a settled value rather
        // than inheriting the warning tint that its underlying OCR confidence would otherwise imply.
        if field.provenance == .solvedFromSubtotal { return .primary }
        return Theme.confidenceTint(field.level, scheme: colorScheme)
    }

    /// Text binding for one score cell.
    ///
    /// Text rather than a number binding for two reasons: an emptied cell must mean "no score", which a
    /// numeric binding cannot express, and an out-of-range entry is *rejected* rather than clamped —
    /// silently turning a typo into a different number is the same failure the parser refuses to make.
    private func scoreBinding(hole: Int) -> Binding<String> {
        Binding(
            get: { scorecard.hole(hole)?.playerScore.value.map(String.init) ?? "" },
            set: { newText in
                let trimmed = newText.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty {
                    scorecard.setScore(nil, forHole: hole)
                    onScoreChanged(hole, nil)
                    return
                }
                guard let value = Int(trimmed), ScoreMath.plausibleScoreRange.contains(value) else { return }
                scorecard.setScore(value, forHole: hole)
                onScoreChanged(hole, value)
            }
        )
    }

    @ViewBuilder
    private func aggregateCell(_ value: Int?, emphasised: Bool = false) -> some View {
        Text(value.map(String.init) ?? "—")
            .font(emphasised ? Theme.scoreFont : Theme.staticCellFont)
            .foregroundStyle(value == nil ? Color.secondary : .primary)
    }

    /// Sums a nine, returning `nil` if any hole in it is missing.
    ///
    /// A partial sum presented as a nine-hole total would be a quiet lie, and the golfer would have no way
    /// to tell it apart from a real one.
    private func sum(of holes: [Int], value: (Int) -> Int?) -> Int? {
        var total = 0
        for hole in holes {
            guard let holeValue = value(hole) else { return nil }
            total += holeValue
        }
        return total
    }

    // MARK: - Totals

    private var totalsRow: some View {
        let totals = scorecard.totals
        return HStack(spacing: 12) {
            totalTile(title: "OUT", value: totals.front.map(String.init))
            if scorecard.holeCount > 9 {
                totalTile(title: "IN", value: totals.back.map(String.init))
            }
            totalTile(title: "TOTAL", value: totals.total.map(String.init), emphasised: true)
            totalTile(
                title: "+/- PAR",
                value: totals.total == nil
                    ? ScoreMath.formatRelativeToPar(totals.relativeToParForHolesPlayed)
                    : ScoreMath.formatRelativeToPar(totals.relativeToPar),
                emphasised: true,
                caption: totals.total == nil ? "\(totals.holesWithScores) holes" : nil
            )
        }
    }

    private func totalTile(title: String, value: String?, emphasised: Bool = false, caption: String? = nil) -> some View {
        VStack(spacing: 2) {
            Text(title)
                .font(Theme.columnHeaderFont)
                .foregroundStyle(.secondary)
            Text(value ?? "—")
                .font(emphasised ? .title3.monospacedDigit().bold() : .body.monospacedDigit())
            if let caption {
                Text(caption)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}
