import SwiftUI
import ScorecardKit

/// Where the golfer points the app at their own scorecard-reading proxy.
///
/// The screen is deliberately plain-spoken. This is the only feature in the app that sends anything off the
/// phone, and it is off by default, so the text's job is to make what it does and does not do unambiguous
/// before anyone turns it on — not to sell it.
struct RemoteParserSettingsView: View {

    @Environment(\.dismiss) private var dismiss
    @Bindable var settings: RemoteParserSettings

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://…", text: $settings.endpointText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .font(.body.monospaced())
                    if let message = settings.validationMessage {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(Color.orange)
                    }
                } header: {
                    Text("AI scorecard reading")
                } footer: {
                    Text("On-device recognition reads printed course data well and handwriting badly — on some cards it finds no pencil at all. Point this at a small server of your own and the app can ask a vision model to read the handwritten scores instead.")
                }

                Section {
                    Label(
                        settings.isConfigured ? "Configured" : "Not set up — the app stays fully on-device",
                        systemImage: settings.isConfigured ? "checkmark.circle.fill" : "iphone"
                    )
                    .foregroundStyle(settings.isConfigured ? Theme.accent : .secondary)

                    if settings.hasAcceptedPrivacyNotice {
                        Button("Withdraw permission to send photos", role: .destructive) {
                            settings.hasAcceptedPrivacyNotice = false
                        }
                    }
                }

                Section("What gets sent") {
                    bullet("The scorecard photo, resized to 1600px, and nothing else.")
                    bullet("Only when you tap “Read with AI” on the review screen. Never automatically, and never during a scan.")
                    bullet("Only the handwritten scores come back. Par, stroke index and yardages keep coming from the course template.")
                    bullet("Whatever comes back is checked against the totals written on your card before any of it is used.")
                }

                Section("What never gets sent") {
                    bullet("Your saved rounds, your course history and the scratch-off map. Those never leave the phone.")
                    bullet("An API key. The app has never held one — that is the whole reason this points at a server instead.")
                }

                Section {
                    Link(destination: URL(string: "https://github.com/pearlman11/scratch-scorecard/tree/main/Proxy/cloudflare-worker")!) {
                        Label("How to deploy the server", systemImage: "arrow.up.forward.square")
                    }
                } footer: {
                    Text("It is about two hundred lines and runs free on Cloudflare Workers. Your API key lives there, encrypted, and never touches this phone.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("•").foregroundStyle(.secondary)
            Text(text).font(.footnote)
        }
    }
}

/// The one-time, in-words consent asked before the first photo leaves the phone.
struct RemoteParseConsentView: View {

    @Environment(\.dismiss) private var dismiss
    let onAccept: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("This sends your photo off the phone")
                        .font(.title2.bold())

                    Text("Everything else in Golf Tracker runs on this device. Reading the handwriting with AI does not: the scorecard photo is sent to the server you set up, which passes it to a vision model and returns the scores it read.")

                    Text("The photo has your handwriting on it and probably your name. Only send it somewhere you are happy for it to go.")

                    VStack(alignment: .leading, spacing: 10) {
                        point("The image is resized to 1600px before it is sent.")
                        point("Only the handwritten scores are taken from the reply.")
                        point("The scores are checked against the totals written on your card before they are used.")
                        point("Nothing is sent unless you tap “Read with AI”.")
                    }
                    .padding()
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))

                    Text("You can withdraw this at any time in Settings.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(Theme.cardPadding)
            }
            .background(Color(.systemGroupedBackground))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Not now") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send the photo") { onAccept() }
                        .fontWeight(.semibold)
                }
            }
        }
    }

    private func point(_ text: String) -> some View {
        Label(text, systemImage: "checkmark.circle.fill")
            .font(.footnote)
            .labelStyle(.titleAndIcon)
            .foregroundStyle(.primary)
    }
}
