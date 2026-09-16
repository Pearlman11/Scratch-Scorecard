#if DEBUG
import SwiftUI
import SwiftData
import PhotosUI
import ScorecardKit

/// The parser inspector. Development builds only.
///
/// Exists because improving accuracy on a real card is otherwise guesswork. When a scan of the physical
/// Steel Canyon card comes out wrong, the question is always *which stage* failed — did OCR miss the row,
/// did it cluster into the wrong band, did the column boundaries drift, or did the matcher pick another
/// course? Every stage's output is shown here, over the image, so the answer takes seconds instead of a
/// rebuild with print statements.
///
/// Deliberately kept out of the consumer UI: it is compiled out of release builds entirely.
struct ParserDebugView: View {

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var photoSelection: PhotosPickerItem?
    @State private var scan: ScorecardScanResult?
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var overlay: OverlayMode = .observations
    @State private var showsNormalized = false

    enum OverlayMode: String, CaseIterable, Identifiable {
        case none = "None"
        case observations = "OCR boxes"
        case rows = "Rows"
        case columns = "Columns"
        var id: String { rawValue }
    }

    private let parser = VisionScorecardParser()

    var body: some View {
        NavigationStack {
            Group {
                if let scan, let report = scan.debugReport {
                    inspector(scan: scan, report: report)
                } else {
                    emptyState
                }
            }
            .navigationTitle("Parser Inspector")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .topBarLeading) {
                    PhotosPicker(selection: $photoSelection, matching: .images) {
                        Image(systemName: "photo.badge.plus")
                    }
                }
            }
            .onChange(of: photoSelection) { _, item in
                Task { await load(item) }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 20) {
            ContentUnavailableView {
                Label("No scan loaded", systemImage: "ladybug")
            } description: {
                Text("Import a scorecard photo to inspect every stage of the parse.")
            }

            Button("Run the Steel Canyon fixture") { runSyntheticFixture() }
                .buttonStyle(.bordered)

            if isWorking { ProgressView() }
            if let errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .padding(.horizontal)
            }
        }
    }

    // MARK: - Inspector

    private func inspector(scan: ScorecardScanResult, report: ParserDebugReport) -> some View {
        List {
            Section {
                Picker("Overlay", selection: $overlay) {
                    ForEach(OverlayMode.allCases) { mode in Text(mode.rawValue).tag(mode) }
                }
                .pickerStyle(.segmented)

                Toggle("Show processed image", isOn: $showsNormalized)

                DebugOverlayView(
                    image: showsNormalized ? scan.processedImage.normalized : scan.processedImage.original,
                    report: report,
                    mode: overlay
                )
                .frame(maxWidth: .infinity)
                .frame(height: 260)
            }

            Section("Image") {
                keyValue("Perspective corrected", scan.processedImage.wasPerspectiveCorrected ? "yes" : "no")
                keyValue("Sharpness", String(format: "%.2f", scan.processedImage.sharpness))
                keyValue("Glare", String(format: "%.2f", scan.processedImage.glareFraction))
                keyValue("Estimated skew", String(format: "%.2f°", report.skewDegrees))
                keyValue("Median text height", String(format: "%.4f", report.medianTextHeight))
                keyValue("Observations", "\(report.observations.count)")
                if !scan.holesRecoveredByTargetedPass.isEmpty {
                    keyValue(
                        "Recovered by cell re-read",
                        scan.holesRecoveredByTargetedPass.map(String.init).joined(separator: ", ")
                    )
                }
            }

            Section("Course candidates") {
                ForEach(report.courseCandidates) { candidate in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(candidate.displayName)
                                .font(.subheadline.weight(.medium))
                            Spacer()
                            Text(String(format: "%.3f", candidate.totalScore))
                                .font(.subheadline.monospacedDigit())
                                .foregroundStyle(candidate.templateID == report.appliedTemplateID ? Theme.accent : .secondary)
                        }
                        Text(candidateBreakdown(candidate))
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                        if let fragment = candidate.matchedFragment {
                            Text("matched text: \"\(fragment)\"")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }

            Section("Detected rows") {
                ForEach(report.rows) { row in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text("\(row.index). \(row.role)")
                                .font(.caption.weight(.semibold))
                            Spacer()
                            Text(String(format: "conf %.2f", row.roleConfidence))
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        if !row.labelText.isEmpty {
                            Text("label: \(row.labelText)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Text(row.cellTexts.joined(separator: " | "))
                            .font(.caption2.monospaced())
                            .lineLimit(3)
                        Text(String(format: "ocr %.2f · uniformity %.2f", row.meanOCRConfidence, row.heightUniformity))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                    .listRowBackground(
                        report.playerRowIndices.contains(row.index)
                            ? Theme.accent.opacity(0.12)
                            : Color(.secondarySystemGroupedBackground)
                    )
                }
            }

            Section("Extracted static data") {
                keyValue("Pars", sequenceText(report.extractedPars))
                keyValue("HCP", sequenceText(report.extractedHandicaps))
                ForEach(report.extractedYardageRows.indices, id: \.self) { index in
                    let row = report.extractedYardageRows[index]
                    keyValue(row.teeName ?? "unnamed tee", sequenceText(row.values))
                }
                keyValue("Applied template", report.appliedTemplateID ?? "none")
                keyValue("Applied tee", report.appliedTeeName ?? "none")
                keyValue("Name fragments", report.nameFragments.joined(separator: " / "))
            }

            Section("Final result") {
                keyValue("Course", scan.scorecard.candidateCourse?.displayName ?? "—")
                keyValue("Course confidence", String(format: "%.3f", scan.scorecard.courseConfidence))
                keyValue("Tee", scan.scorecard.candidateTee ?? "—")
                keyValue("Tee confidence", String(format: "%.2f", scan.scorecard.teeConfidence))
                keyValue("Holes", "\(scan.scorecard.holeCount)")
                keyValue("Quality", scan.scorecard.quality.rawValue)
                keyValue("Overall confidence", String(format: "%.3f", scan.scorecard.overallConfidence))
                keyValue("Scores", sequenceText(scan.scorecard.scores))
                keyValue("Needs review", scan.scorecard.holesNeedingReview.map(String.init).joined(separator: ", "))
            }

            Section("Warnings") {
                ForEach(scan.scorecard.warnings) { warning in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(warning.kind.rawValue)
                            .font(.caption.weight(.semibold))
                        Text(warning.detail)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func candidateBreakdown(_ candidate: ParserDebugReport.CourseCandidateSummary) -> String {
        String(
            format: "name %.2f · par %.2f/%d · hcp %.2f/%d · %@ %.2f/%d · evidence %.2f",
            candidate.nameScore,
            candidate.parScore, candidate.parCompared,
            candidate.handicapScore, candidate.handicapCompared,
            candidate.bestTeeName ?? "tee",
            candidate.teeScore, candidate.teeCompared,
            candidate.evidenceWeight
        )
    }

    private func sequenceText(_ values: [Int?]) -> String {
        values.map { $0.map(String.init) ?? "·" }.joined(separator: " ")
    }

    private func keyValue(_ key: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(key)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 130, alignment: .leading)
            Text(value)
                .font(.caption.monospaced())
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }

    // MARK: - Loading

    private func load(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            guard let data = try await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data) else {
                errorMessage = "Could not open that image."
                return
            }
            let templates = (try? CourseRepository(context: modelContext).templatesForMatching())
                ?? GeorgiaCourseCatalog.templates
            scan = try await parser.scan(
                image: image,
                alreadyRectified: false,
                templates: templates,
                collectsDebugReport: true
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Runs the synthetic Steel Canyon card through the engine with no camera involved.
    ///
    /// Confirms the whole pipeline is healthy before a real photo is blamed for a bad parse.
    private func runSyntheticFixture() {
        isWorking = true
        errorMessage = nil
        Task {
            defer { isWorking = false }
            let card = ScorecardFixtureBuilder.steelCanyonCard(
                scores: [5, 4, 3, 4, 3, 6, 3, 4, 3, 4, 5, 3, 3, 4, 5, 4, 3, 4]
            )
            let observations = ScorecardFixtureBuilder.build(card)
            let engine = DefaultScorecardParser()
            do {
                let outcome = try await engine.parse(ScorecardParseRequest(
                    observations: observations,
                    templates: GeorgiaCourseCatalog.templates,
                    collectsDebugReport: true
                ))
                let blank = UIImage(systemName: "doc.text") ?? UIImage()
                scan = ScorecardScanResult(
                    processedImage: ProcessedScorecardImage(
                        original: blank,
                        normalized: blank,
                        wasPerspectiveCorrected: false,
                        sharpness: 1,
                        glareFraction: 0
                    ),
                    scorecard: outcome.scorecard,
                    observations: observations,
                    debugReport: outcome.debugReport,
                    holesRecoveredByTargetedPass: []
                )
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
#endif
