import SwiftUI
import SwiftData
import ScorecardKit

/// The screen the golfer lands on after a scan: correct what is wrong, confirm, save.
///
/// Organised around the one question that matters — *what should I look at?* Warnings and low-confidence
/// scores come first, the grid is immediately editable, and the original photograph is one tap away so a
/// questionable cell can be checked against the card without leaving the screen.
struct ScorecardReviewView: View {

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var viewModel: ScorecardReviewModel
    @State private var showingPhoto = false
    @State private var showingCoursePicker = false
    @State private var showingTeePicker = false
    @State private var showingPlayerPicker = false

    init(scan: ScorecardScanResult, templates: [CourseTemplate]) {
        _viewModel = State(initialValue: ScorecardReviewModel(scan: scan, templates: templates))
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                identityCard
                if !viewModel.scorecard.warnings.isEmpty {
                    warningsCard
                }
                if viewModel.scorecard.detectedPlayers.count > 1 {
                    playerPickerCard
                }
                ScorecardGridView(scorecard: $viewModel.scorecard)
                photoCard
                saveSection
            }
            .padding(Theme.cardPadding)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Review Scorecard")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Discard", role: .destructive) { dismiss() }
            }
        }
        .sheet(isPresented: $showingPhoto) {
            OriginalPhotoView(image: viewModel.originalImage, title: viewModel.courseDisplayName)
        }
        .sheet(isPresented: $showingCoursePicker) {
            CoursePickerView(
                templates: viewModel.templates,
                suggestedIDs: viewModel.suggestedCourseIDs,
                selectedID: viewModel.scorecard.candidateCourse?.id
            ) { template in
                Task { await viewModel.selectCourse(template) }
            }
        }
        .sheet(isPresented: $showingTeePicker) {
            TeePickerView(
                tees: viewModel.availableTees,
                selected: viewModel.scorecard.candidateTee
            ) { teeName in
                Task { await viewModel.selectTee(teeName) }
            }
        }
        .confirmationDialog("Which row is yours?", isPresented: $showingPlayerPicker, titleVisibility: .visible) {
            ForEach(viewModel.scorecard.detectedPlayers) { player in
                Button(playerButtonTitle(player)) { viewModel.selectPlayer(player) }
            }
        }
        .alert("Possible duplicate", isPresented: $viewModel.showingDuplicateWarning) {
            Button("Save anyway") { Task { await save(force: true) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(viewModel.duplicateMessage)
        }
        .alert("Couldn't save", isPresented: $viewModel.showingSaveError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(viewModel.saveErrorMessage)
        }
        .task {
            viewModel.attach(modelContext: modelContext)
            if viewModel.scorecard.detectedPlayers.count > 1 && viewModel.scorecard.selectedPlayer == nil {
                showingPlayerPicker = true
            }
        }
    }

    // MARK: - Identity

    private var identityCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                showingCoursePicker = true
            } label: {
                editableRow(
                    title: "Course",
                    value: viewModel.courseDisplayName,
                    detail: viewModel.courseConfidenceDescription,
                    needsAttention: viewModel.scorecard.candidateCourse == nil || viewModel.scorecard.courseConfidence < 0.72
                )
            }
            .buttonStyle(.plain)

            Divider()

            Button {
                showingTeePicker = true
            } label: {
                editableRow(
                    title: "Tees",
                    value: viewModel.scorecard.candidateTee ?? "Choose",
                    detail: viewModel.teeDetailDescription,
                    needsAttention: viewModel.scorecard.teeNeedsConfirmation
                )
            }
            .buttonStyle(.plain)
            .disabled(viewModel.availableTees.isEmpty)

            Divider()

            DatePicker("Date played", selection: $viewModel.datePlayed, displayedComponents: .date)
                .font(.subheadline)
        }
        .padding(Theme.cardPadding)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
    }

    private func editableRow(title: String, value: String, detail: String?, needsAttention: Bool) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.headline)
                    .foregroundStyle(.primary)
                if let detail {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(needsAttention ? .orange : .secondary)
                }
            }
            Spacer()
            if needsAttention {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
            }
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
        .frame(minHeight: Theme.minimumTapTarget)
    }

    // MARK: - Warnings

    private var warningsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(viewModel.sortedWarnings) { warning in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: warning.severity.symbolName)
                        .foregroundStyle(warning.severity.tint)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(warning.detail)
                            .font(.footnote)
                            .foregroundStyle(.primary)
                        if !warning.holeNumbers.isEmpty {
                            Text("Holes \(warning.holeNumbers.map(String.init).joined(separator: ", "))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .padding(Theme.cardPadding)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
    }

    // MARK: - Players

    private var playerPickerCard: some View {
        Button {
            showingPlayerPicker = true
        } label: {
            editableRow(
                title: "Your scores",
                value: viewModel.scorecard.selectedPlayer?.displayName ?? "Choose which row is yours",
                detail: "\(viewModel.scorecard.detectedPlayers.count) golfers were found on this card",
                needsAttention: viewModel.scorecard.selectedPlayer == nil
            )
        }
        .buttonStyle(.plain)
        .padding(Theme.cardPadding)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
    }

    private func playerButtonTitle(_ player: DetectedPlayer) -> String {
        let scored = player.holesWithScores
        let total = player.scoreValues.compactMap { $0 }.reduce(0, +)
        return "\(player.displayName) — \(scored) holes, \(total) strokes"
    }

    // MARK: - Photo

    private var photoCard: some View {
        Button {
            showingPhoto = true
        } label: {
            HStack(spacing: 12) {
                if let image = viewModel.originalImage {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 72, height: 54)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Original photo")
                        .font(.headline)
                    Text("Tap to compare against the card")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(Theme.cardPadding)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
    }

    // MARK: - Save

    private var saveSection: some View {
        VStack(spacing: 10) {
            if !viewModel.scorecard.holesNeedingReview.isEmpty {
                Text("\(viewModel.scorecard.holesNeedingReview.count) score\(viewModel.scorecard.holesNeedingReview.count == 1 ? "" : "s") still need checking — you can save anyway.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Button {
                Task { await save(force: false) }
            } label: {
                Text(viewModel.isSaving ? "Saving…" : "Save Round")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .frame(height: Theme.minimumTapTarget + 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent)
            .disabled(viewModel.isSaving || viewModel.scorecard.candidateCourse == nil)

            if viewModel.scorecard.candidateCourse == nil {
                Text("Choose a course before saving.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if viewModel.canOfferTemplateLearning {
                Toggle(isOn: $viewModel.shouldSaveLearnedTemplate) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Remember this course's card")
                            .font(.subheadline)
                        Text("Saves the printed par, HCP and yardages so the next scan here is more accurate.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 4)
            }
        }
    }

    private func save(force: Bool) async {
        if await viewModel.save(force: force) {
            dismiss()
        }
    }
}
