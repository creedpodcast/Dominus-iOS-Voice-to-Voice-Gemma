import SwiftUI

struct ContentView: View {

    @StateObject private var store = ChatStore()
    @StateObject private var speech = SpeechRecognitionManager.shared

    @State private var prompt: String = ""
    @State private var renameText: String = ""
    @State private var renamingID: UUID?

    @State private var micDidSend: Bool = false
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

            // ✅ If voice is on, restart after TTS finishes (prevents recording itself)
            SpeechManager.shared.onAllSpeechFinished = {
                Task { @MainActor in
                    await restartListeningIfNeeded(triggerVoiceFinished: true)
                }
            }
        }
        .onChange(of: store.isGenerating) { generating in
            // ✅ If voice is OFF, restart after generation finishes
            if !generating {
                Task { @MainActor in
                    await restartListeningIfNeeded(triggerVoiceFinished: false)
                }
            }
        }
    }

    @MainActor
    private func restartListeningIfNeeded(triggerVoiceFinished: Bool) async {
        guard sessionActive else { return }
        guard !speech.isListening else { return }
        guard store.isLoaded && !store.isLoading else { return }

        if store.voiceEnabled {
            // voice mode: only restart from TTS callback
            guard triggerVoiceFinished else { return }
        } else {
            // text mode: only restart from generation finished
            guard !triggerVoiceFinished else { return }
        }

        micDidSend = false
        SpeechManager.shared.stopAndClear()
        try? speech.startListening()
    }

    private var chatUI: some View {
        NavigationSplitView {
            List(selection: $store.selectedID) {
                ForEach(store.conversations) { convo in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(convo.title).lineLimit(1)
                        Text(convo.updatedAt, style: .relative)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .tag(convo.id)
                }
            }
            .navigationTitle("Chats")
        } detail: {
            VStack(spacing: 0) {
                header
                Divider()
                chatView
                Divider()
                inputBar
            }
            .navigationTitle("Dominus")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var header: some View {
        HStack {
            Text("Dominus")
                .font(.headline)

            Spacer()

            Button {
                store.voiceEnabled.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: store.voiceEnabled ? "speaker.wave.2.fill" : "text.bubble")
                    Text(store.voiceEnabled ? "Voice" : "Text")
                }
                .font(.subheadline)
            }

            Button("New Chat") { store.newConversation() }
        }
        .padding(.horizontal)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    private var chatView: some View {
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
            .onChange(of: (store.selectedConversation()?.messages.count ?? 0)) { _ in
                if let last = store.selectedConversation()?.messages.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }

    private var inputBar: some View {
        HStack {
            TextField("Type a message…", text: $prompt)
                .textFieldStyle(.roundedBorder)

            // ✅ Tap once starts session, tap again ends session
            Button {
                if !sessionActive {
                    sessionActive = true
                    micDidSend = false

                    // ✅ Required: silence ends each turn
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

            // ✅ Auto-send when listening ends
            .onChange(of: speech.isListening) { listening in
                if !listening && sessionActive && !micDidSend {
                    let spoken = speech.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                    speech.transcript = ""

                    if !spoken.isEmpty {
                        micDidSend = true
                        Task { await store.send(spoken) }
                    }
                }
            }

            Button {
                let current = prompt
                prompt = ""
                Task { await store.send(current) }
            } label: {
                if store.isGenerating { ProgressView() } else { Text("Send") }
            }
            .disabled(
                store.isGenerating ||
                store.isLoading ||
                !store.isLoaded ||
                prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            )
        }
        .padding()
    }
}

struct ChatBubble: View {
    let role: ChatMessage.Role
    let text: String

    var body: some View {
        HStack {
            if role == .assistant {
                bubble(background: .gray.opacity(0.2), foreground: .primary)
                Spacer()
            } else {
                Spacer()
                bubble(background: .blue, foreground: .white)
            }
        }
    }

    private func bubble(background: Color, foreground: Color) -> some View {
        Text(text)
            .padding(12)
            .background(background)
            .foregroundColor(foreground)
            .cornerRadius(16)
            .frame(maxWidth: 280, alignment: .leading)
    }
}
