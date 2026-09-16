import Foundation
import UIKit
import ScorecardKit

/// Asks a first-party proxy to read the handwriting on a card.
///
/// The proxy is the only party that holds a model-provider credential; this type holds its address and
/// nothing else. See `RemoteParserSettings` for why that division is not negotiable, and
/// `Proxy/cloudflare-worker` for the server.
///
/// Everything this returns is treated as untrusted input. A remote model is a better reader of pencil than
/// Vision is, but it is still a system that produces plausible text when it cannot read something, so the
/// response is range-checked here and then audited against the card's own arithmetic by
/// `RemoteScoreAudit` before a single number reaches the golfer's scorecard.
struct ProxiedScorecardVisionService: RemoteScorecardVisionService {

    let endpoint: URL
    let hasUserConsent: Bool
    let session: URLSession

    /// The card is resized before it is sent.
    ///
    /// A modern iPhone photo is 12 MP and several megabytes; a scorecard's digits are legible at a small
    /// fraction of that. Sending less makes the round-trip faster, cheaper and — the part that actually
    /// matters — means less of the golfer's image leaves the phone than would otherwise.
    static let maximumEdge: CGFloat = 1600
    static let jpegQuality: CGFloat = 0.8

    /// How many rows the app will accept from one card. A scorecard has room for a foursome or so; a
    /// response claiming dozens is a malfunction, not a large group.
    static let maximumPlayers = 8

    init(endpoint: URL, hasUserConsent: Bool, session: URLSession = .shared) {
        self.endpoint = endpoint
        self.hasUserConsent = hasUserConsent
        self.session = session
    }

    var isConfigured: Bool { true }

    // MARK: - Wire types

    private struct Request: Encodable {
        let holeCount: Int
        let imageMediaType: String
        /// Base64 JPEG. The proxy forwards it as an image block; it never stores it.
        let image: String
    }

    private struct Response: Decodable {
        struct Hole: Decodable {
            let holeNumber: Int
            let playerScore: Int?
            let confidence: Double?
        }
        struct Player: Decodable {
            let name: String?
            let holes: [Hole]?
            let writtenOut: Int?
            let writtenIn: Int?
            let writtenTotal: Int?
        }
        let courseName: String?
        let teeName: String?
        let players: [Player]?
        /// Set by the proxy when it could not complete the request.
        let error: String?
    }

    // MARK: - Request

    func parseScorecard(imageData: Data, holeCount: Int) async throws -> RemoteScorecardPayload {
        guard hasUserConsent else { throw RemoteScorecardVisionError.consentNotGranted }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // Reading a card takes the model a few seconds; a golfer on course data needs room for that
        // without the request being abandoned, but not so much that a dead server hangs the screen.
        request.timeoutInterval = 60
        request.httpBody = try JSONEncoder().encode(Request(
            holeCount: holeCount,
            imageMediaType: "image/jpeg",
            image: imageData.base64EncodedString()
        ))

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw RemoteScorecardVisionError.transport(error.localizedDescription)
        }

        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            let detail = (try? JSONDecoder().decode(Response.self, from: data))?.error
            throw RemoteScorecardVisionError.transport(detail ?? "the server returned \(http.statusCode).")
        }

        let decoded: Response
        do {
            decoded = try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw RemoteScorecardVisionError.malformedResponse(error.localizedDescription)
        }
        if let error = decoded.error {
            throw RemoteScorecardVisionError.transport(error)
        }
        return try payload(from: decoded, holeCount: holeCount)
    }

    /// Converts the response into the app's own types, discarding anything that is not a possible reading.
    ///
    /// Out-of-range values become `nil` rather than being clamped into range. A "score" of 47 is not a 15
    /// the model was hazy about; it is a cell that was not read, and saying so is the honest outcome.
    private func payload(from response: Response, holeCount: Int) throws -> RemoteScorecardPayload {
        guard let rawPlayers = response.players, !rawPlayers.isEmpty else {
            return RemoteScorecardPayload(courseName: response.courseName, teeName: response.teeName, players: [])
        }

        let players: [RemoteScorecardPayload.Player] = rawPlayers.prefix(Self.maximumPlayers).map { raw in
            var seen = Set<Int>()
            let holes: [RemoteScorecardPayload.Hole] = (raw.holes ?? []).compactMap { hole in
                guard (1...max(holeCount, 1)).contains(hole.holeNumber), seen.insert(hole.holeNumber).inserted else { return nil }
                let score = hole.playerScore.flatMap { ScoreMath.plausibleScoreRange.contains($0) ? $0 : nil }
                return RemoteScorecardPayload.Hole(
                    holeNumber: hole.holeNumber,
                    playerScore: score,
                    confidence: hole.confidence.map { min(max($0, 0), 1) }
                )
            }
            return RemoteScorecardPayload.Player(
                name: raw.name?.trimmingCharacters(in: .whitespacesAndNewlines),
                holes: holes,
                writtenOut: Self.plausibleSubtotal(raw.writtenOut, holes: min(9, holeCount)),
                writtenIn: Self.plausibleSubtotal(raw.writtenIn, holes: max(0, holeCount - 9)),
                writtenTotal: Self.plausibleSubtotal(raw.writtenTotal, holes: holeCount)
            )
        }

        return RemoteScorecardPayload(
            courseName: response.courseName,
            teeName: response.teeName,
            players: players
        )
    }

    /// A subtotal has to be a possible sum of the holes it covers, or it is not a subtotal.
    ///
    /// This is a validity check, never a source of values: a figure outside the range is dropped, and a
    /// missing one is never replaced by a plausible-looking guess.
    private static func plausibleSubtotal(_ value: Int?, holes: Int) -> Int? {
        guard let value, holes > 0 else { return nil }
        let range = holes * ScoreMath.plausibleScoreRange.lowerBound...holes * ScoreMath.plausibleScoreRange.upperBound
        return range.contains(value) ? value : nil
    }
}

extension ProxiedScorecardVisionService {

    /// Prepares a captured card for sending: downscaled, JPEG, orientation resolved.
    ///
    /// The *unenhanced* image is the one to send. The normalized copy that Vision reads has been
    /// contrast-stretched, illumination-flattened and sharpened, all of which help a recognizer trained on
    /// print and actively hurt here — those filters are quite capable of erasing faint pencil altogether.
    /// A multimodal model handles ordinary photographic lighting on its own.
    static func imageData(for image: UIImage) -> Data? {
        let upright = image.normalizedOrientation()
        let longestEdge = max(upright.size.width, upright.size.height)
        guard longestEdge > 0 else { return nil }

        let scale = min(1, maximumEdge / longestEdge)
        guard scale < 1 else { return upright.jpegData(compressionQuality: jpegQuality) }

        let target = CGSize(width: upright.size.width * scale, height: upright.size.height * scale)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let resized = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            upright.draw(in: CGRect(origin: .zero, size: target))
        }
        return resized.jpegData(compressionQuality: jpegQuality)
    }
}
