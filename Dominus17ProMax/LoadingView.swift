import SwiftUI

// MARK: - Splash loading screen (blocks all interaction until fully ready)

struct SplashLoadingView: View {
    /// Combined load progress across every feature the app warms up (0...1).
    let progress: Double
    /// Short status line under the bar (e.g. the current component being loaded).
    let status: String

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                // Logo + title
                VStack(spacing: 18) {
                    Image("DominusLogo")
                        .resizable()
                        .renderingMode(.original)
                        .scaledToFit()
                        .frame(width: 132, height: 132)

                    VStack(spacing: 8) {
                        Text("Dominus")
                            .font(.system(size: 52, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                        Text("Local AI Chatbot")
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.4))
                    }
                }

                Spacer()

                // Single combined loading bar with a pulsing white glow
                LoadingBarView(
                    label: "Loading AI",
                    status: status,
                    progress: progress
                )
                .padding(.horizontal, 40)
                .padding(.bottom, 72)
            }
        }
    }
}

// MARK: - In-use activity pill (transcribing, thinking, etc.)

struct StatusPillView: View {
    let icon: String
    let message: String
    /// Error pills drop the spinner (nothing is in progress) and tint the
    /// icon so a failure reads differently from routine activity.
    var isError: Bool = false

    var body: some View {
        HStack(spacing: 8) {
            if !isError {
                ProgressView()
                    .scaleEffect(0.72)
                    .tint(.white)
            }
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isError ? Color.yellow : Color.white.opacity(0.7))
            Text(message)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .multilineTextAlignment(.leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(
            Capsule()
                .fill(Color.black.opacity(0.72))
                .overlay(Capsule().stroke(Color.white.opacity(0.1), lineWidth: 0.5))
        )
        .shadow(color: .black.opacity(0.3), radius: 6, x: 0, y: 2)
    }
}

// MARK: - Per-component loading pill

struct LoadingBarView: View {
    let label: String
    let status: String
    let progress: Double

    /// Drives the pulsing glow on the filled portion of the bar.
    @State private var pulse = false

    private let barHeight: CGFloat = 6

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 4) {
                Text(label)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer()
                Text("\(Int((progress * 100).rounded()))%")
                    .font(.system(size: 14, weight: .regular, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.6))
                    .animation(nil, value: progress)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.10))
                        .frame(height: barHeight)

                    Capsule()
                        .fill(Color.white)
                        .frame(width: max(0, geo.size.width * progress), height: barHeight)
                        // Pulsing white glow
                        .shadow(color: .white.opacity(pulse ? 0.9 : 0.35),
                                radius: pulse ? 14 : 5)
                        .shadow(color: .white.opacity(pulse ? 0.5 : 0.15),
                                radius: pulse ? 22 : 9)
                        .opacity(pulse ? 1.0 : 0.82)
                        .animation(.linear(duration: 0.15), value: progress)
                }
            }
            .frame(height: barHeight)

            if !status.isEmpty {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.45))
                    .lineLimit(1)
            }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }
}
