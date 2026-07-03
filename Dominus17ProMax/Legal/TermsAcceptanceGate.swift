import SwiftUI

/// Full-screen, blocking gate shown on first launch (and again whenever
/// `LegalContent.currentVersion` changes) until the user taps Agree.
/// Tapping Agree is a deliberate, recorded action and legally functions as
/// an electronic signature under the U.S. ESIGN Act — no separate signature
/// or initials are needed.
struct TermsAcceptanceGate: View {
    let onAgree: () -> Void

    @State private var selectedDoc: Doc = .terms

    private enum Doc: String, CaseIterable {
        case terms = "Terms of Use"
        case privacy = "Privacy Policy"
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 6) {
                Text("Before You Start")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Text("Please review and agree to continue.")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.5))
            }
            .padding(.top, 24)
            .padding(.bottom, 16)

            Picker("", selection: $selectedDoc) {
                ForEach(Doc.allCases, id: \.self) { doc in
                    Text(doc.rawValue).tag(doc)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 20)
            .padding(.bottom, 12)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(selectedDoc == .terms ? LegalContent.termsOfUseText : LegalContent.privacyPolicyText)
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.85))
                        .textSelection(.enabled)

                    Link(
                        "View the hosted version",
                        destination: selectedDoc == .terms ? LegalContent.termsOfUseURL : LegalContent.privacyPolicyURL
                    )
                    .font(.footnote)
                }
                .padding(20)
            }

            VStack(spacing: 12) {
                Button {
                    LegalAcceptance.recordAcceptance()
                    onAgree()
                } label: {
                    Text("Agree & Continue")
                        .font(.system(size: 17, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.white)
                        .foregroundColor(.black)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)

                Text("By tapping Agree & Continue, you accept the Terms of Use and Privacy Policy above.")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.4))
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 24)
        }
        .background(Color.black.ignoresSafeArea())
    }
}
