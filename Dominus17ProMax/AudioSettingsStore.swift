import Foundation
import Combine
import SwiftUI
import UIKit

@MainActor
final class AudioSettingsStore: ObservableObject {
    static let shared = AudioSettingsStore()

    private enum Keys {
        static let startupSoundVolume = "audio.startupSoundVolume"
        static let voiceModeActivationVolume = "audio.voiceModeActivationVolume"
        static let voiceModeDeactivationVolume = "audio.voiceModeDeactivationVolume"
        static let aiVoiceResponseVolume = "audio.aiVoiceResponseVolume"
        static let voiceModeInactivityTimeout = "audio.voiceModeInactivityTimeout"
        static let hapticsEnabled = "haptics.enabled"
        static let orbScale = "orb.scale"
        static let halftoneEnabled = "halftone.enabled"
        static let halftoneDotRed   = "halftone.dotRed"
        static let halftoneDotGreen = "halftone.dotGreen"
        static let halftoneDotBlue  = "halftone.dotBlue"
        static let halftoneDensity  = "halftone.density"
        static let halftoneEmojiCoverage = "halftone.emojiCoverage"
        static let selectedVoiceIdentifier = "speech.selectedVoiceIdentifier"
        static let speechRate = "speech.rate"
        static let speechPitch = "speech.pitch"
    }

    private enum Defaults {
        static let startupSoundVolume = 0.10
        static let voiceModeActivationVolume = 0.35
        static let voiceModeDeactivationVolume = 0.35
        static let aiVoiceResponseVolume = 1.0
        static let voiceModeInactivityTimeout = 60.0
        static let hapticsEnabled = true
        static let orbScale = 1.0
        static let halftoneEnabled = true
        // Default dot color: pure white (clean halftone over any emoji).
        static let halftoneDotRed:   Double = 1.0
        static let halftoneDotGreen: Double = 1.0
        static let halftoneDotBlue:  Double = 1.0
        // Default density: medium grid (about 22 dots per side).
        static let halftoneDensity:  Double = 0.36
        // Default coverage: matches the visible disc size used pre-bug
        // (0.72 of disc / 1.30 of halftone canvas ≈ 0.55).
        static let halftoneEmojiCoverage: Double = 0.55
        // 0.52 ≈ slightly faster than Apple's 0.5 default — most users want a touch
        // more pace than the OS default, and this matches what feels natural with
        // Premium voices on iPhone.
        // 0.55 is noticeably brisker than Apple's 0.5 default — closer to how a
        // person talks in a casual conversation. The slider can push it higher if
        // the user wants it faster still.
        static let speechRate: Double = 0.55
        // 1.05 brightens the voice just enough to fix the "all voices sound deep"
        // complaint without making them sound artificial.
        static let speechPitch: Double = 1.05
    }

    // Apple's documented bounds for AVSpeechUtterance.
    // We expose 0.30…0.70 to the user; the full 0.0…1.0 range includes
    // "almost stopped" and "unintelligibly fast" which nobody actually wants.
    static let minimumSpeechRate: Double = 0.35
    static let maximumSpeechRate: Double = 0.80
    static let minimumSpeechPitch: Double = 0.75
    static let maximumSpeechPitch: Double = 1.50

    static let minimumHalftoneEmojiCoverage: Double = 0.30
    static let maximumHalftoneEmojiCoverage: Double = 0.90

    static let minimumVoiceModeInactivityTimeout = 30.0
    static let maximumVoiceModeInactivityTimeout = 15.0 * 60.0
    static let voiceModeInactivityTimeoutStep = 30.0
    static let minimumOrbScale = 0.6
    static let maximumOrbScale = 2.4

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

    @Published var voiceModeInactivityTimeout: Double {
        didSet {
            save(
                clampTimeout(voiceModeInactivityTimeout),
                forKey: Keys.voiceModeInactivityTimeout
            )
        }
    }

    /// Whether the app fires haptic feedback on send and when the AI starts responding.
    /// Defaults to on. User can toggle in Audio settings.
    @Published var hapticsEnabled: Bool {
        didSet { defaults.set(hapticsEnabled, forKey: Keys.hapticsEnabled) }
    }

    /// User-controlled size multiplier for the voice-mode orb. 1.0 = default
    /// size; range [0.6, 2.4]. Adjusted by pinch-to-zoom on the orb itself.
    @Published var orbScale: Double {
        didSet { save(clampOrbScale(orbScale), forKey: Keys.orbScale) }
    }

    /// Toggle for the halftone-dot pattern overlaid on the emoji inside the
    /// orb. When off, the emoji is shown as plain text glyph.
    @Published var halftoneEnabled: Bool {
        didSet { defaults.set(halftoneEnabled, forKey: Keys.halftoneEnabled) }
    }

