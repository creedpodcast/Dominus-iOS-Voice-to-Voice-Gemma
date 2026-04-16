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
                // Both generation and speech finished — ready for next turn
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

    // MARK: - Voice callbacks (PTT)

    private func setupVoiceCallbacks() {

        // STT ended unexpectedly (error / OS timeout after ~1 min) while user was recording
        speech.onSTTEnded = {
            Task { @MainActor in
                guard self.pttState == .listening else { return }
                // Nothing to send — cancel back to idle
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
                // If still generating, more TTS chunks will arrive — stay in aiTalking
            }
        }
    }

    // MARK: - PTT button logic

    private func handlePTTTap() {
        switch pttState {

        case .idle:
            // ── Start recording ──────────────────────────────────────────
            speech.autoStopOnSilence = false   // user taps to stop, not silence timer
            SpeechManager.shared.stopAndClear()
            try? speech.startListening()
            pttState = .listening

        case .listening:
            // ── User done speaking — stop and send ───────────────────────
            speech.stopListening()
            let spoken = speech.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            speech.transcript = ""
            guard !spoken.isEmpty else {
                // Nothing was captured — cancel
                returnToIdle()
                return
            }
            store.send(spoken)
            pttState = .aiTalking

        case .aiTalking:
            // ── Interrupt AI — stop generation + TTS, start listening ────
            SpeechManager.shared.stopAndClear()
            store.stopGeneration()
            speech.transcript = ""
            speech.autoStopOnSilence = false
            try? speech.startListening()
            pttState = .listening
        }
    }

    /// Tears down the audio session and returns button to idle.
    private func returnToIdle() {
        speech.tearDownVoiceSession()
        pttState = .idle
    }

    // MARK: - PTT button appearance

    private var pttIcon: String {
        switch pttState {
        case .idle:      return "mic"
        case .listening: return "stop.circle.fill"
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
        case .idle:      return "Tap to speak"
        case .listening: return "Tap when done"
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
            Button {
                beginRename(convo)
            } label: {
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

    // MARK: - Detail header

    private var detailHeader: some View {
        HStack {
            Text(store.selectedConversation()?.title ?? "Dominus")
                .font(.headline)
                .lineLimit(1)

            Spacer()

            Button {
                store.voiceEnabled.toggle()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: store.voiceEnabled ? "speaker.wave.2.fill" : "text.bubble")
                    Text(store.voiceEnabled ? "Voice" : "Text")
                }
                .font(.subheadline)
            }
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
        VStack(spacing: 0) {
            // PTT hint label — visible only during active voice turns
            if pttState != .idle {
                Text(pttLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 6)
            }

            HStack(spacing: 8) {

                // Text field — shows live STT transcript while listening
                if pttState == .listening {
                    TextField("Listening…", text: $speech.transcript)
                        .textFieldStyle(.roundedBorder)
                        .disabled(true)
                        .foregroundColor(.primary)
                } else {
                    TextField("Type a message…", text: $prompt)
                        .textFieldStyle(.roundedBorder)
                }

                // PTT button
                Button {
                    handlePTTTap()
                } label: {
                    Image(systemName: pttIcon)
                        .font(.system(size: 20))
                        .foregroundColor(pttColor)
                        .padding(6)
                        // Pulse ring when listening to signal recording is active
                        .overlay(
                            Group {
                                if pttState == .listening {
                                    Circle()
                                        .stroke(Color.red.opacity(0.35), lineWidth: 2)
                                        .padding(-4)
                                }
                            }
                        )
                }
                .disabled(store.isLoading || !store.isLoaded)

                // Send / stop button (text mode only — hidden during PTT session)
                if pttState == .idle {
                    Button {
                        if store.isGenerating && prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            store.stopGeneration()
                        } else {
                            let current = prompt
                            prompt = ""
                            store.send(current)
                        }
                    } label: {
                        Image(systemName: store.isGenerating ? "stop.circle.fill" : "arrow.up.circle.fill")
                            .font(.system(size: 28))
                            .foregroundColor(store.isGenerating ? .orange : .blue)
                    }
                    .disabled(
                        store.isLoading ||
                        !store.isLoaded ||
                        (!store.isGenerating && prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    )
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
        }
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
