import SwiftUI

// MARK: - PTT State

private enum PTTState {
    case idle       // ready — tap to speak
    case listening  // recording user speech — tap when done
    case aiTalking  // AI generating / speaking — tap to interrupt
}

struct ContentView: View {

    @StateObject private var store  = ChatStore()
    @StateObject private var speech = SpeechRecognitionManager.shared

    @State private var prompt: String = ""

    // Rename sheet state
    @State private var showingRenameAlert = false
    @State private var renameConvoID: UUID?
    @State private var renameText: String = ""

    // Push-to-talk state
    @State private var pttState: PTTState = .idle

    // Pulse animation for the recording ring
    @State private var pulseScale: CGFloat = 1.0
    @State private var pulseOpacity: Double = 0.6

    // Remember whether voice was on before PTT so we can restore it
    @State private var voiceWasEnabled: Bool = false

    var body: some View {
        ZStack {
            chatUI

            if store.isLoading || !store.isLoaded {
                LoadingView(
                    progress: store.loadProgress,
                    status: store.loadStatus
                )
                .transition(.opacity)
                .zIndex(999)
            }
        }
        .task {
            store.boot()
            store.loadModelIfNeeded()
            setupVoiceCallbacks()
        }
        // When generation ends, check if we can return to idle
        .onChange(of: store.isGenerating) { generating in
            guard pttState == .aiTalking else { return }
            if !generating && !SpeechManager.shared.isSpeaking {
                returnToIdle()
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

        // STT ended unexpectedly (error / OS 1-min timeout) — reset
        speech.onSTTEnded = {
            Task { @MainActor in
                guard self.pttState == .listening else { return }
                self.returnToIdle()
            }
        }

        // AI finished speaking — if generation is also done, return to idle
        SpeechManager.shared.onAllSpeechFinished = {
            Task { @MainActor in
                guard self.pttState == .aiTalking else { return }
                if !self.store.isGenerating {
                    self.returnToIdle()
                }
            }
        }
    }

    // MARK: - PTT button handler

    private func handlePTTTap() {
        switch pttState {

        case .idle:
            // Save voice state and force it ON so AI always speaks back
            voiceWasEnabled      = store.voiceEnabled
            store.voiceEnabled   = true
            // Start recording — no auto-silence, user taps to stop
            speech.autoStopOnSilence = false
            SpeechManager.shared.stopAndClear()
            try? speech.startListening()
            startPulse()
            pttState = .listening

        case .listening:
            // User done — stop recording and send
            stopPulse()
            speech.stopListening()
            let spoken = speech.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            speech.transcript = ""
            guard !spoken.isEmpty else {
                returnToIdle()
                return
            }
            store.send(spoken)
            pttState = .aiTalking

        case .aiTalking:
            // Interrupt AI immediately — stop both generation and voice
            SpeechManager.shared.stopAndClear()
            store.stopGeneration()
            speech.transcript = ""
            speech.autoStopOnSilence = false
            try? speech.startListening()
            startPulse()
            pttState = .listening
        }
    }

    private func returnToIdle() {
        stopPulse()
        speech.tearDownVoiceSession()
        store.voiceEnabled = voiceWasEnabled   // restore previous voice preference
        pttState = .idle
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
        switch pttState {
        case .idle:      return ""
        case .listening: return "Listening… tap when done"
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
                Divider()
                inputBar
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
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    store.newConversation()
                } label: {
                    Image(systemName: "square.and.pencil")
                }
            }
        }
    }

    @ViewBuilder
    private func sidebarRow(for convo: Conversation) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(convo.title)
                .lineLimit(1)
                .font(.body)
            Text(convo.updatedAt, style: .relative)
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

    // MARK: - Detail header (title only — no extra toggle buttons)

    private var detailHeader: some View {
        HStack {
            Text(store.selectedConversation()?.title ?? "Dominus")
                .font(.headline)
                .lineLimit(1)
            Spacer()
        }
        .padding(.horizontal)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    // MARK: - Chat scroll view

    private var chatScrollView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 12) {
                    let msgs = store.selectedConversation()?.messages ?? []
                    ForEach(msgs) { msg in
                        ChatBubble(role: msg.role, text: msg.content)
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

                // Text field: shows live transcript while listening, normal prompt otherwise
                if pttState == .listening {
                    TextField("Listening…", text: $speech.transcript)
                        .textFieldStyle(.roundedBorder)
                        .disabled(true)
                } else {
                    TextField("Type a message…", text: $prompt)
                        .textFieldStyle(.roundedBorder)
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
                .disabled(store.isLoading || !store.isLoaded)
                // ────────────────────────────────────────────────────────────

                // Send / stop button — only shown in idle text mode
                if pttState == .idle {
                    Button {
                        if store.isGenerating &&
                            prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            store.stopGeneration()
                        } else {
                            let text = prompt
                            prompt = ""
                            store.send(text)
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

// MARK: - Chat Bubble

struct ChatBubble: View {
    let role: ChatMessage.Role
    let text: String

    var body: some View {
        HStack(alignment: .bottom) {
            if role == .assistant {
                bubbleView(background: Color(.systemGray5), foreground: .primary, align: .leading)
                Spacer(minLength: 48)
            } else {
                Spacer(minLength: 48)
                bubbleView(background: .blue, foreground: .white, align: .trailing)
            }
        }
    }

    private func bubbleView(background: Color, foreground: Color, align: Alignment) -> some View {
        Text(text)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(background)
            .foregroundColor(foreground)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .frame(maxWidth: UIScreen.main.bounds.width * 0.72, alignment: align)
    }
}
