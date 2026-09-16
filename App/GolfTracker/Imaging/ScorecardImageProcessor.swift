import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit
import Vision
import ScorecardKit

/// The two images every scan produces.
///
/// Keeping both is a product requirement, not an implementation detail: the golfer's photograph is part of
/// the round's record and must survive untouched, while OCR wants an image that has been flattened,
/// desaturated and pushed to high contrast — which is exactly what you would not want to look at later.
struct ProcessedScorecardImage {
    /// Exactly what the camera or Photos gave us, with only EXIF orientation resolved.
    let original: UIImage
    /// The version fed to Vision. Never shown to the golfer, never saved in place of the original.
    let normalized: UIImage
    /// Perspective correction was applied.
    let wasPerspectiveCorrected: Bool
    /// Rough focus estimate, `0...1`. Low values mean the photo is probably too blurry to read.
    let sharpness: Double
    /// Fraction of the image that is blown out, `0...1`. High values mean glare.
    let glareFraction: Double
}

/// Prepares a photographed scorecard for recognition.
///
/// A scorecard is close to the worst case for OCR: small printed digits on a grid, photographed at an
/// angle, in sunlight, often with a glossy finish. Each step here targets one of those specifically, and
/// the order matters — perspective first (so the grid is rectangular before anything samples it), then
/// tone, then sharpening.
actor ScorecardImageProcessor {

    private let context: CIContext

    init() {
        // Software rendering keeps this usable from a background actor without fighting for the GPU with
        // the camera preview.
        self.context = CIContext(options: [.useSoftwareRenderer: false, .cacheIntermediates: false])
    }

    /// Runs the full pipeline.
    ///
    /// - Parameters:
    ///   - image: the photograph as captured or imported.
    ///   - alreadyRectified: `true` when the image came from `VNDocumentCameraViewController`, which has
    ///     already detected the card's edges and corrected perspective. Running rectangle detection again
    ///     on an already-cropped card tends to latch onto an inner table border and crop the card in half.
    func process(_ image: UIImage, alreadyRectified: Bool) async throws -> ProcessedScorecardImage {
        let upright = image.normalizedOrientation()
        guard let ciImage = CIImage(image: upright) else {
            throw ImageProcessingError.unreadableImage
        }

        var working = ciImage
        var correctedPerspective = false
        if !alreadyRectified, let rectified = try? detectAndCorrectPerspective(in: working) {
            working = rectified
            correctedPerspective = true
        }

        let quality = measureQuality(of: working)
        let enhanced = enhanceForRecognition(working)

        guard let normalizedCG = context.createCGImage(enhanced, from: enhanced.extent) else {
            throw ImageProcessingError.renderFailed
        }

        return ProcessedScorecardImage(
            original: upright,
            normalized: UIImage(cgImage: normalizedCG),
            wasPerspectiveCorrected: correctedPerspective,
            sharpness: quality.sharpness,
            glareFraction: quality.glareFraction
        )
    }

    /// Re-renders a region of the normalized image, scaled up, for a targeted second look at one cell.
    ///
    /// Vision's recognizer works on a fixed internal resolution, so a handwritten digit occupying 20 pixels
    /// of a full-card photo is far below what it can resolve. Cropping to the cell and upscaling gives that
    /// same digit a few hundred pixels, which is the difference between a guess and a reading.
    func upscaledCrop(of image: UIImage, rect: CardRect, scale: CGFloat = 4.0, padding: Double = 0.25) -> UIImage? {
        guard let cgImage = image.cgImage else { return nil }
        let width = CGFloat(cgImage.width)
        let height = CGFloat(cgImage.height)

        let padX = rect.width * padding
        let padY = rect.height * padding
        let cropRect = CGRect(
            x: (rect.minX - padX) * width,
            y: (rect.minY - padY) * height,
            width: (rect.width + padX * 2) * width,
            height: (rect.height + padY * 2) * height
        ).integral.intersection(CGRect(x: 0, y: 0, width: width, height: height))

        guard cropRect.width > 2, cropRect.height > 2, let cropped = cgImage.cropping(to: cropRect) else {
            return nil
        }

        let ciCropped = CIImage(cgImage: cropped)
        let scaled = ciCropped.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        // Lanczos keeps the stroke edges of a handwritten digit crisp; plain scaling smears them.
        let filter = CIFilter.lanczosScaleTransform()
        filter.inputImage = ciCropped
        filter.scale = Float(scale)
        filter.aspectRatio = 1
        let output = filter.outputImage ?? scaled

        guard let result = context.createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: result)
    }

    // MARK: - Perspective

    /// Finds the card in the frame and flattens it.
    ///
    /// Constrained to shapes that could plausibly be a scorecard: a scorecard is a wide, low rectangle, so
    /// allowing any aspect ratio invites the detector to pick a table border, a cart path or the sky.
    private func detectAndCorrectPerspective(in image: CIImage) throws -> CIImage {
        let request = VNDetectRectanglesRequest()
        request.minimumAspectRatio = 0.25
        request.maximumAspectRatio = 1.0
        request.minimumSize = 0.35
        request.minimumConfidence = 0.7
        request.maximumObservations = 1
        request.quadratureTolerance = 25

        let handler = VNImageRequestHandler(ciImage: image, options: [:])
        try handler.perform([request])

        guard let rectangle = request.results?.first else {
            throw ImageProcessingError.noRectangleFound
        }

        // Vision reports normalized, bottom-left-origin points; the filter wants image coordinates.
        func point(_ normalized: CGPoint) -> CGPoint {
            CGPoint(
                x: image.extent.origin.x + normalized.x * image.extent.width,
                y: image.extent.origin.y + normalized.y * image.extent.height
            )
        }

        let filter = CIFilter.perspectiveCorrection()
        filter.inputImage = image
        filter.topLeft = point(rectangle.topLeft)
        filter.topRight = point(rectangle.topRight)
        filter.bottomLeft = point(rectangle.bottomLeft)
        filter.bottomRight = point(rectangle.bottomRight)
        filter.crop = true

        guard let output = filter.outputImage, output.extent.width > 64, output.extent.height > 64 else {
            throw ImageProcessingError.noRectangleFound
        }
        return output
    }

    // MARK: - Enhancement

    /// Flattens lighting and raises contrast so small printed digits survive recognition.
    private func enhanceForRecognition(_ image: CIImage) -> CIImage {
        var working = image

        // 1. Lift shadows and pull back blown highlights. A scorecard photographed in sun has both, often
        //    in the same frame, and a global curve cannot fix them together.
        let shadowHighlight = CIFilter.highlightShadowAdjust()
        shadowHighlight.inputImage = working
        shadowHighlight.shadowAmount = 0.55
        shadowHighlight.highlightAmount = 0.75
        shadowHighlight.radius = 12
        working = shadowHighlight.outputImage ?? working

        // 2. Drop colour. Scorecards use coloured tee rows, and those hues carry no information for a text
        //    recognizer while costing it contrast.
        let mono = CIFilter.colorControls()
        mono.inputImage = working
        mono.saturation = 0
        mono.contrast = 1.35
        mono.brightness = 0.02
        working = mono.outputImage ?? working

        // 3. Even out a gradient across the card — the usual result of a shadow from the photographer or
        //    an angled light. Dividing by a heavily blurred copy of the image approximates the illumination
        //    field and removes it, which is what makes an unevenly lit card readable at all.
        if let flattened = flattenIllumination(working) {
            working = flattened
        }

        // 4. Sharpen the digit strokes. Modest radius: a large one turns grid lines into halos that the
        //    recognizer then reads as characters.
        let sharpen = CIFilter.unsharpMask()
        sharpen.inputImage = working
        sharpen.radius = 1.6
        sharpen.intensity = 0.65
        working = sharpen.outputImage ?? working

        return working.cropped(to: image.extent)
    }

    /// Divides the image by a blurred copy of itself to cancel a smooth lighting gradient.
    private func flattenIllumination(_ image: CIImage) -> CIImage? {
        let blur = CIFilter.gaussianBlur()
        blur.inputImage = image.clampedToExtent()
        // Radius scaled to the image so behaviour does not change with capture resolution.
        blur.radius = Float(max(image.extent.width, image.extent.height) / 28)
        guard let background = blur.outputImage?.cropped(to: image.extent) else { return nil }

        let divide = CIFilter.divideBlendMode()
        divide.inputImage = image
        divide.backgroundImage = background
        guard let divided = divide.outputImage else { return nil }

        // The division normalizes everything toward white; pull the mid-tones back down so ink is dark.
        let gamma = CIFilter.gammaAdjust()
        gamma.inputImage = divided
        gamma.power = 1.8
        return gamma.outputImage?.cropped(to: image.extent)
    }

    // MARK: - Quality

    /// Cheap focus and glare estimates, used to tell the golfer to re-shoot rather than to fail silently.
    private func measureQuality(of image: CIImage) -> (sharpness: Double, glareFraction: Double) {
        // Sharpness: the standard deviation of a Laplacian-style edge response. A blurred photo has little
        // high-frequency energy, so this collapses toward zero.
        let edges = CIFilter.edges()
        edges.inputImage = image
        edges.intensity = 1.0

        var sharpness = 0.5
        if let edgeImage = edges.outputImage {
            let stats = CIFilter.areaAverage()
            stats.inputImage = edgeImage
            stats.extent = image.extent
            if let output = stats.outputImage {
                var bitmap = [UInt8](repeating: 0, count: 4)
                context.render(
                    output,
                    toBitmap: &bitmap,
                    rowBytes: 4,
                    bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                    format: .RGBA8,
                    colorSpace: CGColorSpaceCreateDeviceRGB()
                )
                let mean = Double(bitmap[0]) / 255.0
                // Empirically, a well-focused card lands above ~0.06 mean edge energy.
                sharpness = min(1.0, mean / 0.06)
            }
        }

        // Glare: the fraction of pixels at or near pure white.
        var glare = 0.0
        let threshold = CIFilter.colorClamp()
        threshold.inputImage = image
        threshold.minComponents = CIVector(x: 0.93, y: 0.93, z: 0.93, w: 0)
        threshold.maxComponents = CIVector(x: 1, y: 1, z: 1, w: 1)
        if let clamped = threshold.outputImage {
            let average = CIFilter.areaAverage()
            average.inputImage = clamped
            average.extent = image.extent
            if let output = average.outputImage {
                var bitmap = [UInt8](repeating: 0, count: 4)
                context.render(
                    output,
                    toBitmap: &bitmap,
                    rowBytes: 4,
                    bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                    format: .RGBA8,
                    colorSpace: CGColorSpaceCreateDeviceRGB()
                )
                let mean = Double(bitmap[0]) / 255.0
                glare = max(0, (mean - 0.93) / 0.07)
            }
        }

        return (sharpness, min(1, glare))
    }
}

enum ImageProcessingError: Error, LocalizedError {
    case unreadableImage
    case renderFailed
    case noRectangleFound

    var errorDescription: String? {
        switch self {
        case .unreadableImage: return "That image could not be opened."
        case .renderFailed: return "The photo could not be prepared for scanning."
        case .noRectangleFound: return "No scorecard edges were found in the photo."
        }
    }
}

extension UIImage {
    /// Returns a copy drawn upright, so every later step can ignore EXIF orientation.
    ///
    /// Vision's normalized coordinates are relative to the *oriented* image, and a scorecard photographed
    /// in landscape on a phone held portrait carries an orientation flag. Resolving it once, here, is what
    /// keeps every bounding box downstream meaningful.
    func normalizedOrientation() -> UIImage {
        guard imageOrientation != .up else { return self }
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = scale
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { _ in
            draw(in: CGRect(origin: .zero, size: size))
        }
    }
}
