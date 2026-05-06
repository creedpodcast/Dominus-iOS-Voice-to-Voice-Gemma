import Foundation
import Combine

@MainActor
final class AudioSettingsStore: ObservableObject {
    static let shared = AudioSettingsStore()

    private enum Keys {
        static let startupSoundVolume = "audio.startupSoundVolume"
        static let voiceModeActivationVolume = "audio.voiceModeActivationVolume"
        static let voiceModeDeactivationVolume = "audio.voiceModeDeactivationVolume"
        static let aiVoiceResponseVolume = "audio.aiVoiceResponseVolume"
    }

    private enum Defaults {
        static let startupSoundVolume = 0.10
        static let voiceModeActivationVolume = 0.35
        static let voiceModeDeactivationVolume = 0.35
        static let aiVoiceResponseVolume = 1.0
    }

    @Published var startupSoundVolume: Double {
        didSet { save(clamp(startupSoundVolume), forKey: Keys.startupSoundVolume) }
    }

    @Published var voiceModeActivationVolume: Double {
        didSet { save(clamp(voiceModeActivationVolume), forKey: Keys.voiceModeActivationVolume) }
    }

    @Published var voiceModeDeactivationVolume: Double {
        didSet { save(clamp(voiceModeDeactivationVolume), forKey: Keys.voiceModeDeactivationVolume) }
    }

    @Published var aiVoiceResponseVolume: Double {
        didSet { save(clamp(aiVoiceResponseVolume), forKey: Keys.aiVoiceResponseVolume) }
    }

    private let defaults: UserDefaults

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        startupSoundVolume = Self.load(Keys.startupSoundVolume, fallback: Defaults.startupSoundVolume, defaults: defaults)
        voiceModeActivationVolume = Self.load(Keys.voiceModeActivationVolume, fallback: Defaults.voiceModeActivationVolume, defaults: defaults)
        voiceModeDeactivationVolume = Self.load(Keys.voiceModeDeactivationVolume, fallback: Defaults.voiceModeDeactivationVolume, defaults: defaults)
        aiVoiceResponseVolume = Self.load(Keys.aiVoiceResponseVolume, fallback: Defaults.aiVoiceResponseVolume, defaults: defaults)
    }

    func resetToDefaults() {
        startupSoundVolume = Defaults.startupSoundVolume
        voiceModeActivationVolume = Defaults.voiceModeActivationVolume
        voiceModeDeactivationVolume = Defaults.voiceModeDeactivationVolume
        aiVoiceResponseVolume = Defaults.aiVoiceResponseVolume
    }

    func voiceModeVolume(for resourceName: String) -> Double {
        switch resourceName {
        case "ActivateVoicetoVoice":
            return voiceModeActivationVolume
        case "DeactivateVoicetoVoice":
            return voiceModeDeactivationVolume
        default:
            return max(voiceModeActivationVolume, voiceModeDeactivationVolume)
        }
    }

    private func save(_ value: Double, forKey key: String) {
        defaults.set(value, forKey: key)
    }

    private static func load(_ key: String, fallback: Double, defaults: UserDefaults) -> Double {
        guard defaults.object(forKey: key) != nil else { return fallback }
        return clamp(defaults.double(forKey: key))
    }

    private static func clamp(_ value: Double) -> Double {
        min(1.0, max(0.0, value))
    }

    private func clamp(_ value: Double) -> Double {
        Self.clamp(value)
    }
}
