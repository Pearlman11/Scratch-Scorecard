import Foundation
import SwiftUI
import SwiftData
import PhotosUI
import ScorecardKit

/// Drives the Scan tab: capture, parse, and hand off to review.
@MainActor
@Observable
final class ScanViewModel {

    enum Phase: Equatable {
        case idle
        case preparing
        case recognizing
        case matching
        case failed(String)

        var isBusy: Bool {
            switch self {
            case .preparing, .recognizing, .matching: return true
            case .idle, .failed: return false
            }
        }

        var statusText: String {
            switch self {
            case .idle: return ""
            case .preparing: return "Cleaning up the photo…"
            case .recognizing: return "Reading the scorecard…"
            case .matching: return "Matching the course…"
            case .failed(let message): return message
            }
        }
    }

    var phase: Phase = .idle
    var scanResult: ScorecardScanResult?
    var showingScanner = false
    var showingCameraDenied = false
    var photoSelection: PhotosPickerItem?

    private let parser = VisionScorecardParser()
    private var modelContext: ModelContext?

    func attach(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    var templates: [CourseTemplate] {
        guard let modelContext else { return GeorgiaCourseCatalog.templates }
        return (try? CourseRepository(context: modelContext).templatesForMatching()) ?? GeorgiaCourseCatalog.templates
    }

    // MARK: - Capture

    func startCameraScan() async {
        switch CapturePermissions.cameraStatus() {
        case .authorized:
            showingScanner = true
        case .notDetermined:
            if await CapturePermissions.requestCameraAccess() {
                showingScanner = true
            } else {
                showingCameraDenied = true
            }
        case .denied, .restricted:
            showingCameraDenied = true
        }
    }

    func handleScannedImages(_ images: [UIImage]) async {
        guard let first = images.first else {
            phase = .idle
            return
        }
        // The document camera has already found the card's edges and flattened it.
        await parse(image: first, alreadyRectified: true)
    }

    func handlePickedPhoto(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        phase = .preparing
        do {
            guard let data = try await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data) else {
                phase = .failed("That photo could not be opened.")
                return
            }
            // An imported photo has not been rectified, so the processor runs its own edge detection.
            await parse(image: image, alreadyRectified: false)
        } catch {
            phase = .failed(error.localizedDescription)
        }
        photoSelection = nil
    }

    // MARK: - Parsing

    private func parse(image: UIImage, alreadyRectified: Bool) async {
        phase = .preparing
        let availableTemplates = templates
        do {
            phase = .recognizing
            let result = try await parser.scan(
                image: image,
                alreadyRectified: alreadyRectified,
                templates: availableTemplates,
                // The review screen re-parses when the golfer corrects the course, and the debug inspector
                // needs the same data, so the report is always collected. It is cheap next to recognition.
                collectsDebugReport: true
            )
            phase = .matching
            scanResult = result
            phase = .idle
        } catch let error as ScorecardParsingError {
            phase = .failed(error.errorDescription ?? "The scorecard could not be read.")
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func reset() {
        scanResult = nil
        phase = .idle
    }
}
