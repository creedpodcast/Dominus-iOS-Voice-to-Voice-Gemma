import SwiftUI
import AVFoundation
import UIKit

struct AudioSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var settings = AudioSettingsStore.shared

    @State private var previewPlayer: AVAudioPlayer?
    @State private var showOrbSizeAdjuster: Bool = false

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
                    NavigationLink {
                        VoicePickerScreen()
                    } label: {
                        HStack {
                            Label("AI voice", systemImage: "person.wave.2")
                            Spacer()
                            Text(currentVoiceDisplayName())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                } footer: {
                    Text("Open to browse every English voice installed on this device, preview, and adjust speed and pitch.")
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
                    Stepper(
                        value: $settings.voiceModeInactivityTimeout,
                        in: AudioSettingsStore.minimumVoiceModeInactivityTimeout...AudioSettingsStore.maximumVoiceModeInactivityTimeout,
                        step: AudioSettingsStore.voiceModeInactivityTimeoutStep
                    ) {
                        HStack {
                            Text("Voice inactivity timeout")
                            Spacer()
                            Text(durationText(settings.voiceModeInactivityTimeout))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }

                    Slider(
                        value: $settings.voiceModeInactivityTimeout,
                        in: AudioSettingsStore.minimumVoiceModeInactivityTimeout...AudioSettingsStore.maximumVoiceModeInactivityTimeout,
                        step: AudioSettingsStore.voiceModeInactivityTimeoutStep
                    ) {
                        Text("Voice inactivity timeout")
                    } minimumValueLabel: {
                        Text("30s")
                            .font(.caption2)
                    } maximumValueLabel: {
                        Text("15m")
                            .font(.caption2)
                    }
                } footer: {
                    Text("Voice mode exits after this much user inactivity while Dominus is listening. Time spent generating or speaking does not count against the timer.")
                }

                Section {
                    Button {
                        showOrbSizeAdjuster = true
                    } label: {
                        HStack {
                            Label("Adjust orb size", systemImage: "circle.dashed")
                            Spacer()
                            Text("\(Int((settings.orbScale * 100).rounded()))%")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                } header: {
                    Text("Voice orb")
                } footer: {
                    Text("Opens a full-screen preview that looks exactly like voice mode. Drag the slider or pinch the orb to resize — your change applies the moment you tap Done. You can also pinch the orb directly in voice mode to resize at any time.")
                }

                Section {
                    Toggle(isOn: $settings.hapticsEnabled) {
                        Label("Haptic feedback", systemImage: "hand.tap")
                    }
                } footer: {
                    Text("Subtle tap when you send a message and when Dominus starts responding.")
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
            .fullScreenCover(isPresented: $showOrbSizeAdjuster) {
                OrbSizeAdjustView()
            }
        }
    }

    private func currentVoiceDisplayName() -> String {
        if let id = settings.selectedVoiceIdentifier,
           let v = AVSpeechSynthesisVoice(identifier: id) {
            return v.name
        }
        return "Auto"
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

    private func durationText(_ value: Double) -> String {
        let seconds = Int(value.rounded())
        if seconds < 60 {
            return "\(seconds) sec"
        }
        let minutes = seconds / 60
        let remainder = seconds % 60
        if remainder == 0 {
            return "\(minutes) min"
        }
        return "\(minutes)m \(remainder)s"
    }
}

// MARK: - Voice picker screen

/// Dedicated full-screen voice picker. Pushed via `NavigationLink` from the
/// audio settings root. Uses `List` (not `Form`) so the long voice catalog
/// scrolls naturally on devices with many downloaded Premium voices.
struct VoicePickerScreen: View {
    @ObservedObject private var settings = AudioSettingsStore.shared
    @State private var installedEnglishVoices: [AVSpeechSynthesisVoice] = []

    private struct VoiceGroup {
        let title: String
        let voices: [AVSpeechSynthesisVoice]
    }

    var body: some View {
        List {
            // Speed + pitch sit at the top of the screen so users adjusting
            // a too-deep-sounding voice can fix it without scrolling away from
            // the voice they just picked.
            Section {
                rateSlider()
                pitchSlider()

                Button {
                    SpeechManager.shared.stopAndClear()
                    SpeechManager.shared.enqueue("Hello, I'm Dominus. This is how I sound right now.")
                } label: {
                    Label("Preview current voice", systemImage: "play.circle")
                }

                Button(role: .destructive) {
                    settings.speechRate = 0.55
                    settings.speechPitch = 1.05
                } label: {
                    Label("Reset speed & pitch", systemImage: "arrow.counterclockwise")
                }
            } header: {
                Text("Speed & pitch")
            } footer: {
                Text("Speed and pitch apply to whichever voice you pick below. If a voice still sounds too deep at neutral pitch, try a different voice — Apple's Premium voices vary a lot in baseline tone.")
            }

            Section {
                autoVoiceRow()
            } header: {
                Text("Voice selection")
            } footer: {
                Text("Don't see the voice you want? Open iOS Settings → Accessibility → Spoken Content → Voices → English to download more — they'll appear here automatically.")
            }

            ForEach(groupedVoices(), id: \.title) { group in
                Section(group.title) {
                    ForEach(group.voices, id: \.identifier) { voice in
                        voiceRow(voice)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("AI Voice")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { reloadInstalledVoices() }
        .onReceive(
            NotificationCenter.default.publisher(
                for: UIApplication.willEnterForegroundNotification
            )
        ) { _ in reloadInstalledVoices() }
    }

    // MARK: - Rows

    private func autoVoiceRow() -> some View {
        let isSelected = settings.selectedVoiceIdentifier == nil
        return HStack {
            Label("Auto (recommended)", systemImage: "wand.and.stars")
            Spacer()
            if isSelected {
                Image(systemName: "checkmark").foregroundStyle(.tint)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            settings.selectedVoiceIdentifier = nil
            SpeechManager.shared.refreshPreferredVoice()
        }
    }

    private func voiceRow(_ voice: AVSpeechSynthesisVoice) -> some View {
        let isSelected = settings.selectedVoiceIdentifier == voice.identifier
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(voice.name)
                    .font(.body)
                Text(voiceSubtitle(voice))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                preview(voice)
            } label: {
                Image(systemName: "play.circle")
                    .imageScale(.large)
            }
            .buttonStyle(.borderless)
            if isSelected {
                Image(systemName: "checkmark").foregroundStyle(.tint)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            settings.selectedVoiceIdentifier = voice.identifier
            SpeechManager.shared.refreshPreferredVoice()
        }
    }

    // MARK: - Sliders

    private func rateSlider() -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Speed")
                Spacer()
                Text(ratePercent(settings.speechRate))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(
                value: $settings.speechRate,
                in: AudioSettingsStore.minimumSpeechRate...AudioSettingsStore.maximumSpeechRate
            ) {
                Text("Speed")
            } minimumValueLabel: {
                Image(systemName: "tortoise")
            } maximumValueLabel: {
                Image(systemName: "hare")
            }
        }
    }

    private func pitchSlider() -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Pitch")
                Spacer()
                Text(pitchLabel(settings.speechPitch))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(
                value: $settings.speechPitch,
                in: AudioSettingsStore.minimumSpeechPitch...AudioSettingsStore.maximumSpeechPitch
            ) {
                Text("Pitch")
            } minimumValueLabel: {
                Image(systemName: "arrow.down")
            } maximumValueLabel: {
                Image(systemName: "arrow.up")
            }
        }
    }

    // MARK: - Helpers

    private func reloadInstalledVoices() {
        installedEnglishVoices = AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("en") }
            .sorted { lhs, rhs in
                if lhs.quality.rawValue != rhs.quality.rawValue {
                    return lhs.quality.rawValue > rhs.quality.rawValue
                }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }

    private func groupedVoices() -> [VoiceGroup] {
        var groups: [VoiceGroup] = []
        let premium  = installedEnglishVoices.filter { $0.quality == .premium }
        let enhanced = installedEnglishVoices.filter { $0.quality == .enhanced }
        let standard = installedEnglishVoices.filter { $0.quality == .default }
        if !premium.isEmpty  { groups.append(.init(title: "Premium (Siri-quality)", voices: premium)) }
        if !enhanced.isEmpty { groups.append(.init(title: "Enhanced", voices: enhanced)) }
        if !standard.isEmpty { groups.append(.init(title: "Standard", voices: standard)) }
        return groups
    }

    private func voiceSubtitle(_ voice: AVSpeechSynthesisVoice) -> String {
        Locale.current.localizedString(forIdentifier: voice.language) ?? voice.language
    }

    private func preview(_ voice: AVSpeechSynthesisVoice) {
        settings.selectedVoiceIdentifier = voice.identifier
        SpeechManager.shared.refreshPreferredVoice()
        SpeechManager.shared.stopAndClear()
        SpeechManager.shared.enqueue("Hello, I'm Dominus.")
    }

    private func ratePercent(_ rate: Double) -> String {
        let lo = AudioSettingsStore.minimumSpeechRate
        let hi = AudioSettingsStore.maximumSpeechRate
        let pct = (rate - lo) / (hi - lo)
        return "\(Int((pct * 100).rounded()))%"
    }

    private func pitchLabel(_ pitch: Double) -> String {
        String(format: "%.2f×", pitch)
    }
}

