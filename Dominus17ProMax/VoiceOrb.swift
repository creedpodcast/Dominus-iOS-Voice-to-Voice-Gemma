import SwiftUI

/// Full-screen voice orb overlay shown during PTT voice sessions.
/// Three ripple rings expand outward like sonar pings.
/// The solid core scales with live microphone amplitude.
/// Tap the orb to advance the PTT state.
/// Buttons below: mic mute (kill mic input so stray speech isn't transcribed),
/// stop (kill current AI response, stay in voice mode),
/// X (exit voice mode entirely).
struct VoiceOrbOverlay: View {

    let orbColor:      Color
    let audioLevel:    Float
    let status:        (icon: String, message: String, isError: Bool)?
    let isMicMuted:    Bool
    let isGenerating:  Bool   // kept for API parity; the stop button has been removed
    let isSpeaking:    Bool   // drives the orb's pulse + glow while the AI is talking
    let orbPlacements: [OrbEmojiScanner.Placement]
    let activityGlyph: String?   // idle / user-talking face fallback
    let onTap:         () -> Void
    let onToggleMicMute: () -> Void
    let onStop:        () -> Void   // still wired through `onTap` when AI is speaking
    let onDismiss:     () -> Void

    var body: some View {
        ZStack {
            // Full focus background — tapping it acts the same as tapping the orb.
            Color.black
                .ignoresSafeArea()
                .onTapGesture { onTap() }

            VStack {
                if let status {
                    StatusPillView(icon: status.icon, message: status.message, isError: status.isError)
                        .padding(.top, 22)
                        .padding(.horizontal, 24)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                Spacer()
            }
            .animation(.easeInOut(duration: 0.25), value: status?.message)
            .allowsHitTesting(false)

            GeometryReader { proxy in
                VStack(spacing: 36) {
                    // Emoji-orb feature: render the new `EmojiOrb` (in EmojiOrb.swift)
                    // which adds an emoji glyph layer on top of the same ripple +
                    // core visuals. To revert to the original orb, swap the
                    // `EmojiOrb(...)` call below for `VoiceOrb(color: orbColor,
                    // audioLevel: audioLevel)` — the old struct is preserved
                    // intact at the bottom of this file.
                    EmojiOrb(
                        color: orbColor,
                        audioLevel: audioLevel,
                        isSpeaking: isSpeaking,
                        orbPlacements: orbPlacements,
                        activityGlyph: activityGlyph,
                        availableSize: proxy.size
                    )
                        .onTapGesture { onTap() }

                    // Bottom button row: mic mute + exit only. The orange stop
                    // button has been removed — tapping the orb while the AI is
                    // speaking now interrupts it (handled by the existing PTT
                    // state machine in ContentView).
                    HStack(spacing: 28) {
                        circleButton(
                            icon: isMicMuted ? "mic.slash.fill" : "mic.fill",
                            tint: isMicMuted ? .red.opacity(0.85) : .white,
                            action: onToggleMicMute
                        )

                        circleButton(
                            icon: "xmark",
                            tint: .white,
                            action: onDismiss
                        )
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
            }
        }
        .transition(
            .asymmetric(
                insertion:  .opacity.combined(with: .scale(scale: 0.85)),
                removal:    .opacity.combined(with: .scale(scale: 1.1))
            )
        )
    }

    @ViewBuilder
    private func circleButton(icon: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(Color.white.opacity(0.12))
                    .frame(width: 52, height: 52)
                Circle()
                    .stroke(Color.white.opacity(0.25), lineWidth: 1)
                    .frame(width: 52, height: 52)
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(tint)
            }
        }
        .buttonStyle(.plain)
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
        .onChange(of: color) { _, _ in restartRipples() }
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
