import SwiftUI

// MARK: - Splash loading screen (blocks all interaction until fully ready)

struct SplashLoadingView: View {
    let gemmaProgress: Double
    let gemmaStatus: String
    let whisperProgress: Double
    let whisperStatus: String

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                VStack(spacing: 10) {
                    Text("Dominus")
                        .font(.system(size: 52, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    Text("On-device AI assistant")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.4))
                }

                Spacer()

                VStack(spacing: 14) {
                    LoadingBarView(
                        icon: "cpu.fill",
                        label: "Language Model",
                        status: gemmaStatus,
                        progress: gemmaProgress
                    )
                    LoadingBarView(
                        icon: "waveform",
                        label: "Voice Recognition",
                        status: whisperStatus,
                        progress: whisperProgress
                    )
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 64)
            }
        }
    }
}

// MARK: - Per-component loading pill

struct LoadingBarView: View {
    let icon: String
    let label: String
    let status: String
    let progress: Double

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Text(label)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                    Spacer()
                    Text("\(Int((progress * 100).rounded()))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.6))
                        .animation(nil, value: progress)
                }

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.white.opacity(0.10))
                            .frame(height: 3)
                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: [.blue, .cyan],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .frame(width: max(0, geo.size.width * progress), height: 3)
                            .animation(.linear(duration: 0.12), value: progress)
                    }
                }
                .frame(height: 3)

                if !status.isEmpty {
                    Text(status)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.45))
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
                )
        )
    }
}
