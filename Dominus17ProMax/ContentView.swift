import SwiftUI
import AVFoundation
import UIKit

// MARK: - PTT State

private enum PTTState {
    case idle       // ready — tap to speak
    case listening  // recording user speech — tap when done
    case aiTalking  // AI generating / speaking — tap to interrupt
}

private enum HeadphoneVolumeWarning: Equatable {
    case high
    case low

    var icon: String {
        switch self {
        case .high: return "speaker.wave.3.fill"
        case .low:  return "speaker.slash.fill"
        }
    }

    var message: String {
        switch self {
        case .high: return "Listening volume is high"
        case .low:  return "Listening volume is very low"
        }
    }
}

struct ContentView: View {

    @StateObject private var store   = ChatStore()
    @StateObject private var whisper = WhisperManager.shared
    @ObservedObject private var speechMgr = SpeechManager.shared
    @ObservedObject private var audioSettings = AudioSettingsStore.shared

    @Environment(\.scenePhase) private var scenePhase

    @State private var prompt: String = ""
    /// Debounced task that pre-fetches RAG memories while the user is typing.
    @State private var speculativeRetrievalTask: Task<Void, Never>?
    /// Debounced voice equivalent of speculative RAG. It lets a stable live
    /// transcript warm the current-chat recall path before auto-send fires.
    @State private var voiceSpeculativeRetrievalTask: Task<Void, Never>?
    /// Flips true only after every cold component (LLM inference graph, TTS voice file,
    /// Whisper transcription graph) has been pre-warmed. Splash stays up until then so
    /// "ready" actually means ready — no first-turn stalls, no manual-tap-to-send race.
    @State private var isWarmedUp: Bool = false
    @State private var warmPipelineRefreshTask: Task<Void, Never>?
    @State private var showContextInspector: Bool = false

    // Rename sheet state
    @State private var showingRenameAlert = false
    @State private var renameConvoID: UUID?
    @State private var renameText: String = ""

    // Context hint banner
    @State private var showContextHint: Bool = false
    @State private var hasShownContextHint: Bool = false

    // Profile sheet
    @State private var showProfileSheet = false
    @State private var showAudioSettingsSheet = false

    // Push-to-talk state
    @State private var pttState: PTTState = .idle

    // Pulse animation for the recording ring
    @State private var pulseScale: CGFloat = 1.0
    @State private var pulseOpacity: Double = 0.6

    // Remember whether voice was on before PTT so we can restore it
    @State private var voiceWasEnabled: Bool = false
    @State private var voiceAutoSendTask: Task<Void, Never>?
    @State private var listeningSilenceFillerTask: Task<Void, Never>?
    @State private var voiceModeAutoExitTask: Task<Void, Never>?
    /// Timer that, 3 seconds after the AI stops speaking, drops the orb into
    /// its idle 🙂 face if the user hasn't started talking yet.
    @State private var idleOrbEmojiTask: Task<Void, Never>?
    /// Marks the entry/return greeting so its post-speech handler can show
    /// the 🙂 face for ~5 seconds before clearing back to the dot field.
    @State private var entryGreetingActive: Bool = false
    /// Timer that clears the 5-second entry smile once it has shown long
    /// enough (and the user hasn't started speaking).
    @State private var entrySmileClearTask: Task<Void, Never>?
    /// Timer that clears the AI's last emoji 10 seconds after the AI
    /// finishes speaking. Cancelled when a new reply starts.
    @State private var clearOrbPlacementsTask: Task<Void, Never>?
    /// One-shot timer that auto-clears the user-speaking 🙂 face N seconds
    /// after it first appears. Set only when the glyph transitions from
    /// nil → 🙂, NOT restarted on subsequent transcript updates — that's
    /// what stops noisy/background-only transcripts from looping the smile.
    @State private var activitySmileClearTask: Task<Void, Never>?
    /// How long 🙂 holds before auto-clearing if no escalation happens.
    private var activitySmileHoldSeconds: TimeInterval { 5 }
    /// Timer that, after the "you still there?" filler plays and the user
    /// still hasn't responded, switches the orb to 😴 to signal Dominus is
    /// drifting off while it waits.
    @State private var sleepyOrbEmojiTask: Task<Void, Never>?
    /// Seconds of continued user silence after the "you still there?" filler
    /// before the orb shows 😴.
    private var sleepyOrbDelay: TimeInterval { 15 }
    @State private var isInterruptRestartPending = false

    /// One-shot guards so the user/AI cue sound effects fire at most once per
    /// round. The three "AI finished → resume listening" paths are intentional
    /// safety nets; without this flag they'd each play AIVoiceResponseConcluded
    /// for the same response. Same idea for the user-message cue if multiple
    /// send paths fire in quick succession.
    @State private var didPlayUserConclusionCueThisRound = false
    @State private var didPlayAIConclusionCueThisRound   = false

    /// Force-resume listening if the normal "AI finished" paths haven't put
    /// us back in `.listening` this many seconds after generation completes.
    /// Catches the case where `SpeechManager.isSpeaking` is stuck true
    /// because the TTS engine errored and the buffer-completion callback
    /// never fires. Cancelled the moment listening genuinely resumes.
    @State private var aiTalkingWatchdogTask: Task<Void, Never>?
    /// How long the speaker must be SILENT (ttsAmplitude near zero) after
    /// generation has completed before we force-resume listening. Real
    /// ongoing TTS keeps amplitude active, so a long multi-sentence reply
    /// never trips this; only a stuck-`isSpeaking`-but-no-audio state does.
    private let aiTalkingSilenceRequirement: TimeInterval = 3.0
    /// Below this RMS the speaker is considered idle. Tuned to ignore the
    /// noise floor inside SpeechManager's amplitude tap.
    private let aiTalkingSilenceAmplitudeThreshold: Float = 0.02
    @State private var latestVisibleVoiceTranscript = ""

    /// Last time the visible transcript grew by enough new words to be
    /// "substantial" — i.e., almost certainly real continued speech rather
    /// than Whisper hallucinating one phantom word from background noise.
    /// Used by the hard-send cap below.
    @State private var lastSubstantialGrowthAt: Date?

    /// How many new words must appear at once for an update to count as
    /// "substantial growth" (a strong signal the user is still talking).
    /// Tuned for normal speech: typical Whisper chunks land 2–4 words at a
    /// time; hallucinations from noise typically add 0 or 1 word.
    private let substantialGrowthWordThreshold: Int = 2

    /// If the visible transcript has had real content but no substantial
    /// growth for this long, force-send even if Whisper is still trickling
    /// in single phantom words from background noise.
    private let hardSendAfterContentSilenceSeconds: TimeInterval = 3.0
    @State private var latestVisibleVoiceTranscriptUpdatedAt: Date?
    @State private var lastVoiceSpeechActivityAt: Date?
    @State private var rawSoundOnlyBlockStartedAt: Date?
    @State private var headphoneVolumeWarning: HeadphoneVolumeWarning?
    @State private var dismissedHeadphoneVolumeWarning: HeadphoneVolumeWarning?
    @State private var volumeMonitorTask: Task<Void, Never>?
    @State private var appLoadedSoundPlayer: AVAudioPlayer?
    // voiceModeSoundPlayer removed — SFX now route through
    // SpeechManager.shared.playSFX which uses the same AVAudioEngine as
    // TTS. See `playVoiceModeSound` below.
    @State private var isVoiceModeTransitioning = false
    @State private var hasPlayedAppLoadedSound = false
    /// True once the silence filler ("you still there?") has fired this session.
    /// Prevents it from rescheduling after the AI response and looping.
    @State private var silenceFillerHasPlayed = false
    /// True once the idle-exit monitor has been started this session.
    /// Prevents beginListening() re-entries from spawning duplicate monitors.
    @State private var voiceModeExitScheduled = false
    /// Conversations the user has entered voice mode for at least once this
    /// app launch. Used to pick a "welcome back" greeting vs. a first-time one.
    @State private var chatsWithPriorVoiceSession: Set<UUID> = []
    /// Accumulated seconds of true silence (neither user nor AI talking).
    /// Resets to 0 whenever activity resumes.
    @State private var voiceIdleSeconds: TimeInterval = 0

    // Endpointing starts from "transcript hasn't changed for X seconds";
    // the later gate checks whether that stable transcript is also past
    // recent speech. Whisper itself updates the transcript every ~0.5–1.0s,
    // so X must stay above ~1.0s — anything lower fires in the natural gap
    // between Whisper's own chunks and cuts the user off mid-sentence.
    private let defaultVoiceAutoSendDelay: TimeInterval = 1.35
    private let fastVoiceAutoSendDelay: TimeInterval = 0.95
    private let shortVoiceAutoSendDelay: TimeInterval = 1.05
    private let sequenceVoiceAutoSendDelay: TimeInterval = 1.65

