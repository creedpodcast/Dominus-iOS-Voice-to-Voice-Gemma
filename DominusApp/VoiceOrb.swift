import SwiftUI

/// Full-screen voice orb overlay shown during PTT voice sessions.
/// Three ripple rings expand outward like sonar pings.
/// The solid core scales with live microphone amplitude.
struct VoiceOrbOverlay: View {

    let orbColor: Color
    let audioLevel: Float
    let onTap: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.55)
                .ignoresSafeArea()
                .onTapGesture { onTap() }

            VoiceOrb(color: orbColor, audioLevel: audioLevel)
                .onTapGesture { onTap() }
        }
        .transition(
            .asymmetric(
                insertion:  .opacity.combined(with: .scale(scale: 0.85)),
                removal:    .opacity.combined(with: .scale(scale: 1.1))
            )
        )
    }
}

// MARK: - Orb

struct VoiceOrb: View {

    let color:      Color
    let audioLevel: Float

    @State private var r1Scale:   CGFloat = 1.0
    @State private var r1Opacity: Double  = 0.55
    @State private var r2Scale:   CGFloat = 1.0
    @State private var r2Opacity: Double  = 0.40
    @State private var r3Scale:   CGFloat = 1.0
    @State private var r3Opacity: Double  = 0.25

    private var coreScale: CGFloat {
        1.0 + CGFloat(audioLevel) * 0.35
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(color.opacity(r3Opacity), lineWidth: 1.5)
                .frame(width: 200, height: 200)
                .scaleEffect(r3Scale)

            Circle()
                .stroke(color.opacity(r2Opacity), lineWidth: 2)
                .frame(width: 155, height: 155)
                .scaleEffect(r2Scale)

            Circle()
                .stroke(color.opacity(r1Opacity), lineWidth: 2.5)
                .frame(width: 110, height: 110)
                .scaleEffect(r1Scale)

            Circle()
                .fill(
                    RadialGradient(
                        colors: [color.opacity(0.95), color.opacity(0.50)],
                        center:      .center,
                        startRadius: 0,
                        endRadius:   45
                    )
                )
                .frame(width: 90, height: 90)
                .scaleEffect(coreScale)
                .shadow(color: color.opacity(0.6), radius: 20, x: 0, y: 0)
                .animation(.easeOut(duration: 0.08), value: audioLevel)
        }
        .onAppear { startRipples() }
        .onChange(of: color) { _ in restartRipples() }
    }

    private func startRipples() {
        withAnimation(.easeOut(duration: 1.3).repeatForever(autoreverses: false)) {
            r1Scale = 1.75; r1Opacity = 0
        }
        withAnimation(.easeOut(duration: 1.7).repeatForever(autoreverses: false).delay(0.35)) {
            r2Scale = 1.8; r2Opacity = 0
        }
        withAnimation(.easeOut(duration: 2.1).repeatForever(autoreverses: false).delay(0.70)) {
            r3Scale = 1.85; r3Opacity = 0
        }
    }

    private func restartRipples() {
        r1Scale = 1.0; r1Opacity = 0.55
        r2Scale = 1.0; r2Opacity = 0.40
        r3Scale = 1.0; r3Opacity = 0.25
        startRipples()
    }
}
