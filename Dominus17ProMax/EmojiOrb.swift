import SwiftUI

/// Emoji-orb feature. A black disc with a colored outline and matching glow:
/// red while the AI is speaking, green while it's ready to listen. Pulses
/// gently while the AI talks. Inside the disc, the latest emoji from the
/// AI's reply is shown one at a time (no fade — instant swap on arrival).
///
/// Pinch the orb to resize it; the size is persisted in `AudioSettingsStore`
/// and everything (disc, stroke, glow, emoji, pulse) scales together.
///
/// Legacy `VoiceOrb` (ripple-ring style) is preserved in `VoiceOrb.swift`
/// as a safe fallback. To revert: swap `EmojiOrb(...)` back for
/// `VoiceOrb(...)` in `VoiceOrbOverlay`.
struct EmojiOrb: View {

    /// State color: typically `.red` (speaking) or `.green` (listening), wired
    /// from `ContentView.pttColor`. Drives both the stroke and the glow.
    let color:         Color
    /// Kept for API parity with the legacy orb; not used by the new visual.
    let audioLevel:    Float
    /// True while the AI is speaking — drives the pulse and brighter glow.
    let isSpeaking:    Bool
    /// Glyphs the scanner pulled out of the latest AI reply.
    let orbPlacements: [OrbEmojiScanner.Placement]
    /// Fallback glyph shown when there's no current AI-reply emoji (idle,
    /// user-talking state). When `orbPlacements` is non-empty, the latest
    /// placement wins.
    let activityGlyph: String?
    /// Size of the containing full-screen voice surface. Passed from the
    /// overlay so the orb can scale for Max-class displays without using
    /// deprecated global screen APIs.
    let availableSize: CGSize?

    @ObservedObject private var audioSettings = AudioSettingsStore.shared
    @ObservedObject private var speechMgr = SpeechManager.shared

    // Base layout. The original app used a fixed 110pt disc; on newer Max
    // displays that reads too small. Derive the baseline from the shorter
    // screen edge, then multiply by the user's persisted pinch-controlled scale.
    private var baseDiscDiameter: CGFloat {
        guard let availableSize, availableSize.width > 0, availableSize.height > 0 else {
            return 126
        }
        let shortSide = min(availableSize.width, availableSize.height)
        return min(188, max(148, shortSide * 0.40))
    }

    private var baseOuterFrame: CGFloat {
        baseDiscDiameter * 1.82
    }

    private var userScale:    CGFloat { CGFloat(audioSettings.orbScale) }
    private var outerFrame:   CGFloat { baseOuterFrame   * userScale }
    private var discDiameter: CGFloat { baseDiscDiameter * userScale }
    /// Emoji takes up most of the disc — ~84% of the disc diameter so the
    /// glyph reads cleanly even from across the room.
    private var emojiFontSize: CGFloat { discDiameter * 0.84 }

    // Pinch + idle-breath state
    @State private var pinchScale: CGFloat = 1.0   // live during a pinch
    @State private var breath: Bool = false        // toggles the ±1% idle breath

    /// Scale follows REAL audio amplitude — TTS while the AI is speaking,
    /// mic input while the user is talking. Idle: ±1% breath so the orb
    /// never looks frozen.
    private var pulseScale: CGFloat {
        if isSpeaking {
            // Up to +20% expansion on loud syllables; instant attack via
            // SpeechManager's envelope follower with moderate decay.
            return 1.0 + CGFloat(speechMgr.ttsAmplitude) * 0.20
        } else if audioLevel > 0.02 {
            // User is making sound — pulse with the mic level. Slightly
            // softer ceiling so a loud word doesn't overshoot the orb.
            return 1.0 + CGFloat(audioLevel) * 0.16
        } else {
            return breath ? 1.012 : 0.988
        }
    }

    /// Live audio source feeding the halftone wave. TTS amplitude while
    /// the AI is speaking, mic level otherwise — so the wave breathes
    /// with the conversation regardless of who's talking.
    private var liveAmplitude: Float {
        isSpeaking ? speechMgr.ttsAmplitude : audioLevel
    }

    // Diameter of the disc + stroke AT THE CURRENT PULSE. Only this expands
    // and contracts with the audio amplitude — emoji size, dot grid, and
    // dot density all stay constant.
    private var pulsedDiameter: CGFloat { discDiameter * pulseScale }

    // The halftone canvas is held a bit larger than the disc so that, when
    // the pulse expands the visible circle outward, there's already a
    // pre-existing dot field to reveal underneath. The mask exposes only
    // the portion inside the current pulse circle.
    private let halftoneRoom: CGFloat = 1.16   // canvas = disc × 1.16
    private var halftoneCanvas: CGFloat { discDiameter * halftoneRoom }

