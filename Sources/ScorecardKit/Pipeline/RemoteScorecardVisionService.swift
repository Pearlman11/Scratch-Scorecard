import Foundation

/// A structured scorecard returned by a remote multimodal model.
///
/// Deliberately minimal and strictly typed. A remote model returns JSON, and the temptation is to thread a
/// dictionary through the app; this type is the boundary where that JSON becomes Swift or is rejected.
public struct RemoteScorecardPayload: Codable, Sendable {
    public struct Hole: Codable, Sendable {
        public var holeNumber: Int
        /// The model's reading of the handwritten score. `nil` means it could not read it — which the
        /// service is required to report honestly rather than filling in.
        public var playerScore: Int?
        /// The model's own confidence, `0...1`.
        public var confidence: Double?

        public init(holeNumber: Int, playerScore: Int?, confidence: Double?) {
            self.holeNumber = holeNumber
            self.playerScore = playerScore
            self.confidence = confidence
        }
    }

    public var courseName: String?
    public var teeName: String?
    public var playerName: String?
    public var holes: [Hole]

    public init(courseName: String?, teeName: String?, playerName: String?, holes: [Hole]) {
        self.courseName = courseName
        self.teeName = teeName
        self.playerName = playerName
        self.holes = holes
    }
}

/// An optional second opinion on a card that local OCR struggled with.
///
/// ## Why this is a protocol with a disabled default
///
/// Handwritten scores are meaningfully harder than printed metadata, and a multimodal model is genuinely
/// better at them. But the MVP must work with no network, no account and no server, so the capability is
/// declared here and left switched off. `LocalOnlyRemoteVisionService` is the shipping implementation: it
/// reports that no remote parser is configured, and the app routes uncertain scores to manual review, which
/// is exactly what it does today.
///
/// ## Security
///
/// An implementation of this protocol must **never** hold a model-provider API key. A key shipped in an
/// iOS binary is a published key — the app bundle is readable by anyone who installs it. Any real
/// implementation calls a first-party server that holds the credential and proxies the request.
///
/// ## Privacy
///
/// Every other path in this app is on-device. Enabling a remote parser sends the golfer's photograph off
/// the phone, so an implementation must be opt-in per scan and say so plainly at the point of use.
public protocol RemoteScorecardVisionService: Sendable {
    /// Whether a remote parse can currently be attempted.
    var isConfigured: Bool { get }
    /// Whether the golfer has opted in to sending this image off-device.
    var hasUserConsent: Bool { get }

    /// Requests a structured reading of `imageData`.
    /// - Parameter holeCount: how many holes the local parser believes the card covers.
    func parseScorecard(imageData: Data, holeCount: Int) async throws -> RemoteScorecardPayload
}

public enum RemoteScorecardVisionError: Error, LocalizedError, Sendable {
    case notConfigured
    case consentNotGranted
    case transport(String)
    case malformedResponse(String)

    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "No remote scorecard parser is configured. Scores stay on this device."
        case .consentNotGranted:
            return "Sending this photo for a second opinion needs your permission first."
        case .transport(let detail):
            return "The remote parser could not be reached: \(detail)"
        case .malformedResponse(let detail):
            return "The remote parser returned something unusable: \(detail)"
        }
    }
}

/// The shipping implementation: there is no remote parser, and the app is fully functional without one.
public struct LocalOnlyRemoteVisionService: RemoteScorecardVisionService {
    public init() {}
    public var isConfigured: Bool { false }
    public var hasUserConsent: Bool { false }

    public func parseScorecard(imageData: Data, holeCount: Int) async throws -> RemoteScorecardPayload {
        throw RemoteScorecardVisionError.notConfigured
    }
}

/// Merges a remote reading into a locally-parsed card.
///
/// The merge is one-directional and narrow on purpose: a remote result may fill a score the local parser
/// left empty, or replace one it read poorly, and nothing else. It cannot touch par, stroke index, yardage
/// or the course — those already come from a verified template or from printed text the local parser read
/// well, and a remote model is not a better source for them.
public enum RemoteParseMerger {

    /// - Parameter minimumRemoteConfidence: readings below this are ignored entirely.
    /// - Returns: the merged card and how many scores the remote reading actually changed.
    public static func merge(
        payload: RemoteScorecardPayload,
        into scorecard: ParsedScorecard,
        minimumRemoteConfidence: Double = 0.6
    ) -> (scorecard: ParsedScorecard, updatedHoles: [Int]) {
        var result = scorecard
        var updated: [Int] = []

        for remoteHole in payload.holes {
            guard let index = result.holes.firstIndex(where: { $0.holeNumber == remoteHole.holeNumber }) else { continue }
            let existing = result.holes[index].playerScore

            // The golfer's own correction always wins.
            guard existing.provenance != .userEdited else { continue }
            guard let remoteScore = remoteHole.playerScore else { continue }
            guard ScoreMath.plausibleScoreRange.contains(remoteScore) else { continue }
            let remoteConfidence = remoteHole.confidence ?? 0.5
            guard remoteConfidence >= minimumRemoteConfidence else { continue }
            // Only improve on a value the local parser was unsure of.
            guard existing.value == nil || existing.confidence < remoteConfidence else { continue }

            result.holes[index].playerScore = ParsedField(
                value: remoteScore,
                confidence: remoteConfidence,
                provenance: .multimodalFallback,
                rawText: existing.rawText
            )
            updated.append(remoteHole.holeNumber)
        }
        return (result, updated)
    }
}
