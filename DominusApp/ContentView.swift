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
        case .high: return "Headphone volume is high"
        case .low:  return "Headphone volume is very low"
        }
    }
}

struct ContentView: View {

    @StateObject private var store   = ChatStore()
    @StateObject private var speech  = SpeechRecognitionManager.shared
    @StateObject private var whisper = WhisperManager.shared
    @ObservedObject private var speechMgr = SpeechManager.shared
    @ObservedObject private var audioSettings = AudioSettingsStore.shared

    @Environment(\.scenePhase) private var scenePhase

    @State private var prompt: String = ""
    /// Debounced task that pre-fetches RAG memories while the user is typing.
    @State private var speculativeRetrievalTask: Task<Void, Never>?
    /// Flips true only after every cold component (LLM inference graph, TTS voice file,
    /// Whisper transcription graph) has been pre-warmed. Splash stays up until then so
    /// "ready" actually means ready — no first-turn stalls, no manual-tap-to-send race.
    @State private var isWarmedUp: Bool = false
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
    @State private var isInterruptRestartPending = false
    @State private var latestVisibleVoiceTranscript = ""
    @State private var latestVisibleVoiceTranscriptUpdatedAt: Date?
    @State private var lastVoiceActivityAt: Date?
    @State private var headphoneVolumeWarning: HeadphoneVolumeWarning?
    @State private var dismissedHeadphoneVolumeWarning: HeadphoneVolumeWarning?
    @State private var volumeMonitorTask: Task<Void, Never>?
    @State private var appLoadedSoundPlayer: AVAudioPlayer?
    @State private var voiceModeSoundPlayer: AVAudioPlayer?
    @State private var isVoiceModeTransitioning = false
    @State private var hasPlayedAppLoadedSound = false
    /// True once the silence filler ("you still there?") has fired this session.
    /// Prevents it from rescheduling after the AI response and looping.
    @State private var silenceFillerHasPlayed = false
    /// True once the idle-exit monitor has been started this session.
    /// Prevents beginListening() re-entries from spawning duplicate monitors.
    @State private var voiceModeExitScheduled = false
    /// Accumulated seconds of true silence (neither user nor AI talking).
    /// Resets to 0 whenever activity resumes.
    @State private var voiceIdleSeconds: TimeInterval = 0

