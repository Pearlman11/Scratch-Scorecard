import Foundation
import UIKit
import Vision
import ScorecardKit

// NOTE: every `TextObservation` below is written as `ScorecardKit.TextObservation`.
//
// iOS 18 gave Vision its own Swift-native `Vision.TextObservation`, and this is the only file that imports
// both frameworks, so the bare name is ambiguous here. Qualifying is also honest: Vision's type is a
// recognizer result, ours is the spatially-anchored token the parser reasons over, and this file is
// precisely where one becomes the other.

/// Reads text off a prepared scorecard image using Apple's Vision recognizer.
///
/// ## Why more than one pass
///
/// The two kinds of text on a scorecard want opposite settings. Language correction turns `Steel Canyan`
/// into `Steel Canyon` — and turns the yardage `171` into whatever word it most resembles. Running both
/// configurations and keeping the better observation per region is cheaper than being wrong either way,
/// and the cost is a second pass over an image the user is already waiting on for under a second.
///
/// Bounding boxes are preserved throughout. A scorecard is a table, and a recognizer's output reduced to a
/// list of strings has thrown away the only thing that distinguishes par from a golfer's score.
protocol ScorecardTextRecognizing: Sendable {
    func recognizeText(in image: UIImage) async throws -> [ScorecardKit.TextObservation]
    /// Re-reads a single cell from a cropped, upscaled image. Coordinates in the returned observations are
    /// relative to the crop, not the card.
    func recognizeCell(in croppedImage: UIImage) async throws -> [ScorecardKit.TextObservation]
}

struct VisionTextRecognizer: ScorecardTextRecognizing {

    /// Words a scorecard prints that a general language model would otherwise correct away.
    private static let scorecardVocabulary = [
        "HOLE", "PAR", "HCP", "HDCP", "HANDICAP", "OUT", "IN", "TOT", "TOTAL",
        "YARDS", "YDS", "TEE", "TEES", "BLACK", "BLUE", "WHITE", "RED", "GOLD",
        "SILVER", "GREEN", "CHAMPIONSHIP", "SENIOR", "LADIES", "FORWARD",
        "SLOPE", "RATING", "STROKE", "INDEX", "GROSS", "NET"
    ]

    func recognizeText(in image: UIImage) async throws -> [ScorecardKit.TextObservation] {
        guard let cgImage = image.cgImage else { throw ScorecardParsingError.imageUnreadable("no bitmap") }

        // Both passes run against the same bitmap, so their boxes are directly comparable.
        async let corrected = performRecognition(
            on: cgImage,
            pass: .languageCorrected,
            usesLanguageCorrection: true,
            minimumTextHeight: 0.010
        )
        async let numeric = performRecognition(
            on: cgImage,
            pass: .numeric,
            usesLanguageCorrection: false,
            // Hole numbers and scores are the smallest text on the card; the default floor skips them.
            minimumTextHeight: 0.006
        )

        let merged = merge(languageCorrected: try await corrected, numeric: try await numeric)
        guard !merged.isEmpty else { throw ScorecardParsingError.noTextRecognized }
        return merged
    }

    func recognizeCell(in croppedImage: UIImage) async throws -> [ScorecardKit.TextObservation] {
        guard let cgImage = croppedImage.cgImage else { return [] }
        return try await performRecognition(
            on: cgImage,
            pass: .targetedCell,
            usesLanguageCorrection: false,
            minimumTextHeight: 0.05
        )
    }

    // MARK: - Recognition

    private func performRecognition(
        on cgImage: CGImage,
        pass: OCRPass,
        usesLanguageCorrection: Bool,
        minimumTextHeight: Float
    ) async throws -> [ScorecardKit.TextObservation] {
        try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                let results = (request.results as? [VNRecognizedTextObservation]) ?? []
                continuation.resume(returning: results.flatMap { Self.observations(from: $0, pass: pass) })
            }

            // Accuracy over speed: a scorecard is scanned once and then lived with, so a few hundred
            // milliseconds are worth spending to avoid a wrong score.
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = usesLanguageCorrection
            request.recognitionLanguages = ["en-US"]
            request.minimumTextHeight = minimumTextHeight
            request.revision = VNRecognizeTextRequestRevision3
            if usesLanguageCorrection {
                request.customWords = Self.scorecardVocabulary
            }