    var body: some View {
        ZStack {
            // 1. Black fill — sized to the current pulsed circle.
            Circle()
                .fill(Color.black)
                .frame(width: pulsedDiameter, height: pulsedDiameter)
                .animation(.easeOut(duration: 0.06), value: pulsedDiameter)

            // 2. Halftone — drawn at a fixed canvas larger than the disc,
            // then MASKED to the current pulsed circle. Emoji + dot
            // positions don't move; the mask just reveals more or less of
            // the underlying field as the pulse breathes.
            EmojiOrbContent(
                placements:    orbPlacements,
                activityGlyph: activityGlyph,
                // User-controlled coverage (slider in Audio Settings).
                // Value is the fraction of the halftone canvas the emoji
                // should fill — higher = bigger emoji.
                emojiCoverage: CGFloat(audioSettings.halftoneEmojiCoverage),
                plainFontSize: emojiFontSize,
                audioLevel:    liveAmplitude
            )
            .frame(width: halftoneCanvas, height: halftoneCanvas)
            .mask(
                Circle()
                    .frame(width: pulsedDiameter, height: pulsedDiameter)
                    .animation(.easeOut(duration: 0.06), value: pulsedDiameter)
            )
            .allowsHitTesting(false)

            // 3. Colored stroke + 3-layer glow — sized to the current pulse.
            Circle()
                .stroke(color, lineWidth: 5)
                .frame(width: pulsedDiameter, height: pulsedDiameter)
                .animation(.easeOut(duration: 0.06), value: pulsedDiameter)
                .shadow(color: color.opacity(isSpeaking ? 1.00 : 0.70),
                        radius: isSpeaking ? 14 : 8)
                .shadow(color: color.opacity(isSpeaking ? 0.80 : 0.45),
                        radius: isSpeaking ? 28 : 18)
                .shadow(color: color.opacity(isSpeaking ? 0.55 : 0.25),
                        radius: isSpeaking ? 52 : 36)
                // Color must SNAP, not interpolate — green ↔ red with no
                // amber in between.
                .transaction(value: color) { $0.animation = nil }
        }
        .frame(width: outerFrame, height: outerFrame)
        // Pinch on the orb itself to resize. `pinchScale` tracks the live
        // gesture; on end, the cumulative scale is committed to settings.
        .scaleEffect(pinchScale)
        .gesture(
            MagnificationGesture()
                .onChanged { value in pinchScale = value }
                .onEnded { value in
                    // Only commit a real pinch — ignore tiny gesture wiggles
                    // that fire during a tap-to-interrupt. Anything within
                    // ±4% of 1.0 is treated as "no change."
                    if abs(value - 1.0) > 0.04 {
                        let committed = Double(userScale) * Double(value)
                        audioSettings.setOrbScale(committed)
                    }
                    pinchScale = 1.0
                }
        )
        .onAppear { startIdleBreath() }
    }

    /// Slow ±1% breath cycle so the orb never appears completely frozen when
    /// the AI is silent. Drowned out the moment real audio amplitude takes
    /// over (the speaking branch of `pulseScale` returns instead).
    private func startIdleBreath() {
        withAnimation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true)) {
            breath = true
        }
    }
}

/// Inner orb content. When halftones are enabled, the entire disc is filled
/// with a living wave of dots — the current glyph (if any) renders as a
/// static halftone silhouette in the middle, with an outline ring of dots
/// tracing its edge, while the surrounding area pulses with the live audio
/// amplitude. When halftones are disabled, the emoji simply renders as a
/// plain glyph and the surrounding area is empty.
struct EmojiOrbContent: View {
    let placements:    [OrbEmojiScanner.Placement]
    let activityGlyph: String?
    /// Fraction of the halftone canvas the glyph should occupy (0…1).
    /// Computed by the parent so the visible emoji size stays right even
    /// when the halftone canvas is larger than the disc.
    let emojiCoverage: CGFloat
    /// Plain-text glyph font size, used only when halftones are disabled.
    let plainFontSize: CGFloat
    let audioLevel:    Float

    @ObservedObject private var audioSettings = AudioSettingsStore.shared

    /// Priority: an active **activity glyph** (🙂 user-speaking, 👀 still-there,
    /// 😴 dozing) wins over the last AI emoji. So the moment the user starts
    /// transcribing words, the smile takes over the orb. When activityGlyph
    /// is nil (AI speaking, or silent listening after AI finished), the last
    /// AI emoji remains visible until a new one displaces it.
    private var currentGlyph: String? {
        activityGlyph ?? placements.last?.glyph
    }

    var body: some View {
        if audioSettings.halftoneEnabled {
            // Halftone always renders, with or without a glyph. No glyph =
            // pure wave field; glyph present = silhouette + outline + wave.
            HalftoneEmojiView(
                glyph:         currentGlyph,
                emojiCoverage: emojiCoverage,
                color:         audioSettings.halftoneDotColor,
                density:       audioSettings.halftoneDensity,
                audioLevel:    audioLevel
            )
        } else if let glyph = currentGlyph {
            Text(glyph)
                .font(.system(size: plainFontSize))
                .minimumScaleFactor(0.6)
                .lineLimit(1)
        } else {
            Color.clear
        }
    }
}
