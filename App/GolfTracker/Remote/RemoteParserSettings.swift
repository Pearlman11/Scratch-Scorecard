import Foundation
import SwiftUI
import ScorecardKit

/// Where the optional AI parser points, and whether the golfer has agreed to use it.
///
/// ## Why there is a URL here and not an API key
///
/// The spec for this app is explicit, and it is the right call: no model-provider API key goes in the
/// iPhone binary. An app bundle is a zip file that anyone who installs the app can open, and `strings` on
/// the executable is enough to lift a key out of it — a key shipped to a thousand phones is a key
/// published a thousand times, billed to whoever owns it until they notice. Obfuscating it, splitting it
/// across constants or fetching it at launch and caching it are all the same mistake with extra steps.
///
/// So the phone holds the *address of a server*, which is public information by nature, and that server
/// holds the credential. `Proxy/cloudflare-worker` in this repository is a deployable implementation of
/// that server; the golfer deploys their own and pastes its URL here. Nothing secret is ever stored on the
/// device, so nothing secret can leak from it.
@MainActor
@Observable
final class RemoteParserSettings {

    static let shared = RemoteParserSettings()

    private enum Keys {
        static let endpoint = "remoteParser.endpoint"
        static let accepted = "remoteParser.privacyAccepted"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.endpointText = defaults.string(forKey: Keys.endpoint) ?? ""
        self.hasAcceptedPrivacyNotice = defaults.bool(forKey: Keys.accepted)
    }

    /// As typed by the golfer, so an in-progress edit is not thrown away by validation.
    var endpointText: String {
        didSet { defaults.set(endpointText, forKey: Keys.endpoint) }
    }

    /// Set once the golfer has been told, in words, that using this sends the photo off their phone.
    var hasAcceptedPrivacyNotice: Bool {
        didSet { defaults.set(hasAcceptedPrivacyNotice, forKey: Keys.accepted) }
    }

    /// The endpoint, if what is typed is a usable one.
    ///
    /// HTTPS is required rather than merely preferred. The request carries a photograph of the golfer's
    /// scorecard, which has their name on it; over plain HTTP that is readable by every hop in between.
    var endpoint: URL? {
        let trimmed = endpointText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let url = URL(string: trimmed),
              url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty else { return nil }
        return url
    }

    var isConfigured: Bool { endpoint != nil }

    /// Why the endpoint as typed is not usable, for the settings field to show.
    var validationMessage: String? {
        let trimmed = endpointText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        if endpoint != nil { return nil }
        if let scheme = URL(string: trimmed)?.scheme?.lowercased(), scheme != "https" {
            return "The address must start with https:// — the photo is not sent over an unencrypted connection."
        }
        return "That does not look like a web address."
    }

    /// The service to use for this scan, or `nil` when the app should stay entirely on-device.
    func makeService(session: URLSession = .shared) -> (any RemoteScorecardVisionService)? {
        guard let endpoint else { return nil }
        return ProxiedScorecardVisionService(
            endpoint: endpoint,
            hasUserConsent: hasAcceptedPrivacyNotice,
            session: session
        )
    }
}