    /// SwiftUI `Color` for the halftone dots. Backed by three doubles in
    /// UserDefaults; `Color(red:green:blue:)` reconstructs the live value.
    @Published var halftoneDotRed: Double {
        didSet { defaults.set(halftoneDotRed,   forKey: Keys.halftoneDotRed) }
    }
    @Published var halftoneDotGreen: Double {
        didSet { defaults.set(halftoneDotGreen, forKey: Keys.halftoneDotGreen) }
    }
    @Published var halftoneDotBlue: Double {
        didSet { defaults.set(halftoneDotBlue,  forKey: Keys.halftoneDotBlue) }
    }

    /// Dots per side scale. 0 ≈ sparse 12-per-side, 1 ≈ dense 40-per-side.
    @Published var halftoneDensity: Double {
        didSet { defaults.set(clampUnit(halftoneDensity), forKey: Keys.halftoneDensity) }
    }

    /// Fraction of the halftone canvas the emoji glyph should occupy. Higher
    /// = bigger emoji. Lower = smaller emoji with more breathing room.
    @Published var halftoneEmojiCoverage: Double {
        didSet { defaults.set(clampEmojiCoverage(halftoneEmojiCoverage), forKey: Keys.halftoneEmojiCoverage) }
    }

    /// Stable identifier for the user-chosen `AVSpeechSynthesisVoice`. nil = auto-pick.
    /// SpeechManager reads this on init and after every change; if the identifier no
    /// longer resolves (user uninstalled the voice in iOS Settings), the fallback
    /// male-English picker takes over automatically.
    /// AVSpeechUtterance.rate — perceived speed. Clamped to the public range.
    @Published var speechRate: Double {
        didSet { save(clampSpeechRate(speechRate), forKey: Keys.speechRate) }
    }

    /// AVSpeechUtterance.pitchMultiplier — 1.0 = neutral, >1 brighter, <1 deeper.
    @Published var speechPitch: Double {
        didSet { save(clampSpeechPitch(speechPitch), forKey: Keys.speechPitch) }
    }

    @Published var selectedVoiceIdentifier: String? {
        didSet {
            if let id = selectedVoiceIdentifier {
                defaults.set(id, forKey: Keys.selectedVoiceIdentifier)
            } else {
                defaults.removeObject(forKey: Keys.selectedVoiceIdentifier)
            }
        }
    }

    /// Convenience getter / setter so the UI can bind to a single `Color`.
    var halftoneDotColor: Color {
        get { Color(red: halftoneDotRed, green: halftoneDotGreen, blue: halftoneDotBlue) }
        set {
            let comps = newValue.uiRGBComponents
            halftoneDotRed   = comps.r
            halftoneDotGreen = comps.g
            halftoneDotBlue  = comps.b
        }
    }

