import SwiftUI

struct LoadingView: View {
    let progress: Double        // 0.0 -> 1.0
    let status: String

    @State private var pulse = false

    private var percentText: String {
        "\(Int((progress * 100).rounded()))%"
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 18) {
                Text("Dominus")
                    .font(.largeTitle.bold())
                    .foregroundStyle(.white)

                Text(progress >= 1.0 ? "Download complete" : "Loading…")
                    .font(.headline)
                    .foregroundStyle(.white.opacity(0.9))
                    .opacity(pulse ? 0.25 : 1.0)
                    .animation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true), value: pulse)
                    .onAppear { pulse = true }

                Text(percentText)
                    .font(.system(size: 44, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)

                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .tint(.white)
                    .frame(width: 260)

                Text(status.isEmpty ? "Preparing…" : status)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 300)
            }
            .padding()
        }
    }
}
