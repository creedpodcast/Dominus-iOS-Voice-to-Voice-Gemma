import SwiftUI
import AVFoundation

// MARK: - PTT State

private enum PTTState {
    case idle       // ready — tap to speak
    case listening  // recording user speech — tap when done
    case aiTalking  // AI generating / speaking — tap to interrupt
}

struct ContentView: View {

    @StateObject private var store   = ChatStore()
    @StateObject private var speech  = SpeechRecognitionManager.shared
    @StateObject private var whisper = WhisperManager.shared
    @ObservedObject private var speechMgr = SpeechManager.shared

    @Environment(\.scenePhase) private var scenePhase

    @State private var prompt: String = ""

    // Rename sheet state
    @State private var showingRenameAlert = false
    @State private var renameConvoID: UUID?
    @State private var renameText: String = ""

    // Context hint banner
    @State private var showContextHint: Bool = false
    @State private var hasShownContextHint: Bool = false

    // Profile sheet
    @State private var showProfileSheet = false

    // Push-to-talk state
    @State private var pttState: PTTState = .idle

    // Pulse animation for the recording ring
    @State private var pulseScale: CGFloat = 1.0
    @State private var pulseOpacity: Double = 0.6

    // Remember whether voice was on before PTT so we can restore it
    @State private var voiceWasEnabled: Bool = false

    private var isFullyLoaded: Bool {
        store.isLoaded && whisper.modelReady
    }