            let handler = VNImageRequestHandler(cgImage: cgImage, orientation: .up, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    /// Converts one Vision observation into our own type, splitting it at whitespace.
    ///
    /// Vision groups a whole table row into a single observation surprisingly often. Left whole, that row
    /// has one bounding box spanning eighteen columns and is useless for deciding which hole each value
    /// belongs to, so each token is given its own box derived from the recognized text's character ranges.
    private static func observations(from observation: VNRecognizedTextObservation, pass: OCRPass) -> [ScorecardKit.TextObservation] {
        guard let candidate = observation.topCandidates(3).first else { return [] }
        let alternatives = observation.topCandidates(3).dropFirst().map(\.string)
        let fullText = candidate.string

        var results: [ScorecardKit.TextObservation] = []
        var searchStart = fullText.startIndex

        for token in fullText.split(separator: " ", omittingEmptySubsequences: true) {
            guard let tokenRange = fullText.range(of: String(token), range: searchStart..<fullText.endIndex) else { continue }
            searchStart = tokenRange.upperBound

            // `boundingBox(for:)` gives the box of just this token, which is the whole point.
            let box: CGRect
            if let tokenObservation = try? candidate.boundingBox(for: tokenRange) {
                box = tokenObservation.boundingBox
            } else {
                box = observation.boundingBox
            }

            results.append(ScorecardKit.TextObservation(
                text: String(token),
                rect: CardRect.fromBottomLeftOrigin(
                    x: Double(box.origin.x),
                    y: Double(box.origin.y),
                    width: Double(box.width),
                    height: Double(box.height)
                ),
                confidence: Double(candidate.confidence),
                pass: pass,
                // Alternatives only make sense for a single-token observation; for a split row they would
                // be alternatives for the whole line, not this token.
                alternativeTexts: results.isEmpty && fullText == String(token) ? Array(alternatives) : []
            ))
        }

        if results.isEmpty {
            let box = observation.boundingBox
            results.append(ScorecardKit.TextObservation(
                text: fullText,
                rect: CardRect.fromBottomLeftOrigin(
                    x: Double(box.origin.x),
                    y: Double(box.origin.y),
                    width: Double(box.width),
                    height: Double(box.height)
                ),
                confidence: Double(candidate.confidence),
                pass: pass,
                alternativeTexts: Array(alternatives)
            ))
        }
        return results
    }

    // MARK: - Merging

    /// Combines the two passes, keeping whichever read each region better.
    ///
    /// Overlapping observations are the same piece of text seen twice. The choice between them is made on
    /// what the text *is*, not on raw confidence: for a numeric token the uncorrected pass is right by
    /// construction, and for a word the corrected pass is. Only when the two agree on neither does
    /// confidence decide.
    func merge(languageCorrected: [ScorecardKit.TextObservation], numeric: [ScorecardKit.TextObservation]) -> [ScorecardKit.TextObservation] {
        var result: [ScorecardKit.TextObservation] = []
        var consumedNumeric = Set<Int>()

        for corrected in languageCorrected {
            var bestIndex: Int?
            var bestOverlap = 0.35
            for (index, candidate) in numeric.enumerated() where !consumedNumeric.contains(index) {
                let overlap = corrected.rect.intersectionOverUnion(candidate.rect)
                if overlap > bestOverlap {
                    bestOverlap = overlap
                    bestIndex = index
                }
            }

            guard let bestIndex else {
                result.append(corrected)
                continue
            }
            consumedNumeric.insert(bestIndex)
            let numericMatch = numeric[bestIndex]

            if numericMatch.looksNumeric && !corrected.looksNumeric {
                // Language correction turned a number into a word. Keep the digits.
                result.append(numericMatch)
            } else if corrected.looksNumeric && !numericMatch.looksNumeric {
                result.append(corrected)
            } else if numericMatch.looksNumeric && corrected.looksNumeric {
                // Both read digits. Prefer the uncorrected pass, which never substitutes a word.
                result.append(numericMatch.confidence >= corrected.confidence * 0.85 ? numericMatch : corrected)
            } else {
                result.append(corrected.confidence >= numericMatch.confidence ? corrected : numericMatch)
            }
        }

        // Anything the numeric pass found on its own — usually the smallest digits, which the corrected
        // pass drops at its higher text-height floor.
        for (index, candidate) in numeric.enumerated() where !consumedNumeric.contains(index) {
            result.append(candidate)
        }
        return result
    }
}
