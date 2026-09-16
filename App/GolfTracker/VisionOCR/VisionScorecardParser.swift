import Foundation
import UIKit
import ScorecardKit

/// Everything one scan produces.
struct ScorecardScanResult {
    let processedImage: ProcessedScorecardImage
    let scorecard: ParsedScorecard
    /// Every observation the parse was built from.
    ///
    /// Retained on every scan, not just debug ones: when the golfer corrects the course or the tee, the
    /// right response is to re-run the engine against the same recognition rather than to patch the result,
    /// and that needs the observations. Re-running Vision instead would be slow and could return something
    /// different, which would make a correction feel like a second, worse scan.
    let observations: [TextObservation]
    let debugReport: ParserDebugReport?
    /// Hole numbers that a targeted second look managed to recover.
    let holesRecoveredByTargetedPass: [Int]
}

/// The app's end-to-end scanning path: photograph in, reviewed scorecard out.
///
/// Composes the image processor, the Vision recognizer and `ScorecardKit`'s engine. It owns one piece of
/// logic of its own — the targeted re-read — because that step needs the image and the reconstructed grid
/// at the same time, and `ScorecardKit` deliberately never sees an image.
actor VisionScorecardParser {

    private let processor: ScorecardImageProcessor
    private let recognizer: ScorecardTextRecognizing
    private let engine: DefaultScorecardParser

    init(
        processor: ScorecardImageProcessor = ScorecardImageProcessor(),
        recognizer: ScorecardTextRecognizing = VisionTextRecognizer(),
        engine: DefaultScorecardParser = DefaultScorecardParser(parserName: "VisionScorecardParser")
    ) {
        self.processor = processor
        self.recognizer = recognizer
        self.engine = engine
    }

    func scan(
        image: UIImage,
        alreadyRectified: Bool,
        templates: [CourseTemplate],
        forcedTemplateID: String? = nil,
        forcedTeeName: String? = nil,
        collectsDebugReport: Bool = false
    ) async throws -> ScorecardScanResult {
        let processed = try await processor.process(image, alreadyRectified: alreadyRectified)

        var observations = try await recognizer.recognizeText(in: processed.normalized)
        let qualityWarnings = imageQualityWarnings(for: processed)

        // First parse, purely from the full-card passes.
        var outcome = try await engine.parse(ScorecardParseRequest(
            observations: observations,
            templates: templates,
            forcedTemplateID: forcedTemplateID,
            forcedTeeName: forcedTeeName,
            collectsDebugReport: collectsDebugReport
        ))

        // Second look at the cells that matter and came back unclear.
        let recovered = try await targetedRecoveryObservations(
            for: outcome.scorecard,
            observations: observations,
            normalizedImage: processed.normalized
        )

        var recoveredHoles: [Int] = []
        if !recovered.isEmpty {
            observations.append(contentsOf: recovered.map(\.observation))
            let reparsed = try await engine.parse(ScorecardParseRequest(
                observations: observations,
                templates: templates,
                forcedTemplateID: forcedTemplateID,
                forcedTeeName: forcedTeeName,
                collectsDebugReport: collectsDebugReport
            ))
            // Only accept the re-parse if it actually recovered scores and broke nothing else.
            let before = outcome.scorecard.holes.filter { $0.playerScore.hasValue }.count
            let after = reparsed.scorecard.holes.filter { $0.playerScore.hasValue }.count
            if after > before && reparsed.scorecard.holeCount == outcome.scorecard.holeCount {
                recoveredHoles = recovered.map(\.holeNumber)
                outcome = reparsed
            }
        }

        var scorecard = outcome.scorecard
        scorecard.warnings.append(contentsOf: qualityWarnings)

        return ScorecardScanResult(
            processedImage: processed,
            scorecard: scorecard,
            observations: observations,
            debugReport: outcome.debugReport,
            holesRecoveredByTargetedPass: recoveredHoles
        )
    }

    // MARK: - Targeted re-read

    private struct RecoveredCell {
        let holeNumber: Int
        let observation: TextObservation
    }

    /// Re-reads the score cells the first pass could not.
    ///
    /// Vision recognizes at a fixed internal resolution, so a handwritten digit occupying a few dozen
    /// pixels of a full-card photograph is below what it can resolve at all. Cropping to that one cell and
    /// upscaling gives the same digit hundreds of pixels — which is the difference between "unreadable" and
    /// a reading, and it is why this is worth a second pass rather than better tuning of the first.
    ///
    /// Only *score* cells are re-read. A static value that came out unclear is already handled better by
    /// the course template, and re-reading it would risk replacing a correct template value with a guess.
    private func targetedRecoveryObservations(
        for scorecard: ParsedScorecard,
        observations: [TextObservation],
        normalizedImage: UIImage
    ) async throws -> [RecoveredCell] {
        // Nothing to recover, or nothing to anchor a crop to.
        let unresolved = scorecard.holes.filter { !$0.playerScore.hasValue }
        guard !unresolved.isEmpty, scorecard.holeCount > 0 else { return [] }
        // A card where nothing at all was read is a bad photo, not a set of hard cells; re-reading every
        // cell would be slow and would not help.
        guard scorecard.holes.contains(where: { $0.playerScore.hasValue }) else { return [] }

        let table = ScorecardLayoutDetector().detectTable(from: observations)
        guard !table.sections.isEmpty else { return [] }

        // The row to re-read is the one the golfer's scores came from.
        let playerRowIndices: Set<Int>
        if let selected = scorecard.selectedPlayer, let rowIndex = selected.sourceRowIndex {
            playerRowIndices = [rowIndex]
        } else {
            playerRowIndices = Set(table.playerRows.map(\.index))
        }
        guard !playerRowIndices.isEmpty else { return [] }

        var recovered: [RecoveredCell] = []
        for section in table.sections {
            for rowIndex in section.rowIndices where playerRowIndices.contains(rowIndex) {
                guard table.rows.indices.contains(rowIndex) else { continue }
                let row = table.rows[rowIndex]

                for hole in unresolved {
                    guard let column = section.column(forHole: hole.holeNumber) else { continue }
                    let cellRect = CardRect(
                        x: column.minX,
                        y: row.rect.minY,
                        width: column.maxX - column.minX,
                        height: row.rect.height
                    )
                    // Back into the photograph's own coordinates before cropping.
                    let imageRect = table.rectInOriginalImageSpace(cellRect)
                    guard let crop = await processor.upscaledCrop(of: normalizedImage, rect: imageRect) else { continue }

                    let cellObservations = try await recognizer.recognizeCell(in: crop)
                    guard let best = cellObservations
                        .filter({ NumericOCR.bestInteger(from: $0.trimmed, plausibleRange: ScoreMath.plausibleScoreRange) != nil })
                        .max(by: { $0.confidence < $1.confidence }) else { continue }

                    // The crop's own coordinates are meaningless to the parser; the observation is placed
                    // back at the cell it came from so it lands in the right column and row.
                    recovered.append(RecoveredCell(
                        holeNumber: hole.holeNumber,
                        observation: TextObservation(
                            text: best.trimmed,
                            rect: CardRect(
                                x: imageRect.midX - imageRect.width * 0.2,
                                y: imageRect.midY - imageRect.height * 0.3,
                                width: imageRect.width * 0.4,
                                height: imageRect.height * 0.6
                            ),
                            // A targeted read is a second opinion on text the full-card pass could not
                            // resolve, so it is capped below a clean first-pass read and still reviewed.
                            confidence: min(best.confidence, 0.78),
                            pass: .targetedCell,
                            alternativeTexts: best.alternativeTexts
                        )
                    ))
                }
            }
        }
        return recovered
    }

    // MARK: - Image quality

    /// Turns the processor's focus and glare estimates into warnings the review screen can act on.
    private func imageQualityWarnings(for processed: ProcessedScorecardImage) -> [ParseWarning] {
        var warnings: [ParseWarning] = []
        if processed.sharpness < 0.45 {
            warnings.append(ParseWarning(
                kind: .imageLikelyBlurry,
                severity: .warning,
                detail: "This photo looks soft. If scores are missing, re-shoot it holding the phone steady."
            ))
        }
        if processed.glareFraction > 0.35 {
            warnings.append(ParseWarning(
                kind: .imageLikelyGlared,
                severity: .warning,
                detail: "There is glare across part of the card. Tilting it away from the light usually fixes it."
            ))
        }
        return warnings
    }
}
