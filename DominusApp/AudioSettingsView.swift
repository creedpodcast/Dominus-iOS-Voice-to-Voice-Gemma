import SwiftUI
import AVFoundation

struct AudioSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var settings = AudioSettingsStore.shared

    @State private var previewPlayer: AVAudioPlayer?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    volumeSlider(
                        title: "Startup sound",
                        value: $settings.startupSoundVolume
                    )

                    Button {
                        playSound(named: "AppLoadedSoundEffect", volume: settings.startupSoundVolume)
                    } label: {
                        Label("Test Startup Sound", systemImage: "play.circle")
                    }
                } footer: {
                    Text("Plays once after the app finishes loading.")
                }

                Section {
                    volumeSlider(
                        title: "Voice mode activation",
                        value: $settings.voiceModeActivationVolume
                    )

                    Button {
                        playSound(named: "ActivateVoicetoVoice", volume: settings.voiceModeActivationVolume)
                    } label: {
                        Label("Test Activation Sound", systemImage: "mic.circle")
                    }

                    volumeSlider(
                        title: "Voice mode deactivation",
                        value: $settings.voiceModeDeactivationVolume
                    )

                    Button {
                        playSound(named: "DeactivateVoicetoVoice", volume: settings.voiceModeDeactivationVolume)
                    } label: {
                        Label("Test Deactivation Sound", systemImage: "xmark.circle")
                    }
                } footer: {
                    Text("Used when entering, exiting, or auto-exiting voice-to-voice mode.")
                }

                Section {
                    volumeSlider(
                        title: "AI voice response",
                        value: $settings.aiVoiceResponseVolume
                    )

                    Button {
                        SpeechManager.shared.stopAndClear()
                        SpeechManager.shared.enqueue("This is the current AI voice response volume.")
                    } label: {
                        Label("Test AI Voice", systemImage: "speaker.wave.2.circle")
                    }
                } footer: {
                    Text("Controls spoken AI responses, thinking fillers, and hands-free check-ins.")
                }

                Section {
                    Button(role: .destructive) {
                        settings.resetToDefaults()
                    } label: {
                        Label("Reset Audio Defaults", systemImage: "arrow.counterclockwise")
                    }
                }
            }
            .navigationTitle("Audio")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }

    private func volumeSlider(title: String, value: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                Spacer()
                Text(volumePercent(value.wrappedValue))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            Slider(value: value, in: 0...1) {
                Text(title)
            } minimumValueLabel: {
                Image(systemName: "speaker.slash")
            } maximumValueLabel: {
                Image(systemName: "speaker.wave.3")
            }
        }
    }

    private func playSound(named resourceName: String, volume: Double) {
        guard let url = Bundle.main.url(
            forResource: resourceName,
            withExtension: "wav",
            subdirectory: "SoundEffects"
        ) ?? Bundle.main.url(
            forResource: resourceName,
            withExtension: "wav"
        ) else {
            print("🔇 Preview sound not found:", resourceName)
            return
        }

        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [])
            try AVAudioSession.sharedInstance().setActive(true, options: [])

            let player = try AVAudioPlayer(contentsOf: url)
            let clampedVolume = Float(min(1.0, max(0.0, volume)))
            player.volume = clampedVolume
            player.prepareToPlay()
            player.setVolume(clampedVolume, fadeDuration: 0)
            player.play()
            previewPlayer = player
        } catch {
            print("🔇 Failed to preview sound:", error.localizedDescription)
        }
    }

    private func volumePercent(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }
}
