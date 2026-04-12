import SwiftUI

struct ContentView: View {

    @StateObject private var store  = ChatStore()
    @StateObject private var speech = SpeechRecognitionManager.shared

    @State private var prompt: String = ""

    // Rename sheet state
    @State private var showingRenameAlert = false
    @State private var renameConvoID: UUID?
    @State private var renameText: String = ""

    // Voice session state
    @State private var micDidSend: Bool    = false
    @State private var sessionActive: Bool = false

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

            SpeechManager.shared.onAllSpeechFinished = {
                Task { @MainActor in
                    await restartListeningIfNeeded(triggerVoiceFinished: true)
                }
            }
        }
        .onChange(of: store.isGenerating) { generating in
            if !generating {
                Task { @MainActor in
                    await restartListeningIfNeeded(triggerVoiceFinished: false)
                }
            }
        }
        // Rename alert — uses a TextField so the user can edit inline
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

    // MARK: - Restart listening

    @MainActor
    private func restartListeningIfNeeded(triggerVoiceFinished: Bool) async {
        guard sessionActive              else { return }
        guard !speech.isListening        else { return }
        guard store.isLoaded && !store.isLoading else { return }

        if store.voiceEnabled {
            guard triggerVoiceFinished  else { return }
        } else {
            guard !triggerVoiceFinished else { return }
        }

        micDidSend = false
        SpeechManager.shared.stopAndClear()
        try? speech.startListening()
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
        // ── Trailing swipe: Delete ──────────────────────────────────────
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                store.deleteConversation(convo)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        // ── Leading swipe: Rename ───────────────────────────────────────
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            Button {
                beginRename(convo)
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            .tint(.blue)
        }
        // ── Long-press context menu ─────────────────────────────────────
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
        HStack(spacing: 8) {
            TextField("Type a message…", text: $prompt)
                .textFieldStyle(.roundedBorder)

            // Mic button — tap once to start session, tap again to stop
            Button {
                if !sessionActive {
                    sessionActive = true
                    micDidSend    = false
                    speech.autoStopOnSilence = true
                    SpeechManager.shared.stopAndClear()
                    try? speech.startListening()
                } else {
                    sessionActive = false
                    SpeechManager.shared.stopAndClear()
                    if speech.isListening { speech.stopListening() }
                }
            } label: {
                Image(systemName: sessionActive ? "stop.circle.fill" : "mic")
                    .font(.system(size: 20))
                    .foregroundColor(sessionActive ? .orange : .blue)
                    .padding(6)
            }
            .disabled(store.isLoading || !store.isLoaded)
            // Auto-send when silence timer fires and stopListening() is called
            .onChange(of: speech.isListening) { listening in
                if !listening && sessionActive && !micDidSend {
                    let spoken = speech.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                    speech.transcript = ""
                    if !spoken.isEmpty {
                        micDidSend = true
                        store.send(spoken)
                    }
                }
            }

            // Send button
            Button {
                if store.isGenerating && prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    // Nothing typed — just stop
                    store.stopGeneration()
                } else {
                    // Text ready — stop current and send new
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
                // Always tappable while generating (acts as stop button)
                // Only disabled when idle with empty prompt
                (!store.isGenerating && prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            )
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
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
