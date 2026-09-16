import SwiftUI
import UIKit
import SwiftData
import PhotosUI
import ScorecardKit

/// The main action: photograph a scorecard, or import one to test with.
struct ScanView: View {

    @Environment(\.modelContext) private var modelContext
    @State private var viewModel = ScanViewModel()
    @State private var showingDebugInspector = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    header
                    actionButtons
                    if viewModel.phase.isBusy {
                        progressCard
                    }
                    if case .failed(let message) = viewModel.phase {
                        failureCard(message)
                    }
                    tipsCard
                }
                .padding(Theme.cardPadding)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Scan")
            .toolbar {
                #if DEBUG
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingDebugInspector = true
                    } label: {
                        Image(systemName: "ladybug")
                    }
                    .accessibilityLabel("Parser inspector")
                }
                #endif
            }
            .fullScreenCover(isPresented: $viewModel.showingScanner) {
                DocumentScannerView(
                    onFinish: { images in
                        Task { @MainActor in await viewModel.handleScannedImages(images) }
                    },
                    onCancel: {
                        Task { @MainActor in viewModel.phase = .idle }
                    },
                    onError: { error in
                        Task { @MainActor in viewModel.phase = .failed(error.localizedDescription) }
                    }
                )
                .ignoresSafeArea()
            }
            .navigationDestination(item: Binding(
                get: { viewModel.scanResult.map { ScanRoute(result: $0) } },
                set: { if $0 == nil { viewModel.reset() } }
            )) { route in
                ScorecardReviewView(scan: route.result, templates: viewModel.templates)
            }
            #if DEBUG
            .sheet(isPresented: $showingDebugInspector) {
                ParserDebugView()
            }
            #endif
            .alert("Camera access is off", isPresented: $viewModel.showingCameraDenied) {
                if let url = CapturePermissions.settingsURL {
                    Button("Open Settings") { UIApplication.shared.open(url) }
                }
                Button("Not now", role: .cancel) {}
            } message: {
                Text("Golf Tracker needs the camera to photograph a scorecard. You can still import a photo from your library.")
            }
            .onChange(of: viewModel.photoSelection) { _, newValue in
                Task { await viewModel.handlePickedPhoto(newValue) }
            }
            .task { viewModel.attach(modelContext: modelContext) }
        }
    }

    /// Wrapper so the scan result can drive `navigationDestination(item:)`, which needs Hashable identity.
    ///
    /// The identity is the parse's own id, not a fresh UUID. The binding's getter runs on every body
    /// evaluation, so minting a new id there would change the destination's identity constantly and
    /// bounce the golfer out of the review screen.
    private struct ScanRoute: Hashable, Identifiable {
        let result: ScorecardScanResult
        var id: UUID { result.scorecard.id }

        static func == (lhs: ScanRoute, rhs: ScanRoute) -> Bool { lhs.id == rhs.id }
        func hash(into hasher: inout Hasher) { hasher.combine(id) }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(spacing: 8) {
            Image(systemName: "doc.text.viewfinder")
                .font(.system(size: 52))
                .foregroundStyle(Theme.accent)
            Text("Scan a scorecard")
                .font(.title2.bold())
            Text("Photograph your card and Golf Tracker will build the digital version, filling in par, HCP and yardages for you.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 24)
    }

    private var actionButtons: some View {
        VStack(spacing: 12) {
            Button {
                Task { await viewModel.startCameraScan() }
            } label: {
                Label("Photograph Scorecard", systemImage: "camera.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .frame(height: Theme.minimumTapTarget + 8)
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent)
            .disabled(viewModel.phase.isBusy || !CapturePermissions.isDocumentScannerAvailable)

            PhotosPicker(selection: $viewModel.photoSelection, matching: .images, photoLibrary: .shared()) {
                Label("Import from Photos", systemImage: "photo.on.rectangle")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .frame(height: Theme.minimumTapTarget + 4)
            }
            .buttonStyle(.bordered)
            .disabled(viewModel.phase.isBusy)

            if !CapturePermissions.isDocumentScannerAvailable {
                Text("This device has no document scanner. Import a photo instead.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var progressCard: some View {
        HStack(spacing: 12) {
            ProgressView()
            Text(viewModel.phase.statusText)
                .font(.subheadline)
            Spacer()
        }
        .padding(Theme.cardPadding)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
    }

    private func failureCard(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Couldn't read that card", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.orange)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button("Try again") { viewModel.reset() }
                .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.cardPadding)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
    }

    private var tipsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("For the best read")
                .font(.headline)
            tip("Lay the card flat and fill the frame.")
            tip("Even light beats bright light — avoid glare on glossy cards.")
            tip("Include the hole numbers and the OUT / IN columns.")
            tip("Anything the app can't read clearly is left blank for you to fill in, never guessed.")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.cardPadding)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
    }

    private func tip(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Theme.accent)
                .font(.caption)
                .accessibilityHidden(true)
            Text(text)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}
