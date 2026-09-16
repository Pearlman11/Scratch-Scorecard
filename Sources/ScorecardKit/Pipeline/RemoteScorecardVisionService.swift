import Foundation

/// A structured scorecard returned by a remote multimodal model.
///
/// Deliberately minimal and strictly typed. A remote model returns JSON, and the temptation is to thread a
/// dictionary through the app; this type is the boundary where that JSON becomes Swift or is rejected.
///
/// The shape mirrors what a card actually contains — *rows* of handwriting, each with the subtotals the
/// golfer wrote beside them — rather than a single flat list of scores. That matters for two reasons. A
/// four-ball card has four rows and the app cannot know which one is the golfer's until they say so. And
/// the written OUT / IN / TOTAL are what make a remote reading checkable: a row that sums to the total
/// written next to it has been confirmed by the card itself, which is a far stronger guarantee than a
/// model's own confidence score.
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

    /// One handwritten row on the card.
    public struct Player: Codable, Sendable {
        /// The name written at the head of the row, when legible.
        public var name: String?
        public var holes: [Hole]
        /// The subtotals written in this row's OUT / IN / TOTAL columns, transcribed separately from the
        /// per-hole cells so the two readings can be checked against each other.
        public var writtenOut: Int?
        public var writtenIn: Int?
        public var writtenTotal: Int?

        public init(
            name: String? = nil,
            holes: [Hole],
            writtenOut: Int? = nil,
            writtenIn: Int? = nil,
            writtenTotal: Int? = nil
        ) {
            self.name = name
            self.holes = holes
            self.writtenOut = writtenOut
            self.writtenIn = writtenIn
            self.writtenTotal = writtenTotal
        }

        /// The model's reading of one hole, when it returned one.
        public func hole(_ number: Int) -> Hole? {
            holes.first { $0.holeNumber == number }
        }
    }

    public var courseName: String?
    public var teeName: String?
    public var players: [Player]

    public init(courseName: String?, teeName: String?, players: [Player]) {
        self.courseName = courseName
        self.teeName = teeName
        self.players = players
    }

    /// Convenience for the single-row case.
    public init(courseName: String?, teeName: String?, playerName: String?, holes: [Hole]) {
        self.init(
            courseName: courseName,
            teeName: teeName,
            players: [Player(name: playerName, holes: holes)]
        )
    }
}

/// An optional second opinion on a card that local OCR struggled with.
///
/// ## Why this exists
///
/// Printed course data and handwritten scores are not the same problem. Vision's text recognizer is trained
/// on print, and on a real card it reads every printed row — par, stroke index, yardages — while returning
/// *nothing at all* for pencil. Not a bad reading: no detection. Everything downstream of that stage,
/// including the checksum solver, then has nothing to work with. A multimodal model does not share that
/// blind spot, which is why the handwriting — and only the handwriting — is worth sending out.
///
/// ## What a remote reading is allowed to touch
///
/// Scores, and nothing else. Par, stroke index, yardage and the course are already restored from a verified
/// template or read confidently from print, and a remote model is not a better source for them. See
/// `RemoteParseIntegrator`.
///
/// ## Security
///
/// An implementation of this protocol must **never** hold a model-provider API key. A key shipped in an
/// iOS binary is a published key — the app bundle is readable by anyone who installs it, and `strings` on
/// the binary is all it takes. Any real implementation calls a first-party server that holds the credential
/// and proxies the request. `ProxiedScorecardVisionService` in the app target is that implementation, and
/// `Proxy/cloudflare-worker` is the server.
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
    /// - Parameters:
    ///   - imageData: the rectified card, as JPEG.
    ///   - holeCount: how many holes the local parser believes the card covers.
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

/// The default: there is no remote parser, and the app is fully functional without one.
///
/// This is what ships until the golfer configures a proxy of their own, and it is what every test runs
/// against. A build with no server behind it is a working build.
public struct LocalOnlyRemoteVisionService: RemoteScorecardVisionService {
    public init() {}
    public var isConfigured: Bool { false }
    public var hasUserConsent: Bool { false }

    public func parseScorecard(imageData: Data, holeCount: Int) async throws -> RemoteScorecardPayload {
        throw RemoteScorecardVisionError.notConfigured
    }
}