    var body: some View {
        ZStack {
            chatUI

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
        .task {
            store.boot()
            store.loadModelIfNeeded()
            setupVoiceCallbacks()
            await whisper.loadModel()
        }
        // Re-check both models whenever the app returns to foreground;
        // also fire a title-generation pass when the user backgrounds the app
        // so short-lived chats still get a real title.
        .onChange(of: scenePhase) { phase in
            switch phase {
            case .active:
                store.loadModelIfNeeded()
                Task { await whisper.loadModel() }
            case .background:
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
            if !generating && !SpeechManager.shared.isSpeaking {
                beginListening()
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
                try? await Task.sleep(nanoseconds: 350_000_000) // 350 ms grace period
                guard self.pttState == .aiTalking else { return } // re-check after sleep
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
        // AI is generating but TTS hasn't started yet — the "thinking" gap
        if store.isGenerating && !speechMgr.isSpeaking && pttState == .aiTalking {
            return ("brain", "Thinking\u{2026}")
        }
        // Text mode: model is generating a reply
        if store.isGenerating && pttState == .idle {
            return ("cpu", "Generating\u{2026}")
        }
        return nil
    }

    // MARK: - PTT button handler

    private func handlePTTTap() {
        switch pttState {

        case .idle:
            voiceWasEnabled    = store.voiceEnabled
            store.voiceEnabled = true
            SpeechManager.shared.stopAndClear()
            beginListening()

        case .listening:
            // If mic is muted there's nothing to transcribe — ignore the tap so the user
            // doesn't accidentally drop out of voice mode. They must unmute first.
            if whisper.isMicMuted { return }

            stopPulse()
            Task {
                let spoken = await whisper.stopAndTranscribe()
                guard !spoken.isEmpty else {
                    returnToIdle()
                    return
                }
                store.send(spoken, includeAmbientCues: true)
                pttState = .aiTalking
            }

        case .aiTalking:
            SpeechManager.shared.stopAndClear()
            store.stopGeneration()
            whisper.cancelRecording()
            beginListening()
        }
    }

    // MARK: - Listening helpers

    private func beginListening() {
        SpeechManager.shared.stopAndClear()
        // Tear down SpeechRecognitionManager's engine first — two AVAudioEngines
        // cannot both install a tap on the input node simultaneously.
        speech.tearDownVoiceSession()
        whisper.startRecording()
        startPulse()
        pttState = .listening
    }

    private func returnToIdle() {
        stopPulse()
        whisper.cancelRecording()
        // WhisperManager stopped its engine — safe to fully deactivate audio session
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        store.voiceEnabled = voiceWasEnabled
        pttState = .idle
    }

    /// Called by the X button — immediately stops everything and exits voice mode.
    private func exitVoiceMode() {
        SpeechManager.shared.stopAndClear()
        store.stopGeneration()
        returnToIdle()
    }

    /// Called by the orb's stop button — kills the current AI response (generation + TTS)
    /// but keeps the user inside voice mode. Loops back to listening.
    private func stopCurrentResponse() {
        SpeechManager.shared.stopAndClear()
        store.stopGeneration()
        beginListening()
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
        case .idle:      return "mic"
        case .listening: return "waveform"
        case .aiTalking: return "mic.fill"
        }
    }

    private var pttColor: Color {
        switch pttState {
        case .idle:      return .blue
        case .listening: return .red
        case .aiTalking: return .green
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
                Button {
                    showProfileSheet = true
                } label: {
                    Image(systemName: "person.circle")
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
    // Estimates token usage from history chars + current draft. ~4 chars per token.
    private var contextUsage: Double {
        let maxTokens = 2048
        let maxMessages = 20
        let systemOverhead = 300

        let messages = store.selectedConversation()?.messages ?? []
        let windowChars = messages.suffix(maxMessages).reduce(0) { $0 + $1.content.count }
        let estimated = systemOverhead + (windowChars + prompt.count) / 4
        return min(1.0, Double(estimated) / Double(maxTokens))
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

            ContextRingView(usage: contextUsage)
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
                        let msgs = store.selectedConversation()?.messages ?? []
                        ForEach(msgs) { msg in
                            ChatBubble(messageID: msg.id, role: msg.role, text: msg.content)
                                .id(msg.id)
                        }
                    }
                    .padding()
                }
                .onChange(of: store.selectedConversation()?.messages.count ?? 0) { _ in
                    if let last = store.selectedConversation()?.messages.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
                .onChange(of: store.selectedConversation()?.messages.last?.content) { _ in
                    guard store.isGenerating else { return }
                    if let last = store.selectedConversation()?.messages.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }

                if pttState != .idle {
                    VoiceOrbOverlay(
                        orbColor:        pttColor,
                        audioLevel:      whisper.audioLevel,
                        isMicMuted:      whisper.isMicMuted,
                        isGenerating:    store.isGenerating || speechMgr.isSpeaking,
                        onTap:           handlePTTTap,
                        onToggleMicMute: { whisper.isMicMuted.toggle() },
                        onStop:          stopCurrentResponse,
                        onDismiss:       exitVoiceMode
                    )
                    .zIndex(10)
                }

                // Status pill — floats at top of chat area whenever something is loading
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
                    ZStack {
                        // Animated pulse ring — only visible while recording
                        Circle()
                            .stroke(Color.red, lineWidth: 2.5)
                            .frame(width: 48, height: 48)
                            .scaleEffect(pulseScale)
                            .opacity(pttState == .listening ? pulseOpacity : 0)

                        // Core icon
                        Image(systemName: pttIcon)
                            .font(.system(size: 22, weight: .medium))
                            .foregroundColor(pttColor)
                            .frame(width: 36, height: 36)
                    }
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

// MARK: - Context Ring

struct ContextRingView: View {
    let usage: Double

    private var ringColor: Color {
        switch usage {
        case ..<0.6:  return .green
        case ..<0.85: return .yellow
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

// MARK: - Chat Bubble

struct ChatBubble: View {
    let messageID: UUID
    let role: ChatMessage.Role
    let text: String

    @ObservedObject private var speech = SpeechManager.shared
    @State private var copied: Bool = false

    private var isPlayingThis: Bool {
        speech.nowPlayingMessageID == messageID
    }

    var body: some View {
        HStack(alignment: .bottom) {
            if role == .assistant {
                VStack(alignment: .leading, spacing: 4) {
                    bubbleView(background: Color(.systemGray5), foreground: .primary, align: .leading)
                    assistantActions
                }
                Spacer(minLength: 48)
            } else {
                Spacer(minLength: 48)
                bubbleView(background: .blue, foreground: .white, align: .trailing)
            }
        }
    }

    private func bubbleView(background: Color, foreground: Color, align: Alignment) -> some View {
        Text(text)
            .textSelection(.enabled)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(background)
            .foregroundColor(foreground)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
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