    /// Minimum continuous speech silence required before auto-send fires.
    /// The transcript can plateau mid-sentence (Whisper passes are 1s apart),
    /// so we also gate on VAD speech. If the mic detected speech within
    /// this window, we re-arm the timer instead of sending.
    private let voiceSpeechSilenceRequirement: TimeInterval = 0.95
    /// Raw sound is only a short grace signal. If noise keeps happening but
    /// Silero does not classify it as speech, autosend may continue after
    /// this hold instead of waiting forever.
    private let rawSoundOnlyMaxHoldSeconds: TimeInterval = 0.9
    private let voiceLatencyTestingDisablesFillers = true
    private let listeningSilenceFillerDelay: TimeInterval = 20
    private let listeningSilenceFillers = [
        "What's up?",
        "You still there?",
        "I'm here when you're ready.",
        "I'll wait here until you're ready.",
        "Take your time.",
        "No rush. Just Chilling."]

    private var isFullyLoaded: Bool {
        store.isLoaded && whisper.modelReady && isWarmedUp
    }

    var body: some View {
        ZStack {
            chatUI

            if pttState != .idle {
                VoiceOrbOverlay(
                    orbColor:        pttColor,
                    audioLevel:      whisper.audioLevel,
                    status:          activeStatus,
                    isMicMuted:      whisper.isMicMuted,
                    isGenerating:    store.isGenerating || speechMgr.isSpeaking,
                    isSpeaking:      store.isGenerating || speechMgr.isSpeaking,
                    orbPlacements:   store.latestOrbPlacements,
                    activityGlyph:   store.orbActivityGlyph,
                    onTap:           handlePTTTap,
                    onToggleMicMute: { whisper.isMicMuted.toggle() },
                    onStop:          stopCurrentResponse,
                    onDismiss:       exitVoiceMode
                )
                .zIndex(100)
            }

            if pttState != .idle, let warning = headphoneVolumeWarning {
                VStack {
                    HeadphoneVolumeWarningBanner(warning: warning) {
                        dismissedHeadphoneVolumeWarning = warning
                        withAnimation { headphoneVolumeWarning = nil }
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 18)
                    Spacer()
                }
                .transition(.move(edge: .top).combined(with: .opacity))
                .zIndex(150)
            }

            if !isFullyLoaded {
                SplashLoadingView(
                    gemmaProgress:  store.loadProgress,
                    gemmaStatus:    store.loadStatus,
                    whisperProgress: whisper.loadProgress,
                    whisperStatus:  whisper.modelStatus
                )
                .transition(.opacity)
                .zIndex(999)
                .allowsHitTesting(true)
            }
        }
        .animation(.easeInOut(duration: 0.5), value: isFullyLoaded)
        .onChange(of: isFullyLoaded) { loaded in
            guard loaded else { return }
            playAppLoadedSoundIfNeeded()
            prepareVoiceStackForFastEntry()
            scheduleWarmPipelineRefresh()
        }
        .task {
            store.boot()
            store.loadModelIfNeeded()
            setupVoiceCallbacks()
            await whisper.loadModel()
            await warmUpEverything()
            if isFullyLoaded {
                prepareVoiceStackForFastEntry()
            }
        }
        // Re-check both models whenever the app returns to foreground;
        // also fire a title-generation pass when the user backgrounds the app
        // so short-lived chats still get a real title.
        .onChange(of: scenePhase) { phase in
            switch phase {
            case .active:
                store.loadModelIfNeeded()
                Task {
                    await whisper.loadModel()
                    // Light re-warm — covers the case where iOS suspended us long
                    // enough that the audio session or voice file went cold.
                    SpeechManager.shared.prewarmVoice()
                    whisper.prewarmVoiceMode()
                    if isFullyLoaded {
                        prepareVoiceStackForFastEntry()
                        scheduleWarmPipelineRefresh()
                    }
                }
            case .background:
                store.updateCurrentEpisodeSummary()
                store.generateTitleForCurrentIfNeeded()
            default:
                break
            }
        }
        // When generation ends with no TTS pending (e.g. mute is on, or empty response),
        // loop back to listening — the user is still in voice mode and probably wants
        // to keep talking. They can tap X to exit voice mode explicitly.
        .onChange(of: store.isGenerating) { generating in
            guard pttState == .aiTalking else { return }
            guard !isInterruptRestartPending else { return }
            if !generating {
                // Arm the watchdog unconditionally so we never sit forever in
                // .aiTalking if isSpeaking is stuck true (the pre-existing TTS
                // engine bug). The normal resume paths cancel this if they
                // win first.
                armAITalkingWatchdog()
            }
            if !generating && !SpeechManager.shared.isSpeaking {
                beginListeningAfterAIResponse()
            }
        }
        .onChange(of: store.silentAmbientEventCount) { _ in
            guard pttState == .aiTalking else { return }
            guard !isInterruptRestartPending else { return }
            beginListening()
        }
        .onChange(of: whisper.liveTranscript) { transcript in
            handleLiveVoiceTranscript(transcript)
            updateActivityGlyphFromTranscript(transcript)
        }
        .onChange(of: speechMgr.isSpeaking) { isSpeaking in
            handleAISpeakingChange(isSpeaking)
        }
        .onChange(of: pttState) { newState in
            if newState == .idle {
                // Leaving voice mode entirely — clear all orb state.
                idleOrbEmojiTask?.cancel()
                sleepyOrbEmojiTask?.cancel()
                entrySmileClearTask?.cancel()
                clearOrbPlacementsTask?.cancel()
                activitySmileClearTask?.cancel()
                entryGreetingActive = false
                store.orbActivityGlyph = nil
                store.resetOrbThrottle()
                scheduleWarmPipelineRefresh()
            }
        }
        .onChange(of: whisper.lastSpeechActivityAt) { activityAt in
            handleListeningSpeechActivity(activityAt)
        }
        .onChange(of: audioSettings.voiceModeInactivityTimeout) { _ in
            guard pttState == .listening else { return }
            scheduleVoiceModeAutoExit()
        }
        .onChange(of: prompt) { newText in
            // Speculative RAG: after 300 ms of typing inactivity, pre-fetch memories
            // so _send() can skip retrieval and start generating immediately.
            speculativeRetrievalTask?.cancel()
            let trimmed = newText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count >= 4, pttState == .idle, !store.isGenerating else { return }
            speculativeRetrievalTask = Task {
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard !Task.isCancelled else { return }
                store.speculativeRetrieve(for: trimmed)
            }
        }
        // Rename alert
        .alert("Rename Chat", isPresented: $showingRenameAlert) {
            TextField("Chat title", text: $renameText)
                .autocorrectionDisabled()
            Button("Save") {
                if let id = renameConvoID, !renameText.isEmpty {
                    store.renameConversation(id, to: renameText)
                }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    // MARK: - Voice callbacks

    private func setupVoiceCallbacks() {
        // AI finished speaking — wait a beat for the audio hardware to fully drain,
        // then flip to listening. Without the delay the orb goes red while the last
        // syllable is still audible and the mic picks up the AI's own voice.
        SpeechManager.shared.onAllSpeechFinished = {
            Task { @MainActor in
                guard self.pttState == .aiTalking else { return }
                guard !self.isInterruptRestartPending else { return }
                try? await Task.sleep(nanoseconds: 350_000_000) // 350 ms grace period
                guard self.pttState == .aiTalking else { return } // re-check after sleep
                guard !self.isInterruptRestartPending else { return }
                if !self.store.isGenerating {
                    self.beginListeningAfterAIResponse()
                }
            }
        }
    }

    // MARK: - In-use status pill

    /// Returns the pill to show while the app is doing something in the background.
    /// nil = nothing to show. Priority: most specific state first.
    private var activeStatus: (icon: String, message: String)? {
        // Mic / audio engine spinning up after PTT tap
        if whisper.isStartingRecording {
            return ("mic", "Starting microphone\u{2026}")
        }
        // Whisper running final transcription pass. User-facing copy stays
        // "Thinking" because the fast live-transcript path usually skips this,
        // and the next visible phase is AI preparation.
        if whisper.isTranscribing {
            return ("brain", "Thinking\u{2026}")
        }
        // TTS audio pipeline initialising (first-call warm-up or per-message replay)
        if speechMgr.isStartingPlayback {
            return ("speaker.wave.2", "Starting audio\u{2026}")
        }
        return nil
    }

    // MARK: - PTT button handler

    private func handlePTTTap() {
        guard !isVoiceModeTransitioning else { return }

        switch pttState {

        case .idle:
            voiceWasEnabled    = store.voiceEnabled
            store.voiceEnabled = true
            // Fresh voice-mode session starts unmuted, even if the last
            // session ended muted. Mute is sticky WITHIN a session
            // (across turns) but not across sessions.
            whisper.isMicMuted = false
            SpeechManager.shared.stopAndClear()
            // Set the session to .playAndRecord + .default up front so the
            // activation cue, greeting TTS, and listening recording all share
            // one category. (Previously this call was skipped because the
            // pipeline used .playback for TTS and .playAndRecord for
            // recording, so switching here would have caused a category
            // flip mid-cue. With the single-category ChatGPT-style model,
            // this is now the right thing to do — it locks the volume bus
            // for the whole voice session before the first audible event.)
            SpeechManager.shared.prepareForVoiceMode()
            startVolumeMonitoring()
            isVoiceModeTransitioning = false

            // Show 🙂 the instant voice mode opens, so the orb has a friendly
            // face the moment the user enters (or re-enters). The greeting
            // about to play will briefly clear it while the AI is speaking,
            // and `handleAISpeakingChange` re-asserts it for 5 seconds once
            // the greeting finishes. Also drop any stale AI orb state.
            store.resetOrbThrottle()
            store.orbActivityGlyph = "🙂"
            entryGreetingActive   = true
            entrySmileClearTask?.cancel()
            clearOrbPlacementsTask?.cancel()

            // Pick a greeting based on whether this chat has had a prior voice
            // session this app launch. Speak it before listening starts; the
            // existing `onAllSpeechFinished` callback will transition us into
            // listening once the greeting finishes.
            let chatID = store.selectedID
            let returning = chatID.map { chatsWithPriorVoiceSession.contains($0) } ?? false
            let greeting = VoiceModeGreetings.pick(hasBeenInVoiceModeForThisChat: returning)
            if let id = chatID { chatsWithPriorVoiceSession.insert(id) }

            pttState = .aiTalking
            Task { @MainActor in
                await playVoiceModeSound(named: "ActivateVoicetoVoice")
                guard pttState == .aiTalking, store.voiceEnabled else { return }
                SpeechManager.shared.enqueue(greeting)
            }

        case .listening:
            // If mic is muted there's nothing to transcribe — ignore the tap so the user
            // doesn't accidentally drop out of voice mode. They must unmute first.
            if whisper.isMicMuted { return }

            submitVoiceRecording()

        case .aiTalking:
            interruptAIAndResumeListening()
        }
    }

    // MARK: - Listening helpers

    private func prepareVoiceStackForFastEntry() {
        guard pttState == .idle, !whisper.isRecording, !store.isGenerating else { return }
        whisper.prewarmVoiceMode()
        SpeechManager.shared.prepareForVoiceMode()
    }

    private func scheduleWarmPipelineRefresh() {
        warmPipelineRefreshTask?.cancel()
        warmPipelineRefreshTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 750_000_000)
            guard !Task.isCancelled else { return }
            guard scenePhase == .active, isFullyLoaded else { return }
            guard pttState == .idle, !whisper.isRecording, !store.isGenerating else { return }

            store.loadModelIfNeeded()
            whisper.prewarmVoiceMode()
            SpeechManager.shared.prepareForVoiceMode()
            prewarmKeyboard()
        }
    }

    /// Run every "first use" cost behind the loading screen so when the splash
    /// hides, the app is genuinely ready: no text-input stall, no manual-tap-to-send
    /// on the first voice session, no first-TTS delay. Runs the three independent
    /// warmups in parallel.
    private func warmUpEverything() async {
        guard !isWarmedUp else { return }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await store.prewarmEngine() }
            group.addTask { await whisper.prewarmTranscription() }
            group.addTask { @MainActor in SpeechManager.shared.prewarmVoice() }
            group.addTask { @MainActor in prewarmKeyboard() }
        }
        isWarmedUp = true
    }

    /// Pre-loads the iOS keyboard extension so the first tap on the text field
    /// has no delay. Creates a hidden UITextField, makes it first responder to
    /// trigger keyboard load, then immediately resigns and removes it.
    private func prewarmKeyboard() {
        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first?.windows.first else { return }

        let dummy = UITextField()
        dummy.alpha = 0
        dummy.isUserInteractionEnabled = false
        window.addSubview(dummy)
        dummy.becomeFirstResponder()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            dummy.resignFirstResponder()
            dummy.removeFromSuperview()
        }
    }

    /// Use when the AI has just finished a normal reply and we're auto-
    /// resuming listening. Plays AIVoiceResponseConcluded fully through the
    /// speakers BEFORE starting the mic, so Whisper never picks up the cue.
    /// Re-checks the pttState/interrupt gates after the await — if the user
    /// taps to interrupt or backgrounds the app during the cue, we bail.
    private func armAITalkingWatchdog() {
        aiTalkingWatchdogTask?.cancel()
        aiTalkingWatchdogTask = Task { @MainActor in
            // Poll every 250 ms. Track the most recent time the speaker
            // produced non-trivial audio. Only force-resume once we've gone
            // `aiTalkingSilenceRequirement` seconds without amplitude — that
            // means TTS is either done, errored, or otherwise stuck silent.
            var lastNonSilentAt = Date()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard !Task.isCancelled else { return }
                guard pttState == .aiTalking, !isInterruptRestartPending else { return }

                // Generation could resume (e.g. memory refinement) — in that
                // case, suspend the watchdog. It'll be re-armed when
                // generation flips false again.
                if store.isGenerating { return }

                if SpeechManager.shared.ttsAmplitude > aiTalkingSilenceAmplitudeThreshold {
                    lastNonSilentAt = Date()
                    continue
                }

                let silentFor = Date().timeIntervalSince(lastNonSilentAt)
                if silentFor >= aiTalkingSilenceRequirement {
                    print("⏱ AI-talking watchdog: \(String(format: "%.1f", silentFor))s silent — forcing resume listen")
                    // If the cue already played (dedupe flag set) but
                    // we're still in .aiTalking, the cue task must have
                    // failed to resume. Go straight to beginListening
                    // bypassing the dedupe so we recover. If the cue
                    // hasn't played yet, defer to the normal cue+resume
                    // path.
                    if didPlayAIConclusionCueThisRound {
                        beginListening()
                    } else {
                        beginListeningAfterAIResponse()
                    }
                    return
                }
            }
        }
    }

    private func cancelAITalkingWatchdog() {
        aiTalkingWatchdogTask?.cancel()
        aiTalkingWatchdogTask = nil
    }

    private func beginListeningAfterAIResponse() {
        // Bail entirely on re-entry. The three "AI finished" paths
        // (onAllSpeechFinished, isGenerating onChange,
        // handleAISpeakingChange safety net) often fire within ~50 ms of
        // each other on later turns when generation is fast. The
        // dedupe used to "fall through" to beginListening() on the
        // second caller — but beginListening() calls stopAndClear(),
        // which stops the sfxPlayerNode mid-play and made the SFX
        // disappear after a few turns. Now: the FIRST caller owns the
        // entire cue+resume sequence; everyone else bails. If the
        // first caller's task somehow fails to resume listening, the
        // amplitude watchdog catches it.
        guard !didPlayAIConclusionCueThisRound else { return }
        didPlayAIConclusionCueThisRound = true
        Task { @MainActor in
            // Must wait the FULL clip duration here: if we start the mic
            // before the cue finishes playing, Whisper picks up the cue's
            // tail through the speaker, transcribes it as "speech", and the
            // conversation ping-pongs.
            await playVoiceModeSound(
                named: "AIVoiceResponseConcluded",
                waitForFullDuration: true
            )
            guard pttState == .aiTalking,
                  !isInterruptRestartPending,
                  !store.isGenerating else { return }
            beginListening()
        }
    }

    private func beginListening() {
        resetVoiceAutoSendState()
        cancelAITalkingWatchdog()
        isInterruptRestartPending = false
        // Next user turn — clear the user-cue guard so the next submission
        // can play its conclusion sound.
        didPlayUserConclusionCueThisRound = false
        SpeechManager.shared.stopAndClear()
        whisper.startRecording()
        startPulse()
        pttState = .listening
        scheduleListeningSilenceFiller()
        scheduleVoiceModeAutoExit()
    }

    private func returnToIdle() {
        didPlayUserConclusionCueThisRound = false
        didPlayAIConclusionCueThisRound   = false
        cancelAITalkingWatchdog()
        resetVoiceAutoSendState()
        cancelListeningSilenceFiller()
        cancelVoiceModeAutoExit()
        silenceFillerHasPlayed = false    // reset for next voice session
        voiceIdleSeconds = 0
        stopVolumeMonitoring()
        isInterruptRestartPending = false
        stopPulse()
        whisper.cancelRecording()
        // Phone-call style: voice mode owned the audio exclusively. On
        // exit, deactivate the session so other audio apps (Spotify,
        // podcasts) can resume their playback. iOS sends them a
        // notification (`.notifyOthersOnDeactivation`) that wakes them
        // up. The next voice-mode entry calls `lockVoiceModeSession`
        // again — which is the user-intended "I'm starting a voice
        // call" moment where the brief bus shift is acceptable.
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: .notifyOthersOnDeactivation
        )
        store.voiceEnabled = voiceWasEnabled
        pttState = .idle
    }

    /// Called by the X button — immediately stops everything and exits voice mode.
    private func exitVoiceMode() {
        resetVoiceAutoSendState()
        isInterruptRestartPending = false
        SpeechManager.shared.stopAndClear()
        store.stopGeneration()
        isVoiceModeTransitioning = true
        Task { @MainActor in
            await playVoiceModeSound(named: "DeactivateVoicetoVoice")
            returnToIdle()
            isVoiceModeTransitioning = false
        }
    }

    /// Called by the orb's stop button — kills the current AI response (generation + TTS)
    /// but keeps the user inside voice mode. Loops back to listening.
    private func stopCurrentResponse() {
        resetVoiceAutoSendState()
        interruptAIAndResumeListening()
    }

    private func interruptAIAndResumeListening() {
        resetVoiceAutoSendState()
        cancelAITalkingWatchdog()
        isInterruptRestartPending = true
        SpeechManager.shared.stopAndClear()
        store.stopGeneration()
        whisper.cancelRecording()

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard isInterruptRestartPending, pttState == .aiTalking else { return }
            beginListening()
        }
    }

    /// Returns true if `transcript` contains any bracket/paren cue that is NOT
    /// silence or pause. These are real sounds (cough, sneeze, typing, etc.)
    /// that should trigger auto-send just like spoken words.
    private func containsActionableAmbientCue(_ transcript: String) -> Bool {
        // Delegate to WhisperManager so the silence-cue ignore list lives in
        // one place. Previously this method had its own narrower filter
        // ("silence" / "pause" only) that let [Blank_Audio], [No Speech],
        // etc. through, and the AI would respond to phantom non-sounds.
        WhisperManager.containsActionableAmbientCue(transcript)
    }

    // MARK: - Idle / user-activity orb emoji
    //
    // State machine driving `store.orbActivityGlyph`:
    //   • While the AI is generating or speaking: nothing (the AI's own
    //     reply emojis own the orb, persisting until the next emoji).
    //   • User begins speaking (transcript non-empty): 🙂
    //   • User has spoken 3+ sentences: 🤔
    //   • User has spoken 5+ sentences: 🧐 (face with monocle)
    //   • User submits / leaves voice mode: cleared.
    //   • Silence check-in fires ("you still there?"): 👀
    //   • 15s more of silence: 😴

    private func handleAISpeakingChange(_ isSpeaking: Bool) {
        idleOrbEmojiTask?.cancel()
        if isSpeaking {
            // AI is talking — its own reply emojis take over. Cancel any
            // pending entry-smile, activity-smile, or post-AI clear
            // timers; they'll be re-scheduled when this speech finishes.
            store.orbActivityGlyph = nil
            entrySmileClearTask?.cancel()
            activitySmileClearTask?.cancel()
            clearOrbPlacementsTask?.cancel()
            return
        }
        guard pttState != .idle else { return }

        // Safety net for hands-free mode: if TTS just finished, generation is
        // done, and we're still parked in .aiTalking, transition into
        // listening. `onAllSpeechFinished` is the primary resume path but it
        // can race past (fires while isGenerating is still true and bails;
        // or fires before pttState has flipped to .aiTalking on very fast
        // replies). Without this, the user has to tap the orb to resume.
        if pttState == .aiTalking,
           !isInterruptRestartPending,
           !store.isGenerating {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 350_000_000)
                guard pttState == .aiTalking,
                      !isInterruptRestartPending,
                      !store.isGenerating,
                      !SpeechManager.shared.isSpeaking else { return }
                beginListeningAfterAIResponse()
            }
        }

        // Path A — entry / return greeting just finished: show 🙂 for 5s
        // so the user has a friendly face on screen during the welcome
        // window, then clear back to the live dot field.
        if entryGreetingActive {
            entryGreetingActive = false
            store.orbActivityGlyph = "🙂"
            entrySmileClearTask?.cancel()
            entrySmileClearTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                if Task.isCancelled { return }
                guard pttState != .idle else { return }
                let visible = WhisperManager.visibleTranscript(from: whisper.liveTranscript)
                guard visible.isEmpty else { return }   // user already started talking
                store.orbActivityGlyph = nil
            }
            return
        }

        // Path B — normal AI reply just finished. If it produced any
        // emojis, hold them on the orb for 10 seconds, then clear so the
        // orb settles to its pure dot-field state.
        if !store.latestOrbPlacements.isEmpty {
            clearOrbPlacementsTask?.cancel()
            clearOrbPlacementsTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                if Task.isCancelled { return }
                guard pttState != .idle else { return }
                store.resetOrbThrottle()
            }
        }
    }

    private func updateActivityGlyphFromTranscript(_ transcript: String) {
        guard pttState == .listening else { return }
        // Don't override the AI's own emoji while it's still speaking.
        guard !speechMgr.isSpeaking, !store.isGenerating else { return }

        let visible = WhisperManager.visibleTranscript(from: transcript)
        guard !visible.isEmpty else { return }   // leave existing state alone

        // User finally responded — clear any pending sleepy-orb transition.
        sleepyOrbEmojiTask?.cancel()
        sleepyOrbEmojiTask = nil

        // Count sentence-terminator punctuation (Whisper inserts these).
        let sentenceCount = visible.reduce(0) { acc, ch in
            (ch == "." || ch == "?" || ch == "!") ? acc + 1 : acc
        }

        let glyph: String
        if sentenceCount >= 5 {
            glyph = "🧐"     // monocle / thinking-with-glasses
        } else if sentenceCount >= 3 {
            glyph = "🤔"     // thinking face
        } else {
            glyph = "🙂"     // single smile
        }

        // Already showing this glyph — do nothing. (Stops noisy/background
        // transcript ticks from re-triggering the glyph or resetting the
        // smile auto-clear timer.)
        guard store.orbActivityGlyph != glyph else { return }

        // Upgrades to 🤔 / 🧐 mean the user is genuinely talking at length
        // — cancel the auto-clear so those stay until a real submit or AI
        // reply takes over. The 🙂 face stays only on its one-shot timer.
        if glyph == "🙂" {
            store.orbActivityGlyph = "🙂"
            scheduleActivitySmileAutoClear()
        } else {
            activitySmileClearTask?.cancel()
            store.orbActivityGlyph = glyph
        }
    }

    /// One-shot timer that takes 🙂 off the orb after `activitySmileHoldSeconds`.
    /// Not restarted by subsequent transcript ticks, so background noise that
    /// keeps re-publishing the same 🙂 can't extend the smile indefinitely.
    private func scheduleActivitySmileAutoClear() {
        activitySmileClearTask?.cancel()
        activitySmileClearTask = Task { @MainActor in
            try? await Task.sleep(
                nanoseconds: UInt64(activitySmileHoldSeconds * 1_000_000_000)
            )
            if Task.isCancelled { return }
            guard pttState == .listening,
                  !speechMgr.isSpeaking,
                  !store.isGenerating,
                  store.orbActivityGlyph == "🙂"
            else { return }
            store.orbActivityGlyph = nil
        }
    }

    private func handleLiveVoiceTranscript(_ transcript: String) {
        guard pttState == .listening, !whisper.isMicMuted else {
            resetVoiceAutoSendState()
            return
        }

        let visibleTranscript = WhisperManager.visibleTranscript(from: transcript)
        let hasAmbientSound = containsActionableAmbientCue(transcript)

        // Allow ambient-only transcripts (no visible words but real sounds detected)
        // to schedule auto-send, just like spoken words do.
        guard !visibleTranscript.isEmpty || hasAmbientSound else {
            resetVoiceAutoSendState()
            return
        }

        let visibleChanged = !visibleTranscript.isEmpty && visibleTranscript != latestVisibleVoiceTranscript

        if visibleChanged {
            let prevWords = wordCount(of: latestVisibleVoiceTranscript)
            let newWords  = wordCount(of: visibleTranscript)
            // Substantial growth = real speech continuing. Treat the FIRST
            // ever non-empty content as substantial too, so the hard-send
            // cap doesn't fire immediately on a one-word utterance.
            if lastSubstantialGrowthAt == nil ||
               newWords - prevWords >= substantialGrowthWordThreshold {
                lastSubstantialGrowthAt = Date()
            }
            latestVisibleVoiceTranscript = visibleTranscript
            latestVisibleVoiceTranscriptUpdatedAt = Date()
            rawSoundOnlyBlockStartedAt = nil
            scheduleVoiceSpeculativeRetrieval(for: visibleTranscript)
        }
        cancelListeningSilenceFiller()
        if lastVoiceSpeechActivityAt == nil, let speechAt = whisper.lastSpeechActivityAt {
            lastVoiceSpeechActivityAt = speechAt
        }

        // Timer-reset rule: only ACTUAL WORDS reset the autosend timer.
        // Bracket cues ([keyboard_typing], [cough], [sneeze], etc.) still
        // ride along in `spoken` and get sent to the AI when the timer
        // eventually fires (see submitVoiceRecording), but they no longer
        // hold the conversation hostage by perpetually resetting it. The
        // first time the timer is armed at all (when content first
        // appears — visible words OR ambient cues), we still schedule so
        // a pure cough/sneeze utterance can send.
        let isFirstSchedule = voiceAutoSendTask == nil
        if visibleChanged || isFirstSchedule {
            scheduleVoiceAutoSend()
        }
    }

    private func scheduleVoiceSpeculativeRetrieval(for transcript: String) {
        voiceSpeculativeRetrievalTask?.cancel()
        let cleaned = cleanVoiceSubmission(transcript)
        guard cleaned.count >= 4, !store.isGenerating else { return }

        voiceSpeculativeRetrievalTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled, pttState == .listening else { return }
            store.speculativeRetrieve(for: cleaned)
        }
    }

    private func handleListeningSpeechActivity(_ activityAt: Date?) {
        guard pttState == .listening, !whisper.isMicMuted else { return }
        guard let activityAt else { return }
        lastVoiceSpeechActivityAt = activityAt
        rawSoundOnlyBlockStartedAt = nil
        // Re-arm the auto-send timer on every speech event, even when the
        // transcript is already non-empty. The transcript can plateau mid-sentence
        // while Whisper waits for its next 1s pass — if we don't reschedule on
        // speech, the timer can fire while the user is still actively talking.
        // submitVoiceRecording() also handles the empty-transcript case (ambient
        // sounds like cough/sneeze) by going back to listening if there's nothing
        // to send.
        scheduleVoiceAutoSend()
    }

    private struct EndpointBlocker {
        let message: String
        let retryDelay: TimeInterval
    }

    private func scheduleVoiceAutoSend(retryDelay: TimeInterval? = nil) {
        let transcriptSnapshot = latestVisibleVoiceTranscript
        let rawSnapshot = whisper.liveTranscript
        let delay = retryDelay ?? adaptiveVoiceAutoSendDelay(for: transcriptSnapshot, rawTranscript: rawSnapshot)
        voiceAutoSendTask?.cancel()
        voiceAutoSendTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, pttState == .listening else { return }

            print("⏱ autosend FIRED — delay=\(delay)s, transcript='\(transcriptSnapshot)', lastSpeechAt=\(String(describing: whisper.lastSpeechActivityAt)), lastSoundAt=\(String(describing: whisper.lastSoundActivityAt)), noiseFloor=\(String(format: "%.3f", whisper.adaptiveNoiseFloor))")

            if let blocker = endpointBlocker() {
                print(blocker.message)
                scheduleVoiceAutoSend(retryDelay: blocker.retryDelay)
                return
            }

            // If the VISIBLE transcript is still growing, the user is still
            // speaking — wait again. We deliberately do NOT compare the raw
            // `liveTranscript` here: it mutates on every ambient cue Whisper
            // emits ([BLANK_AUDIO], [BREATHING], cough, typing, blowing into
            // the mic, etc.), which would block autosend forever in noisy
            // environments. The visible transcript already strips those.
            //
            // Hard-send cap: even when the visible transcript is mutating,
            // if no SUBSTANTIAL growth (≥N new words) has happened for the
            // hardSend window, that means Whisper is just trickling phantom
            // words from background noise. Force-send so the user isn't
            // held hostage by a noisy room.
            if latestVisibleVoiceTranscript != transcriptSnapshot {
                if let last = lastSubstantialGrowthAt,
                   !latestVisibleVoiceTranscript.isEmpty,
                   Date().timeIntervalSince(last) >= hardSendAfterContentSilenceSeconds {
                    print("🚀 hard-send cap: \(String(format: "%.1f", Date().timeIntervalSince(last)))s since last substantial growth — sending despite transcript jitter")
                    submitVoiceRecording()
                    return
                }
                print("📝 visible transcript still growing — rescheduling")
                scheduleVoiceAutoSend()
                return
            }

            print("🔇 endpoint complete — transcript stable and no recent speech, sending")
            submitVoiceRecording()
        }
    }

    private func endpointBlocker() -> EndpointBlocker? {
        let now = Date()
        if let lastSpeech = whisper.lastSpeechActivityAt ?? lastVoiceSpeechActivityAt {
            let silentFor = now.timeIntervalSince(lastSpeech)
            if silentFor < voiceSpeechSilenceRequirement {
                rawSoundOnlyBlockStartedAt = nil
                let remaining = voiceSpeechSilenceRequirement - silentFor
                return EndpointBlocker(
                    message: "🗣 speech active \(String(format: "%.2f", silentFor))s ago — waiting for \(voiceSpeechSilenceRequirement)s speech silence",
                    retryDelay: max(0.12, remaining + 0.05)
                )
            }
        }

        guard let lastSound = whisper.lastSoundActivityAt else {
            rawSoundOnlyBlockStartedAt = nil
            return nil
        }

        let soundQuietFor = now.timeIntervalSince(lastSound)
        guard soundQuietFor < voiceSpeechSilenceRequirement else {
            rawSoundOnlyBlockStartedAt = nil
            return nil
        }

        let startedAt = rawSoundOnlyBlockStartedAt ?? now
        rawSoundOnlyBlockStartedAt = startedAt
        let rawSoundHeldFor = now.timeIntervalSince(startedAt)
        if rawSoundHeldFor < rawSoundOnlyMaxHoldSeconds {
            let remaining = rawSoundOnlyMaxHoldSeconds - rawSoundHeldFor
            return EndpointBlocker(
                message: "🔊 raw sound without VAD speech — grace \(String(format: "%.2f", rawSoundHeldFor))/\(rawSoundOnlyMaxHoldSeconds)s",
                retryDelay: max(0.12, remaining + 0.05)
            )
        }

        rawSoundOnlyBlockStartedAt = nil
        print("🌫 ignoring raw-only noise after \(String(format: "%.2f", rawSoundHeldFor))s without VAD speech")
        return nil
    }

    private func adaptiveVoiceAutoSendDelay(for visibleTranscript: String, rawTranscript: String) -> TimeInterval {
        let visible = cleanVoiceSubmission(visibleTranscript)
        let raw = rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasAmbientSound = containsActionableAmbientCue(rawTranscript)
        guard !visible.isEmpty else {
            return hasAmbientSound ? defaultVoiceAutoSendDelay : shortVoiceAutoSendDelay
        }

        if looksLikeContinuingSequence(visible) {
            return sequenceVoiceAutoSendDelay
        }

        let wordCount = visible.split(whereSeparator: { $0.isWhitespace }).count
        if wordCount <= 2 {
            return shortVoiceAutoSendDelay
        }

        let clearEndingCharacters = CharacterSet(charactersIn: ".?!")
        if let lastScalar = visible.unicodeScalars.last,
           clearEndingCharacters.contains(lastScalar) {
            return fastVoiceAutoSendDelay
        }

        if raw.hasSuffix(".") || raw.hasSuffix("?") || raw.hasSuffix("!") {
            return fastVoiceAutoSendDelay
        }

        return defaultVoiceAutoSendDelay
    }

    private func cancelVoiceAutoSend() {
        voiceAutoSendTask?.cancel()
        voiceAutoSendTask = nil
    }

    private func cancelVoiceSpeculativeRetrieval() {
        voiceSpeculativeRetrievalTask?.cancel()
        voiceSpeculativeRetrievalTask = nil
    }

    private func scheduleListeningSilenceFiller() {
        // Temporarily disabled while testing voice latency so local filler
        // phrases do not interfere with timing experiments.
        guard !voiceLatencyTestingDisablesFillers else { return }
        // Only fire once per voice session — after it plays we don't reschedule,
        // so the exit timer can run to completion without looping.
        guard !silenceFillerHasPlayed else { return }
        listeningSilenceFillerTask?.cancel()
        listeningSilenceFillerTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(listeningSilenceFillerDelay * 1_000_000_000))
            guard !Task.isCancelled,
                  pttState == .listening,
                  !whisper.isMicMuted,
                  WhisperManager.visibleTranscript(from: whisper.liveTranscript).isEmpty,
                  latestVisibleVoiceTranscript.isEmpty
            else { return }

            playListeningSilenceFiller()
        }
    }

    private func cancelListeningSilenceFiller() {
        listeningSilenceFillerTask?.cancel()
        listeningSilenceFillerTask = nil
    }

    private func playListeningSilenceFiller() {
        silenceFillerHasPlayed = true   // prevent this from ever looping
        cancelListeningSilenceFiller()
        resetVoiceAutoSendState()
        stopPulse()
        whisper.cancelRecording()
        pttState = .aiTalking

        // Orb states for the check-in:
        //   • 👀 the moment Dominus speaks the "still there?" prompt
        //   • 😴 after `sleepyOrbDelay` more seconds of continued silence
        // (activityGlyph overrides AI placements via the orb's priority,
        // so we don't need to wipe placements — they remain underneath.)
        idleOrbEmojiTask?.cancel()
        store.orbActivityGlyph = "👀"

        SpeechManager.shared.stopAndClear()
        SpeechManager.shared.enqueue(listeningSilenceFillers.randomElement() ?? "You still there?")

        sleepyOrbEmojiTask?.cancel()
        sleepyOrbEmojiTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(sleepyOrbDelay * 1_000_000_000))
            if Task.isCancelled { return }
            guard pttState != .idle else { return }
            let visible = WhisperManager.visibleTranscript(from: whisper.liveTranscript)
            guard visible.isEmpty else { return }   // user finally spoke; activity handler took over
            store.orbActivityGlyph = "😴"
        }
    }

    private func scheduleVoiceModeAutoExit() {
        // Only start one monitor per voice session.
        guard !voiceModeExitScheduled else { return }
        voiceModeExitScheduled = true
        voiceIdleSeconds = 0
        voiceModeAutoExitTask?.cancel()

        voiceModeAutoExitTask = Task { @MainActor in
            while !Task.isCancelled, pttState != .idle {
                try? await Task.sleep(nanoseconds: 1_000_000_000) // tick every second
                guard !Task.isCancelled, pttState != .idle else { return }

                let userTalking = store.isGenerating == false &&
                    (!latestVisibleVoiceTranscript.isEmpty ||
                     (whisper.isRecording && (whisper.audioLevel > 0.02)))
                let aiTalking = SpeechManager.shared.isSpeaking || store.isGenerating

                if userTalking || aiTalking {
                    // Activity detected — reset the idle counter
                    voiceIdleSeconds = 0
                } else {
                    voiceIdleSeconds += 1
                    if voiceIdleSeconds >= audioSettings.voiceModeInactivityTimeout {
                        await playVoiceModeSound(named: "DeactivateVoicetoVoice")
                        returnToIdle()
                        return
                    }
                }
            }
        }
    }

    private func cancelVoiceModeAutoExit() {
        voiceModeAutoExitTask?.cancel()
        voiceModeAutoExitTask = nil
        voiceModeExitScheduled = false
        voiceIdleSeconds = 0
    }

    private func resetVoiceAutoSendState() {
        cancelVoiceAutoSend()
        cancelVoiceSpeculativeRetrieval()
        latestVisibleVoiceTranscript = ""
        latestVisibleVoiceTranscriptUpdatedAt = nil
        lastVoiceSpeechActivityAt = nil
        lastSubstantialGrowthAt = nil
        rawSoundOnlyBlockStartedAt = nil
    }

    private func wordCount(of text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace }).count
    }

    private func looksLikeContinuingSequence(_ text: String) -> Bool {
        let alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
        let lettersOnly = text.uppercased().unicodeScalars
            .filter { $0.value >= 65 && $0.value <= 90 }
            .map { String($0) }
            .joined()
        if lettersOnly.count >= 3,
           lettersOnly.count < alphabet.count,
           alphabet.hasPrefix(lettersOnly) {
            return true
        }

        let tokens = text
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
        guard tokens.count >= 3 else { return false }

        let numberWords: [String: Int] = [
            "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4,
            "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9,
            "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13,
            "fourteen": 14, "fifteen": 15, "sixteen": 16,
            "seventeen": 17, "eighteen": 18, "nineteen": 19,
            "twenty": 20
        ]
        let numbers = tokens.compactMap { token -> Int? in
            if let value = Int(token) { return value }
            return numberWords[token]
        }
        guard numbers.count == tokens.count else { return false }

        let sequentialPairs = zip(numbers, numbers.dropFirst()).filter { $0.1 == $0.0 + 1 }.count
        let repeatedPairs = zip(numbers, numbers.dropFirst()).filter { $0.1 == $0.0 }.count
        return sequentialPairs >= 2 || repeatedPairs >= 1 || numbers.count >= 4
    }

    // MARK: - Headphone volume warnings

    private func startVolumeMonitoring() {
        volumeMonitorTask?.cancel()
        dismissedHeadphoneVolumeWarning = nil
        updateHeadphoneVolumeWarning()

        volumeMonitorTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard !Task.isCancelled else { return }
                updateHeadphoneVolumeWarning()
            }
        }
    }

    private func stopVolumeMonitoring() {
        volumeMonitorTask?.cancel()
        volumeMonitorTask = nil
        headphoneVolumeWarning = nil
        dismissedHeadphoneVolumeWarning = nil
    }

    private func playAppLoadedSoundIfNeeded() {
        guard !hasPlayedAppLoadedSound else { return }
        hasPlayedAppLoadedSound = true

        guard let url = Bundle.main.url(
            forResource: "AppLoadedSoundEffect",
            withExtension: "wav",
            subdirectory: "SoundEffects"
        ) ?? Bundle.main.url(
            forResource: "AppLoadedSoundEffect",
            withExtension: "wav"
        ) else {
            print("🔇 App loaded sound effect not found in bundle.")
            return
        }

        do {
            let player = try AVAudioPlayer(contentsOf: url)
            let volume = SpeechManager.shared.safeEffectVolume(Float(audioSettings.startupSoundVolume))
            player.volume = volume
            player.prepareToPlay()
            player.setVolume(volume, fadeDuration: 0)
            player.play()
            appLoadedSoundPlayer = player
        } catch {
            print("🔇 Failed to play app loaded sound effect:", error.localizedDescription)
        }
    }

    /// Thin shim — actual playback now routes through `SpeechManager`'s
    /// shared `AVAudioEngine` so SFX and AI voice share one render thread
    /// and audio session. The previous implementation used `AVAudioPlayer`
    /// (a separate audio path) and reset the audio session on every cue,
    /// which competed with the TTS engine for hardware access and caused
    /// micro-cutouts in the AI voice between cues.
    private func playVoiceModeSound(named resourceName: String,
                                    waitForFullDuration: Bool = false) async {
        let volume = Float(audioSettings.voiceModeVolume(for: resourceName))
        await SpeechManager.shared.playSFX(
            named: resourceName,
            volume: volume,
            waitForFullDuration: waitForFullDuration
        )
    }

    private func updateHeadphoneVolumeWarning() {
        guard pttState != .idle, isPrivateListeningRoute else {
            headphoneVolumeWarning = nil
            dismissedHeadphoneVolumeWarning = nil
            return
        }

        let volume = AVAudioSession.sharedInstance().outputVolume
        let nextWarning: HeadphoneVolumeWarning?
        if volume > 0.50 {
            nextWarning = .high
        } else if volume <= 0.12 {
            nextWarning = .low
        } else {
            nextWarning = nil
        }

        guard let nextWarning else {
            headphoneVolumeWarning = nil
            dismissedHeadphoneVolumeWarning = nil
            return
        }

        guard dismissedHeadphoneVolumeWarning != nextWarning else { return }
        withAnimation { headphoneVolumeWarning = nextWarning }
    }

    private var isPrivateListeningRoute: Bool {
        AVAudioSession.sharedInstance().currentRoute.outputs.contains { output in
            switch output.portType {
            case .headphones,
                 .bluetoothA2DP,
                 .bluetoothHFP,
                 .bluetoothLE,
                 .carAudio,
                 .airPlay:
                return true
            default:
                return false
            }
        }
    }

    private func submitVoiceRecording() {
        resetVoiceAutoSendState()
        cancelListeningSilenceFiller()
        stopPulse()
        // Cancel pending greeting / post-AI / smile timers so the next AI
        // reply gets a clean orb pipeline. Note: we deliberately do NOT
        // reset `orbActivityGlyph` here — the noise-driven auto-send used
        // to wipe 🙂 each cycle and let the next noise tick re-trigger it
        // in a loop. `handleAISpeakingChange` will clear the glyph cleanly
        // when the AI actually starts speaking.
        idleOrbEmojiTask?.cancel()
        sleepyOrbEmojiTask?.cancel()
        entrySmileClearTask?.cancel()
        clearOrbPlacementsTask?.cancel()
        activitySmileClearTask?.cancel()
        entryGreetingActive = false
        Task {
            let liveText = cleanVoiceSubmission(whisper.liveTranscript)
            let spoken: String
            if !liveText.isEmpty {
                whisper.stopRecordingWithoutTranscribing()
                spoken = liveText
                print("⚡️ Voice fast path sent live transcript:", liveText)
            } else {
                spoken = await whisper.stopAndTranscribe()
            }
            let visibleVoiceText = cleanVoiceSubmission(spoken)

            // Detect whether Whisper embedded actionable non-speech markers
            // (cough, sneeze, laughter, typing, etc.). Silence and pause markers
            // are excluded — they never get sent or acknowledged.
            let hasAmbientCues = containsActionableAmbientCue(spoken)
            let textForSend = hasAmbientCues ? spoken : visibleVoiceText

            guard !visibleVoiceText.isEmpty || hasAmbientCues else {
                beginListening()
                return
            }
            if AudioSettingsStore.shared.hapticsEnabled {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            }
            store.voiceEnabled = true
            store.send(
                textForSend,
                includeAmbientCues: true,
                ambientDuration: whisper.lastRecordingDuration
            )
            pttState = .aiTalking
            // New round — reset the AI conclusion cue guard so it can fire
            // once when the AI's reply ends.
            didPlayAIConclusionCueThisRound = false
            // Fire-and-forget — plays during the Gemma-generation window
            // before TTS starts. Guard against double-fire from any rapid
            // re-entry of submitVoiceRecording.
            if !didPlayUserConclusionCueThisRound {
                didPlayUserConclusionCueThisRound = true
                Task { @MainActor in
                    await playVoiceModeSound(named: "UserVoiceResponseConcluded")
                }
            }
        }
    }

    private func cleanVoiceSubmission(_ text: String) -> String {
        var s = WhisperManager.visibleTranscript(from: text)
        let replacements: [(pattern: String, replacement: String)] = [
            ("(?i)\\b(?:period|full stop)\\b[\\.,!?:;]*", ". "),
            ("(?i)\\bcomma\\b[\\.,!?:;]*", ", "),
            ("(?i)\\b(?:question mark)\\b[\\.,!?:;]*", "? "),
            ("(?i)\\b(?:exclamation point|exclamation mark)\\b[\\.,!?:;]*", "! ")
        ]

        for item in replacements {
            s = s.replacingOccurrences(
                of: item.pattern,
                with: item.replacement,
                options: .regularExpression
            )
        }

        s = s.replacingOccurrences(of: "\\s+([\\.,!?:;])", with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: "([\\.,!?:;]){2,}", with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Pulse animation

    private func startPulse() {
        pulseScale   = 1.0
        pulseOpacity = 0.7
        withAnimation(
            .easeInOut(duration: 0.75)
            .repeatForever(autoreverses: true)
        ) {
            pulseScale   = 1.55
            pulseOpacity = 0.0
        }
    }

    private func stopPulse() {
        withAnimation(.easeOut(duration: 0.15)) {
            pulseScale   = 1.0
            pulseOpacity = 0.0
        }
    }

    // MARK: - PTT button appearance

    private var pttIcon: String {
        switch pttState {
        case .idle:      return "waveform"
        case .listening: return "waveform"
        case .aiTalking: return "waveform"
        }
    }

    private var pttColor: Color {
        switch pttState {
        case .idle:      return .gray
        case .listening: return .green
        case .aiTalking: return .red
        }
    }

    private var pttLabel: String {
        if pttState == .listening && whisper.isTranscribing { return "Transcribing…" }
        switch pttState {
        case .idle:      return ""
        case .listening: return "Recording… tap to send"
        case .aiTalking: return "Tap to interrupt"
        }
    }

    // MARK: - Root layout

    private var chatUI: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            VStack(spacing: 0) {
                detailHeader
                Divider()
                chatScrollView
                if showContextHint {
                    contextHintBanner
                }
                Divider()
                inputBar
            }
            .onChange(of: contextUsage) { usage in
                guard !hasShownContextHint, usage >= 0.85 else { return }
                hasShownContextHint = true
                withAnimation { showContextHint = true }
            }
            .onChange(of: store.selectedID) { _ in
                showContextHint = false
                hasShownContextHint = false
            }
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(selection: $store.selectedID) {
            ForEach(store.conversations) { convo in
                sidebarRow(for: convo)
            }
        }
        .navigationTitle("Chats")
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                HStack {
                    Button {
                        showProfileSheet = true
                    } label: {
                        Image(systemName: "person.circle")
                    }
                    Button {
                        showAudioSettingsSheet = true
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                    }
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    store.newConversation()
                } label: {
                    Image(systemName: "square.and.pencil")
                }
            }
        }
        .sheet(isPresented: $showProfileSheet) {
            ProfileView()
        }
        .sheet(isPresented: $showAudioSettingsSheet) {
            AudioSettingsView()
        }
    }

    @ViewBuilder
    private func sidebarRow(for convo: Conversation) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(convo.title)
                .lineLimit(1)
                .font(.body)
            Text(convo.startedAtDisplay)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .tag(convo.id)
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                store.deleteConversation(convo)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            Button {
                beginRename(convo)
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            .tint(.blue)
        }
        .contextMenu {
            Button { beginRename(convo) } label: {
                Label("Rename", systemImage: "pencil")
            }
            Button(role: .destructive) {
                store.deleteConversation(convo)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private func beginRename(_ convo: Conversation) {
        renameConvoID = convo.id
        renameText    = convo.title
        showingRenameAlert = true
    }

    // MARK: - Context hint banner

    private var contextHintBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle")
                .foregroundStyle(.orange)
            Text("Earlier messages are fading from AI context — long-term memory still applies.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                withAnimation { showContextHint = false }
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color(.systemOrange).opacity(0.08))
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    // MARK: - Context usage (0.0–1.0)
    // Mirrors ChatStore's prompt trimming estimate so the ring reflects the actual
    // rolling context sent to Gemma instead of the full visible chat.
    private var contextUsage: Double {
        store.contextUsageEstimate(
            for: store.selectedConversation(),
            draft: prompt
        )
    }

    // MARK: - Detail header

    private var detailHeader: some View {
        HStack(spacing: 12) {
            Text(store.selectedConversation()?.title ?? "Dominus")
                .font(.headline)
                .lineLimit(1)
            Spacer()

            // TTS toggle — read replies aloud in text mode. Hidden during voice mode
            // because voice mode controls TTS internally (mute lives on the orb).
            if pttState == .idle {
                Button {
                    store.voiceEnabled.toggle()
                } label: {
                    Image(systemName: store.voiceEnabled ? "speaker.wave.2.fill" : "speaker.slash")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(store.voiceEnabled ? Color.accentColor : .secondary)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(store.voiceEnabled ? "Mute spoken replies" : "Speak replies aloud")
            }

            Button { showContextInspector = true } label: {
                ContextRingView(usage: contextUsage)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Inspect context window")
            .sheet(isPresented: $showContextInspector) {
                ContextInspectorSheet(snapshot: store.lastContextSnapshot,
                                      usage: contextUsage)
            }
        }
        .padding(.horizontal)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    // MARK: - Chat scroll view

    private var chatScrollView: some View {
        ScrollViewReader { proxy in
            ZStack {
                ScrollView {
                    VStack(spacing: 12) {
                        // In voice mode: show messages as-is (brackets visible so the
                        // user can see what the AI is reacting to in real time).
                        // In text mode: strip bracket markers from user messages so
                        // "[Coughing]" disappears and "Hello! [Coughing]" becomes "Hello!".
                        // Pure ambient-only messages (entirely brackets) are hidden in text mode.
                        let isInVoiceMode = pttState != .idle
                        let allMsgs = store.selectedConversation()?.messages ?? []
                        let msgs = allMsgs.filter { msg in
                            guard msg.role == .user, !isInVoiceMode else { return true }
                            return !WhisperManager.visibleTranscript(from: msg.content).isEmpty
                        }
                        ForEach(msgs) { msg in
                            let isStreamingAssistant = store.isGenerating
                                && msg.role == .assistant
                                && msg.id == allMsgs.last?.id
                            let displayText: String = {
                                guard msg.role == .user, !isInVoiceMode else { return msg.content }
                                return WhisperManager.visibleTranscript(from: msg.content)
                            }()
                            ChatBubble(
                                messageID: msg.id,
                                role: msg.role,
                                text: displayText,
                                isStreaming: isStreamingAssistant
                            )
                                .id(msg.id)
                        }
                    }
                    .padding()
                }
                .onChange(of: store.selectedConversation()?.messages.count ?? 0) { _ in
                    guard let last = store.selectedConversation()?.messages.last else { return }
                    if last.role == .assistant {
                        withAnimation(.easeOut(duration: 0.28)) {
                            proxy.scrollTo(last.id, anchor: .top)
                        }
                    }
                }

                // Status pill — floats at top of chat area for audio/transcription only.
                VStack {
                    if let status = activeStatus {
                        StatusPillView(icon: status.icon, message: status.message)
                            .padding(.top, 12)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                    Spacer()
                }
                .animation(.easeInOut(duration: 0.25), value: activeStatus?.message)
                .zIndex(20)
                .allowsHitTesting(false)
            }
            .animation(.easeInOut(duration: 0.35), value: pttState == .idle)
        }
    }

    // MARK: - Input bar

    private var inputBar: some View {
        VStack(spacing: 4) {

            // Status hint — shown only when voice session is active
            if pttState != .idle {
                Text(pttLabel)
                    .font(.caption)
                    .foregroundStyle(pttColor.opacity(0.85))
                    .transition(.opacity)
            }

            HStack(spacing: 10) {

                // Text field: live Whisper transcript while recording, loading state
                // while model is still warming up, normal prompt otherwise.
                if pttState == .listening {
                    TextField("Listening\u{2026}", text: .constant(whisper.liveTranscript))
                        .textFieldStyle(.roundedBorder)
                        .disabled(true)
                } else {
                    TextField(
                        store.isLoaded ? "Type a message\u{2026}" : "Loading AI model\u{2026}",
                        text: $prompt
                    )
                    .textFieldStyle(.roundedBorder)
                    .disabled(!store.isLoaded)
                    .overlay(alignment: .trailing) {
                        if store.isLoading {
                            ProgressView()
                                .scaleEffect(0.65)
                                .padding(.trailing, 8)
                        }
                    }
                }

                // ── THE ONE BUTTON ──────────────────────────────────────────
                Button {
                    handlePTTTap()
                } label: {
                    Image(systemName: pttIcon)
                        .font(.system(size: 22, weight: .medium))
                        .foregroundColor(pttColor)
                        .frame(width: 52, height: 52)
                }
                .disabled(store.isLoading || !store.isLoaded || !whisper.modelReady)
                // ────────────────────────────────────────────────────────────

                // Send / stop button — only shown in idle text mode
                if pttState == .idle {
                    Button {
                        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
                        if store.isGenerating && trimmed.isEmpty {
                            store.stopGeneration()
                        } else if !trimmed.isEmpty {
                            if AudioSettingsStore.shared.hapticsEnabled {
                                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                            }
                            prompt = ""
                            store.send(trimmed)
                        }
                    } label: {
                        Image(
                            systemName: store.isGenerating
                                ? "stop.circle.fill"
                                : "arrow.up.circle.fill"
                        )
                        .font(.system(size: 28))
                        .foregroundColor(store.isGenerating ? .orange : .blue)
                    }
                    .disabled(
                        store.isLoading || !store.isLoaded ||
                        (!store.isGenerating &&
                         prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    )
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
        }
        .animation(.easeInOut(duration: 0.2), value: pttState == .idle)
    }
}

// MARK: - Headphone Volume Warning

private struct HeadphoneVolumeWarningBanner: View {
    let warning: HeadphoneVolumeWarning
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: warning.icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(Color.white.opacity(0.16), in: Circle())

            Text(warning.message)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.white)

            Spacer(minLength: 12)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss volume warning")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.white.opacity(0.22), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.28), radius: 18, y: 8)
        .gesture(
            DragGesture(minimumDistance: 18)
                .onEnded { value in
                    if abs(value.translation.width) > 44 || value.translation.height < -24 {
                        onDismiss()
                    }
                }
        )
    }
}

// MARK: - Context Ring

struct ContextRingView: View {
    let usage: Double

    private var ringColor: Color {
        switch usage {
        case ..<0.45: return .green
        case ..<0.70: return .yellow
        default:      return .red
        }
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color(.systemGray5), lineWidth: 4)
            Circle()
                .trim(from: 0, to: usage)
                .stroke(ringColor, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.2), value: usage)
            Text("\(Int(usage * 100))%")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .frame(width: 40, height: 40)
    }
}

// MARK: - Context Inspector Sheet

struct ContextInspectorSheet: View {
    let snapshot: ChatStore.ContextSnapshot
    let usage: Double

    private var ringColor: Color {
        switch usage {
        case ..<0.45: return .green
        case ..<0.70: return .yellow
        default:      return .red
        }
    }

    var body: some View {
        NavigationStack {
            List {
                // ── Header: total tokens ──────────────────────────────────
                Section {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Context Window")
                                .font(.headline)
                            Text("\(snapshot.totalTokens) estimated tokens")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        ZStack {
                            Circle()
                                .stroke(Color(.systemGray5), lineWidth: 5)
                            Circle()
                                .trim(from: 0, to: usage)
                                .stroke(ringColor,
                                        style: StrokeStyle(lineWidth: 5, lineCap: .round))
                                .rotationEffect(.degrees(-90))
                            Text("\(Int(usage * 100))%")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                        .frame(width: 48, height: 48)
                    }
                    .padding(.vertical, 4)
                }

                // ── System prompt ─────────────────────────────────────────
                inspectorSection(
                    title: "System Prompt",
                    tokens: snapshot.systemTokens,
                    color: .blue,
                    content: snapshot.systemPrompt.isEmpty ? "(empty)" : snapshot.systemPrompt
                )

                // ── User profile ──────────────────────────────────────────
                inspectorSection(
                    title: "User Profile",
                    tokens: snapshot.profileTokens,
                    color: .purple,
                    content: snapshot.profile.isEmpty ? "(not injected this turn)" : snapshot.profile
                )

                // ── Memory context ────────────────────────────────────────
                inspectorSection(
                    title: "Retrieved Memory",
                    tokens: snapshot.memoryTokens,
                    color: .orange,
                    content: snapshot.memory.isEmpty ? "(no relevant memory this turn)" : snapshot.memory
                )

                // ── Conversation turns ────────────────────────────────────
                Section {
                    ForEach(snapshot.turns) { turn in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(turn.role)
                                    .font(.caption)
                                    .fontWeight(.semibold)
                                    .foregroundStyle(turn.role == "You" ? Color.accentColor : Color.secondary)
                                Spacer()
                                tokenBadge(turn.tokens, color: .primary.opacity(0.5))
                            }
                            Text(turn.content)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(4)
                        }
                        .padding(.vertical, 2)
                    }
                } header: {
                    HStack {
                        Text("Conversation Turns (\(snapshot.turns.count))")
                        Spacer()
                        tokenBadge(snapshot.turnsTokens, color: .green)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Context Inspector")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    @ViewBuilder
    private func inspectorSection(title: String, tokens: Int, color: Color, content: String) -> some View {
        Section {
            Text(content)
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            HStack {
                Text(title)
                Spacer()
                tokenBadge(tokens, color: color)
            }
        }
    }

    private func tokenBadge(_ count: Int, color: Color) -> some View {
        Text("~\(count) tok")
            .font(.caption2)
            .fontWeight(.semibold)
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.12), in: Capsule())
    }
}

// MARK: - Chat Bubble

struct CinematicStreamingText: View {
    let text: String
    let isStreaming: Bool

    @State private var revealedCharacterCount = 0
    @State private var revealTask: Task<Void, Never>?

    private var characters: [Character] {
        Array(text)
    }

    var body: some View {
        Group {
            if isStreaming {
                Text(String(characters.prefix(revealedCharacterCount)))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onAppear { syncReveal(animated: true) }
                    .onChange(of: text) { _ in
                        syncReveal(animated: true)
                    }
                    .onDisappear {
                        revealTask?.cancel()
                        revealTask = nil
                    }
            } else {
                Text(text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onAppear {
                        revealTask?.cancel()
                        revealTask = nil
                        revealedCharacterCount = characters.count
                    }
            }
        }
    }

    private func syncReveal(animated: Bool) {
        let latestCharacterCount = characters.count
        guard isStreaming else {
            revealedCharacterCount = latestCharacterCount
            return
        }

        if latestCharacterCount < revealedCharacterCount {
            revealedCharacterCount = latestCharacterCount
        }

        guard latestCharacterCount > revealedCharacterCount else {
            return
        }

        revealTask?.cancel()
        revealTask = Task { @MainActor in
            var index = revealedCharacterCount
            while index < latestCharacterCount, !Task.isCancelled {
                let delay: UInt64 = animated ? 6_000_000 : 0
                if delay > 0 {
                    try? await Task.sleep(nanoseconds: delay)
                }
                guard !Task.isCancelled else { return }
                revealedCharacterCount = index + 1
                index += 1
            }
        }
    }
}

struct ChatBubble: View {
    let messageID: UUID
    let role: ChatMessage.Role
    let text: String
    var isStreaming: Bool = false

    @ObservedObject private var speech = SpeechManager.shared
    @State private var copied: Bool = false
    @State private var thinkingPulse: Bool = false

    private var isPlayingThis: Bool {
        speech.nowPlayingMessageID == messageID
    }

    private var isMemoryNotice: Bool {
        text.hasPrefix("Added to Memory")
            || text.hasPrefix("Memory Suggestion:")
            || text.hasPrefix("Memory suggestion dismissed")
            || text.hasPrefix("Forgot Memory:")
    }

    private var isThinkingPlaceholder: Bool {
        role == .assistant && text == "Thinking..."
    }

    var body: some View {
        HStack(alignment: .bottom) {
            if role == .assistant {
                VStack(alignment: .leading, spacing: 4) {
                    bubbleView(
                        background: isMemoryNotice ? Color(.systemGray3) : Color(.systemGray5),
                        foreground: isMemoryNotice || isThinkingPlaceholder ? Color(.secondaryLabel) : .primary,
                        align: .leading
                    )
                    if !isMemoryNotice && !isThinkingPlaceholder {
                        assistantActions
                    }
                }
                Spacer(minLength: 48)
            } else {
                Spacer(minLength: 48)
                VStack(alignment: .trailing, spacing: 4) {
                    bubbleView(background: .blue, foreground: .white, align: .trailing)
                }
            }
        }
        .onAppear {
            guard isThinkingPlaceholder else { return }
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                thinkingPulse = true
            }
        }
    }

    private func bubbleView(background: Color, foreground: Color, align: Alignment) -> some View {
        CinematicStreamingText(text: text, isStreaming: isStreaming && role == .assistant && !isMemoryNotice)
            .textSelection(.enabled)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(isMemoryNotice || isThinkingPlaceholder ? Color.clear : background)
            .foregroundColor(foreground)
            .opacity(isThinkingPlaceholder ? (thinkingPulse ? 0.35 : 0.75) : 1)
            .clipShape(RoundedRectangle(cornerRadius: isMemoryNotice || isThinkingPlaceholder ? 0 : 18, style: .continuous))
            .frame(maxWidth: UIScreen.main.bounds.width * 0.72, alignment: align)
    }

    private var assistantActions: some View {
        HStack(spacing: 22) {
            Button {
                UIPasteboard.general.string = text
                withAnimation { copied = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
                    withAnimation { copied = false }
                }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 18))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Copy message")

            ShareLink(item: text) {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 18))
            }
            .accessibilityLabel("Share message")

            Button {
                if isPlayingThis {
                    SpeechManager.shared.stopAndClear()
                } else {
                    SpeechManager.shared.speak(text, for: messageID)
                }
            } label: {
                // Show a spinner while audio pipeline is warming up for this message,
                // stop icon while actively playing, speaker icon when idle.
                if speech.isStartingPlayback && speech.nowPlayingMessageID == messageID {
                    ProgressView()
                        .scaleEffect(0.75)
                        .frame(width: 18, height: 18)
                } else {
                    Image(systemName: isPlayingThis ? "stop.circle" : "speaker.wave.2")
                        .font(.system(size: 18))
                        .foregroundStyle(isPlayingThis ? Color.accentColor : .secondary)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isPlayingThis ? "Stop reading" : "Read message aloud")
        }
        .foregroundStyle(.secondary)
        .padding(.leading, 6)
    }
}