    private let voiceAutoSendDelay: TimeInterval = 1.5
    private let voiceActivityGraceDelay: TimeInterval = 0.8
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
            if !generating && !SpeechManager.shared.isSpeaking {
                beginListening()
            }
        }
        .onChange(of: store.silentAmbientEventCount) { _ in
            guard pttState == .aiTalking else { return }
            guard !isInterruptRestartPending else { return }
            beginListening()
        }
        .onChange(of: whisper.liveTranscript) { transcript in
            handleLiveVoiceTranscript(transcript)
        }
        .onChange(of: whisper.lastAudioActivityAt) { activityAt in
            handleListeningAudioActivity(activityAt)
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
                    self.beginListening()
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
        // Whisper running final transcription pass
        if whisper.isTranscribing {
            return ("waveform", "Transcribing your speech\u{2026}")
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
            SpeechManager.shared.stopAndClear()
            startVolumeMonitoring()
            beginListening()
            isVoiceModeTransitioning = false
            Task { @MainActor in
                await playVoiceModeSound(named: "ActivateVoicetoVoice")
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

    private func beginListening() {
        resetVoiceAutoSendState()
        isInterruptRestartPending = false
        SpeechManager.shared.stopAndClear()
        // Tear down SpeechRecognitionManager's engine first — two AVAudioEngines
        // cannot both install a tap on the input node simultaneously.
        speech.tearDownVoiceSession()
        whisper.startRecording()
        startPulse()
        pttState = .listening
        scheduleListeningSilenceFiller()
        scheduleVoiceModeAutoExit()
    }

    private func returnToIdle() {
        resetVoiceAutoSendState()
        cancelListeningSilenceFiller()
        cancelVoiceModeAutoExit()
        silenceFillerHasPlayed = false    // reset for next voice session
        voiceIdleSeconds = 0
        stopVolumeMonitoring()
        isInterruptRestartPending = false
        stopPulse()
        whisper.cancelRecording()
        // WhisperManager stopped its engine — safe to fully deactivate audio session
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
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
        let pattern = "(?:\\[[^\\]\\n]{1,48}\\]|\\([^)\\n]{1,48}\\))"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        let range = NSRange(transcript.startIndex..., in: transcript)
        return regex.matches(in: transcript, range: range).contains { match in
            guard let r = Range(match.range, in: transcript) else { return false }
            let cue = transcript[r].lowercased()
            return !cue.contains("silence") && !cue.contains("pause")
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

        if !visibleTranscript.isEmpty, visibleTranscript != latestVisibleVoiceTranscript {
            latestVisibleVoiceTranscript = visibleTranscript
            latestVisibleVoiceTranscriptUpdatedAt = Date()
        }
        cancelListeningSilenceFiller()
        if lastVoiceActivityAt == nil {
            lastVoiceActivityAt = whisper.lastAudioActivityAt ?? Date()
        }
        scheduleVoiceAutoSend()
    }

    private func handleListeningAudioActivity(_ activityAt: Date?) {
        guard pttState == .listening, !whisper.isMicMuted else { return }
        guard let activityAt else { return }
        lastVoiceActivityAt = activityAt
        // Schedule on any audio activity — ambient sounds (cough, sneeze, etc.) don't
        // produce visible transcript text until stopAndTranscribe(), so we can't gate
        // on latestVisibleVoiceTranscript here. submitVoiceRecording() handles the
        // "nothing to send" case by calling beginListening() and returning.
        scheduleVoiceAutoSend()
    }

    private func scheduleVoiceAutoSend() {
        let transcriptSnapshot = latestVisibleVoiceTranscript
        let rawSnapshot = whisper.liveTranscript
        voiceAutoSendTask?.cancel()
        voiceAutoSendTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(voiceAutoSendDelay * 1_000_000_000))
            guard !Task.isCancelled, pttState == .listening else { return }

            // If the transcript is still growing, the user is still speaking — wait again.
            if latestVisibleVoiceTranscript != transcriptSnapshot ||
               whisper.liveTranscript != rawSnapshot {
                scheduleVoiceAutoSend()
                return
            }

            // submitVoiceRecording() handles the empty case — if stopAndTranscribe()
            // returns nothing (no words, no ambient cues), it calls beginListening()
            // and we return to listening immediately without sending anything.
            submitVoiceRecording()
        }
    }

    private func cancelVoiceAutoSend() {
        voiceAutoSendTask?.cancel()
        voiceAutoSendTask = nil
    }

    private func scheduleListeningSilenceFiller() {
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
        SpeechManager.shared.stopAndClear()
        SpeechManager.shared.enqueue(listeningSilenceFillers.randomElement() ?? "You still there?")
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
        latestVisibleVoiceTranscript = ""
        latestVisibleVoiceTranscriptUpdatedAt = nil
        lastVoiceActivityAt = nil
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
            let volume = Float(audioSettings.startupSoundVolume)
            player.volume = volume
            player.prepareToPlay()
            player.setVolume(volume, fadeDuration: 0)
            player.play()
            appLoadedSoundPlayer = player
        } catch {
            print("🔇 Failed to play app loaded sound effect:", error.localizedDescription)
        }
    }

    private func playVoiceModeSound(named resourceName: String) async {
        guard let url = Bundle.main.url(
            forResource: resourceName,
            withExtension: "wav",
            subdirectory: "SoundEffects"
        ) ?? Bundle.main.url(
            forResource: resourceName,
            withExtension: "wav"
        ) else {
            print("🔇 Voice mode sound not found:", resourceName)
            return
        }

        do {
            do {
                if pttState == .idle && !isVoiceModeTransitioning {
                    try AVAudioSession.sharedInstance().setCategory(
                        .playback,
                        mode: .default,
                        options: []
                    )
                } else {
                    try AVAudioSession.sharedInstance().setCategory(
                        .playAndRecord,
                        mode: .voiceChat,
                        options: [.defaultToSpeaker, .allowBluetooth, .allowBluetoothA2DP]
                    )
                }
                try AVAudioSession.sharedInstance().setActive(true, options: [])
            } catch {
                print("🔇 Voice mode sound session setup failed:", error.localizedDescription)
            }

            let player = try AVAudioPlayer(contentsOf: url)
            let volume = Float(audioSettings.voiceModeVolume(for: resourceName))
            player.volume = volume
            player.prepareToPlay()
            player.setVolume(volume, fadeDuration: 0)
            player.play()
            voiceModeSoundPlayer = player
            let duration = max(0.25, min(player.duration + 0.08, 1.2))
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
        } catch {
            print("🔇 Failed to play voice mode sound:", error.localizedDescription)
        }
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
                 .bluetoothLE:
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
        Task {
            let spoken = await whisper.stopAndTranscribe()
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
            store.send(
                textForSend,
                includeAmbientCues: true,
                ambientDuration: whisper.lastRecordingDuration
            )
            pttState = .aiTalking
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

    @State private var revealedChunkCount = 0
    @State private var revealTask: Task<Void, Never>?

    private var chunks: [String] {
        Self.chunkText(text)
    }

    var body: some View {
        Group {
            if isStreaming {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(Array(chunks.enumerated()), id: \.offset) { index, chunk in
                        ZStack(alignment: .leading) {
                            Text(chunk)
                                .opacity(index < revealedChunkCount ? 0 : 0.18)
                                .blur(radius: 1.1)

                            Text(chunk)
                                .opacity(index < revealedChunkCount ? 1 : 0)
                                .blur(radius: index < revealedChunkCount ? 0 : 0.8)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .animation(.easeOut(duration: 0.2), value: revealedChunkCount)
                    }
                }
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
                        revealedChunkCount = chunks.count
                    }
            }
        }
    }

    private func syncReveal(animated: Bool) {
        let latestChunks = chunks
        guard isStreaming else {
            revealedChunkCount = latestChunks.count
            return
        }

        guard latestChunks.count > revealedChunkCount else {
            return
        }

        revealTask?.cancel()
        revealTask = Task { @MainActor in
            var index = revealedChunkCount
            while index < latestChunks.count, !Task.isCancelled {
                let delay: UInt64 = animated ? 38_000_000 : 0
                if delay > 0 {
                    try? await Task.sleep(nanoseconds: delay)
                }
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.18)) {
                    revealedChunkCount = index + 1
                }
                index += 1
            }
        }
    }

    private static func chunkText(_ text: String) -> [String] {
        let clean = text
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return [] }

        var chunks: [String] = []
        var current = ""

        func flush() {
            let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            chunks.append(trimmed)
            current = ""
        }

        let sentences = clean
            .splitKeepingSentenceTerminators()
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        for sentence in sentences {
            if !current.isEmpty {
                current += " "
            }
            current += sentence

            let sentenceCount = current.filter { ".!?".contains($0) }.count
            if sentenceCount >= 2 || current.count >= 420 {
                flush()
            }
        }
        flush()

        return chunks.isEmpty ? [clean] : chunks
    }
}

private extension String {
    func splitKeepingSentenceTerminators() -> [String] {
        var parts: [String] = []
        var current = ""

        for character in self {
            current.append(character)
            if ".!?".contains(character) {
                parts.append(current)
                current = ""
            }
        }

        let remainder = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !remainder.isEmpty {
            parts.append(remainder)
        }

        return parts
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