    private let defaults: UserDefaults

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        startupSoundVolume = Self.load(Keys.startupSoundVolume, fallback: Defaults.startupSoundVolume, defaults: defaults)
        voiceModeActivationVolume = Self.load(Keys.voiceModeActivationVolume, fallback: Defaults.voiceModeActivationVolume, defaults: defaults)
        voiceModeDeactivationVolume = Self.load(Keys.voiceModeDeactivationVolume, fallback: Defaults.voiceModeDeactivationVolume, defaults: defaults)
        aiVoiceResponseVolume = Self.load(Keys.aiVoiceResponseVolume, fallback: Defaults.aiVoiceResponseVolume, defaults: defaults)
        voiceModeInactivityTimeout = Self.loadTimeout(Keys.voiceModeInactivityTimeout, fallback: Defaults.voiceModeInactivityTimeout, defaults: defaults)
        hapticsEnabled = defaults.object(forKey: Keys.hapticsEnabled) != nil
            ? defaults.bool(forKey: Keys.hapticsEnabled)
            : Defaults.hapticsEnabled
        orbScale = Self.loadOrbScale(Keys.orbScale, fallback: Defaults.orbScale, defaults: defaults)
        halftoneEnabled = defaults.object(forKey: Keys.halftoneEnabled) != nil
            ? defaults.bool(forKey: Keys.halftoneEnabled)
            : Defaults.halftoneEnabled
        halftoneDotRed   = Self.loadDouble(Keys.halftoneDotRed,   fallback: Defaults.halftoneDotRed,   defaults: defaults)
        halftoneDotGreen = Self.loadDouble(Keys.halftoneDotGreen, fallback: Defaults.halftoneDotGreen, defaults: defaults)
        halftoneDotBlue  = Self.loadDouble(Keys.halftoneDotBlue,  fallback: Defaults.halftoneDotBlue,  defaults: defaults)
        halftoneDensity  = Self.loadUnit(Keys.halftoneDensity,    fallback: Defaults.halftoneDensity,  defaults: defaults)
        halftoneEmojiCoverage = Self.loadEmojiCoverage(Keys.halftoneEmojiCoverage,
                                                       fallback: Defaults.halftoneEmojiCoverage,
                                                       defaults: defaults)
        selectedVoiceIdentifier = defaults.string(forKey: Keys.selectedVoiceIdentifier)
        speechRate = Self.loadSpeechRate(defaults: defaults)
        speechPitch = Self.loadSpeechPitch(defaults: defaults)
    }

    /// Apply a pinch-to-zoom delta to the orb scale, clamped to the allowed
    /// range. Called from the orb's pinch gesture.
    func setOrbScale(_ value: Double) {
        orbScale = Self.clampOrbScale(value)
    }

    func resetToDefaults() {
        startupSoundVolume = Defaults.startupSoundVolume
        voiceModeActivationVolume = Defaults.voiceModeActivationVolume
        voiceModeDeactivationVolume = Defaults.voiceModeDeactivationVolume
        aiVoiceResponseVolume = Defaults.aiVoiceResponseVolume
        voiceModeInactivityTimeout = Defaults.voiceModeInactivityTimeout
        hapticsEnabled = Defaults.hapticsEnabled
        orbScale = Defaults.orbScale
        halftoneEnabled  = Defaults.halftoneEnabled
        halftoneDotRed   = Defaults.halftoneDotRed
        halftoneDotGreen = Defaults.halftoneDotGreen
        halftoneDotBlue  = Defaults.halftoneDotBlue
        halftoneDensity  = Defaults.halftoneDensity
        halftoneEmojiCoverage = Defaults.halftoneEmojiCoverage
        selectedVoiceIdentifier = nil
        speechRate = Defaults.speechRate
        speechPitch = Defaults.speechPitch
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

    private static func loadTimeout(_ key: String, fallback: Double, defaults: UserDefaults) -> Double {
        guard defaults.object(forKey: key) != nil else { return fallback }
        return clampTimeout(defaults.double(forKey: key))
    }

    private static func clamp(_ value: Double) -> Double {
        min(1.0, max(0.0, value))
    }

    private static func clampTimeout(_ value: Double) -> Double {
        let stepped = (value / voiceModeInactivityTimeoutStep).rounded() * voiceModeInactivityTimeoutStep
        return min(maximumVoiceModeInactivityTimeout, max(minimumVoiceModeInactivityTimeout, stepped))
    }

    private func clamp(_ value: Double) -> Double {
        Self.clamp(value)
    }

    private func clampTimeout(_ value: Double) -> Double {
        Self.clampTimeout(value)
    }

    private static func clampOrbScale(_ value: Double) -> Double {
        min(maximumOrbScale, max(minimumOrbScale, value))
    }

    private func clampOrbScale(_ value: Double) -> Double {
        Self.clampOrbScale(value)
    }

    private static func loadOrbScale(_ key: String, fallback: Double, defaults: UserDefaults) -> Double {
        guard defaults.object(forKey: key) != nil else { return fallback }
        return clampOrbScale(defaults.double(forKey: key))
    }

    private static func loadDouble(_ key: String, fallback: Double, defaults: UserDefaults) -> Double {
        guard defaults.object(forKey: key) != nil else { return fallback }
        return defaults.double(forKey: key)
    }

    private static func loadUnit(_ key: String, fallback: Double, defaults: UserDefaults) -> Double {
        guard defaults.object(forKey: key) != nil else { return fallback }
        return clampUnit(defaults.double(forKey: key))
    }

    private static func clampUnit(_ v: Double) -> Double { min(1, max(0, v)) }
    private func clampUnit(_ v: Double) -> Double { Self.clampUnit(v) }

    private static func clampEmojiCoverage(_ v: Double) -> Double {
        min(maximumHalftoneEmojiCoverage, max(minimumHalftoneEmojiCoverage, v))
    }
    private func clampEmojiCoverage(_ v: Double) -> Double { Self.clampEmojiCoverage(v) }

    private static func loadEmojiCoverage(_ key: String, fallback: Double, defaults: UserDefaults) -> Double {
        guard defaults.object(forKey: key) != nil else { return fallback }
        return clampEmojiCoverage(defaults.double(forKey: key))
    }

    private static func clampSpeechRate(_ v: Double) -> Double {
        min(maximumSpeechRate, max(minimumSpeechRate, v))
    }
    private func clampSpeechRate(_ v: Double) -> Double { Self.clampSpeechRate(v) }

    private static func clampSpeechPitch(_ v: Double) -> Double {
        min(maximumSpeechPitch, max(minimumSpeechPitch, v))
    }
    private func clampSpeechPitch(_ v: Double) -> Double { Self.clampSpeechPitch(v) }

    private static func loadSpeechRate(defaults: UserDefaults) -> Double {
        guard defaults.object(forKey: Keys.speechRate) != nil else { return Defaults.speechRate }
        return clampSpeechRate(defaults.double(forKey: Keys.speechRate))
    }

    private static func loadSpeechPitch(defaults: UserDefaults) -> Double {
        guard defaults.object(forKey: Keys.speechPitch) != nil else { return Defaults.speechPitch }
        return clampSpeechPitch(defaults.double(forKey: Keys.speechPitch))
    }
}

// MARK: - Color → RGB component bridge

extension Color {
    /// Pulls the RGB components out via UIColor so we can persist them as
    /// three doubles. Falls back to opaque white if extraction fails.
    var uiRGBComponents: (r: Double, g: Double, b: Double) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(self).getRed(&r, green: &g, blue: &b, alpha: &a)
        return (Double(r), Double(g), Double(b))
    }
}
