import SwiftUI

/// Read-only display of a bundled legal document, reachable anytime from
/// Profile. Not used for the first-launch acceptance gate (see
/// `TermsAcceptanceGate`), which reuses the same bundled text.
struct LegalDocumentView: View {
    let title: String
    let bodyText: String
    let hostedURL: URL

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(bodyText)
                    .font(.system(size: 14))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)

                Link("View the hosted version", destination: hostedURL)
                    .font(.footnote)
            }
            .padding(20)
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
