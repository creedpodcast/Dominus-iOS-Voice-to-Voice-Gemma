import SwiftUI

/// Full-screen orb-resizing view presented from Audio Settings. Looks and
/// behaves exactly like the real voice-mode screen — same black background,
/// same orb in the same position, same mic + X mock buttons — so the user
/// sees a true-to-life preview at any size up to the maximum (240%) without
/// the form cell's clipping. Adjust with the slider or pinch the orb itself;
/// changes commit live to `AudioSettingsStore.orbScale`. Tap **Done** to
/// return to settings.
struct OrbSizeAdjustView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var audioSettings = AudioSettingsStore.shared

    @State private var isSpeaking: Bool = false
    @State private var emojiIndex: Int = 0
    @State private var cycleTask: Task<Void, Never>?

    private let sampleEmojis: [String] = ["😄", "🤔", "👋", "🎉", "🔥"]

    private var placements: [OrbEmojiScanner.Placement] {
        let glyph = sampleEmojis[emojiIndex % sampleEmojis.count]
        return [OrbEmojiScanner.Placement(glyph: glyph, utf16Index: 0)]
    }

    var body: some View {
        ZStack {
            // Same black canvas as the real voice-mode overlay.
            Color.black.ignoresSafeArea()

            GeometryReader { proxy in
                // Center column: orb + mic/X mock buttons in the same arrangement
                // and dimensions used by VoiceOrbOverlay, so what the user sees
                // here is what they'll see in voice mode at the chosen size.
                VStack(spacing: 36) {
                    EmojiOrb(
                        color:         isSpeaking ? .red : .green,
                        audioLevel:    0,
                        isSpeaking:    isSpeaking,
                        orbPlacements: placements,
                        activityGlyph: nil,
                        availableSize: proxy.size
                    )

                    HStack(spacing: 28) {
                        mockButton(icon: "mic.fill", tint: .white)
                        mockButton(icon: "xmark",    tint: .white)
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
            }

            // Top label so it's obvious what's happening.
            VStack {
                HStack {
                    Text(isSpeaking ? "Speaking" : "Listening")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.white.opacity(0.65))
                        .padding(.top, 22)
                        .padding(.leading, 22)
                    Spacer()

                    Button("Done") { dismiss() }
                        .font(.body.weight(.semibold))
                        .foregroundColor(.white)
                        .padding(.top, 18)
                        .padding(.trailing, 22)
                }
                Spacer()
            }

            // Bottom control panel: size slider + percentage + reset button.
            VStack {
                Spacer()
                VStack(spacing: 12) {
                    HStack {
                        Text("Orb size")
                            .font(.callout.weight(.semibold))
                            .foregroundColor(.white)
                        Spacer()
                        Text("\(Int((audioSettings.orbScale * 100).rounded()))%")
                            .font(.callout.monospacedDigit())
                            .foregroundColor(.white.opacity(0.75))
                    }

                    Slider(
                        value: $audioSettings.orbScale,
                        in: AudioSettingsStore.minimumOrbScale...AudioSettingsStore.maximumOrbScale
                    ) {
                        Text("Orb size")
                    } minimumValueLabel: {
                        Image(systemName: "circle")
                            .font(.caption2)
                            .foregroundColor(.white.opacity(0.6))
                    } maximumValueLabel: {
                        Image(systemName: "circle.fill")
                            .font(.callout)
                            .foregroundColor(.white.opacity(0.85))
                    }
                    .tint(.white)

                    Button {
                        audioSettings.orbScale = 1.0
                    } label: {
                        Label("Reset to default size", systemImage: "arrow.counterclockwise")
                            .font(.footnote.weight(.medium))
                    }
                    .buttonStyle(.bordered)
                    .tint(.white)
                    .controlSize(.small)

                    Divider()
                        .overlay(Color.white.opacity(0.18))
                        .padding(.vertical, 4)

                    // Halftone controls
                    Toggle(isOn: $audioSettings.halftoneEnabled) {
                        Text("Halftone dots")
                            .font(.callout.weight(.semibold))
                            .foregroundColor(.white)
                    }
                    .tint(.white)

                    if audioSettings.halftoneEnabled {
                        ColorPicker(
                            "Dot color",
                            selection: Binding(
                                get: { audioSettings.halftoneDotColor },
                                set: { audioSettings.halftoneDotColor = $0 }
                            ),
                            supportsOpacity: false
                        )
                        .font(.callout)
                        .foregroundColor(.white)

                        HStack {
                            Text("Density")
                                .font(.callout)
                                .foregroundColor(.white)
                            Spacer()
                            Text("\(Int((audioSettings.halftoneDensity * 100).rounded()))%")
                                .font(.callout.monospacedDigit())
                                .foregroundColor(.white.opacity(0.75))
                        }

                        Slider(value: $audioSettings.halftoneDensity, in: 0...1) {
                            Text("Halftone density")
                        } minimumValueLabel: {
                            Image(systemName: "circle.grid.2x2")
                                .font(.caption2)
                                .foregroundColor(.white.opacity(0.6))
                        } maximumValueLabel: {
                            Image(systemName: "circle.grid.3x3.fill")
                                .font(.callout)
                                .foregroundColor(.white.opacity(0.85))
                        }
                        .tint(.white)

                        HStack {
                            Text("Emoji size")
                                .font(.callout)
                                .foregroundColor(.white)
                            Spacer()
                            Text("\(Int((audioSettings.halftoneEmojiCoverage * 100).rounded()))%")
                                .font(.callout.monospacedDigit())
                                .foregroundColor(.white.opacity(0.75))
                        }

                        Slider(
                            value: $audioSettings.halftoneEmojiCoverage,
                            in: AudioSettingsStore.minimumHalftoneEmojiCoverage ... AudioSettingsStore.maximumHalftoneEmojiCoverage
                        ) {
                            Text("Emoji size")
                        } minimumValueLabel: {
                            Image(systemName: "face.smiling")
                                .font(.caption2)
                                .foregroundColor(.white.opacity(0.6))
                        } maximumValueLabel: {
                            Image(systemName: "face.smiling.fill")
                                .font(.title3)
                                .foregroundColor(.white.opacity(0.85))
                        }
                        .tint(.white)
                    }
                }
                .padding(20)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color.white.opacity(0.08))
                )
                .padding(.horizontal, 20)
                .padding(.bottom, 28)
            }
        }
        .onAppear { startCycle() }
        .onDisappear { cycleTask?.cancel() }
    }

    /// Visual stand-in for the bottom-row buttons in the real overlay. Same
    /// dimensions, same styling — purely decorative here.
    @ViewBuilder
    private func mockButton(icon: String, tint: Color) -> some View {
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

    private func startCycle() {
        cycleTask?.cancel()
        cycleTask = Task { @MainActor in
            while !Task.isCancelled {
                isSpeaking = false
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                if Task.isCancelled { return }

                isSpeaking = true
                for _ in 0..<3 {
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    if Task.isCancelled { return }
                    emojiIndex = (emojiIndex + 1) % sampleEmojis.count
                }
            }
        }
    }
}
