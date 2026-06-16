import SwiftUI

struct ProfileView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var store = ProfileStore.shared

    @State private var displayNameDraft = ""
    @State private var appPurposeDraft = ""
    @State private var personaDraft = ""
    @State private var jobTitleDraft = ""
    @State private var goalDrafts = Array(repeating: "", count: 3)
    @State private var behaviorDrafts = Array(repeating: "", count: 3)
    @State private var voiceEmojisDraft: Bool = true

    private let nameLimit = 40
    private let shortLimit = 120
    private let purposeLimit = 160
    private let personaLimit = 220

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LimitedTextField(
                        title: "Name or preferred name",
                        text: $displayNameDraft,
                        limit: nameLimit,
                        autocapitalization: .words
                    )
                } header: {
                    Label("Name", systemImage: "person")
                }

                Section {
                    LimitedTextField(
                        title: "Job title or role",
                        text: $jobTitleDraft,
                        limit: shortLimit,
                        autocapitalization: .sentences
                    )
                } header: {
                    Label("Role or Work", systemImage: "briefcase")
                }

                Section {
                    LimitedTextEditor(
                        text: $appPurposeDraft,
                        placeholder: "One sentence about why you use Dominus.",
                        limit: purposeLimit,
                        minHeight: 76
                    )
                } header: {
                    Label("Why You Use Dominus", systemImage: "target")
                }

                Section {
                    LimitedTextEditor(
                        text: $personaDraft,
                        placeholder: "One sentence about tone, style, or boundaries.",
                        limit: personaLimit,
                        minHeight: 88
                    )
                } header: {
                    Label("How Dominus Should Talk", systemImage: "bubble.left.and.bubble.right")
                }

                Section {
                    Toggle(isOn: $voiceEmojisDraft) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Use emojis in voice mode")
                            Text("Adds “Use an emoji at the end of every response.” to your profile only during voice-to-voice.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Label("Voice-to-Voice Emojis", systemImage: "face.smiling")
                }

                Section {
                    ForEach(goalDrafts.indices, id: \.self) { index in
                        LimitedTextField(
                            title: "Goal \(index + 1)",
                            text: $goalDrafts[index],
                            limit: shortLimit,
                            autocapitalization: .sentences
                        )
                    }
                } header: {
                    Label("Current Goals", systemImage: "flag")
                } footer: {
                    Text("Up to three short goals. Keep each one to a single sentence.")
                }

                Section {
                    ForEach(behaviorDrafts.indices, id: \.self) { index in
                        LimitedTextField(
                            title: "Behavior \(index + 1)",
                            text: $behaviorDrafts[index],
                            limit: shortLimit,
                            autocapitalization: .sentences
                        )
                    }
                } header: {
                    Label("Important Behavior", systemImage: "slider.horizontal.3")
                } footer: {
                    Text("Use these for stable preferences like directness, brevity, or when Dominus should ask before assuming.")
                }

                Section {
                    Label(
                        "This profile is always added to prompts. Keep it short and do not include secrets, hidden commands, or dangerous instructions.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.callout)
                    .foregroundStyle(.orange)

                    Label(
                        "Dominus is a local AI tool. Use it as support, not as a replacement for professional help, judgment, relationships, or real-world safety decisions.",
                        systemImage: "info.circle"
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                } header: {
                    Text("Important")
                }

                if hasProfileContent {
                    Section {
                        Button(role: .destructive) {
                            clearDrafts()
                            store.deleteAll()
                            store.persona = ""
                        } label: {
                            Label("Clear profile", systemImage: "trash")
                        }
                    }
                }
            }
            .navigationTitle("Profile & Preferences")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        save()
                        dismiss()
                    }
                }
            }
            .onAppear(perform: loadDrafts)
        }
    }

    private var hasProfileContent: Bool {
        !displayNameDraft.trimmed.isEmpty
            || !jobTitleDraft.trimmed.isEmpty
            || !appPurposeDraft.trimmed.isEmpty
            || !personaDraft.trimmed.isEmpty
            || goalDrafts.contains { !$0.trimmed.isEmpty }
            || behaviorDrafts.contains { !$0.trimmed.isEmpty }
    }

    private func loadDrafts() {
        displayNameDraft = store.displayName
        appPurposeDraft = store.appPurpose
        personaDraft = store.persona
        jobTitleDraft = store.jobTitle
        goalDrafts = padded(store.goals, count: 3)
        behaviorDrafts = padded(store.behaviorNotes, count: 3)
        voiceEmojisDraft = store.voiceEmojisEnabled
    }

    private func save() {
        store.updateDisplayName(limited(displayNameDraft, nameLimit))
        store.updateJobTitle(limited(jobTitleDraft, shortLimit))
        store.updateAppPurpose(limited(appPurposeDraft, purposeLimit))
        store.persona = limited(personaDraft, personaLimit)
        store.updateGoals(goalDrafts.map { limited($0, shortLimit) })
        store.updateBehaviorNotes(behaviorDrafts.map { limited($0, shortLimit) })
        store.voiceEmojisEnabled = voiceEmojisDraft
    }

    private func clearDrafts() {
        displayNameDraft = ""
        appPurposeDraft = ""
        personaDraft = ""
        jobTitleDraft = ""
        goalDrafts = Array(repeating: "", count: 3)
        behaviorDrafts = Array(repeating: "", count: 3)
    }

    private func padded(_ values: [String], count: Int) -> [String] {
        Array((values + Array(repeating: "", count: count)).prefix(count))
    }

    private func limited(_ text: String, _ limit: Int) -> String {
        String(text.trimmed.prefix(limit))
    }
}

private struct LimitedTextField: View {
    let title: String
    @Binding var text: String
    let limit: Int
    var autocapitalization: TextInputAutocapitalization = .sentences

    var body: some View {
        TextField(title, text: $text)
            .textInputAutocapitalization(autocapitalization)
            .autocorrectionDisabled()
            .onChange(of: text) { _ in
                if text.count > limit {
                    text = String(text.prefix(limit))
                }
            }
    }
}

private struct LimitedTextEditor: View {
    @Binding var text: String
    let placeholder: String
    let limit: Int
    let minHeight: CGFloat

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            ZStack(alignment: .topLeading) {
                if text.isEmpty {
                    Text(placeholder)
                        .foregroundStyle(.secondary)
                        .font(.callout)
                        .padding(.top, 8)
                        .padding(.leading, 4)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $text)
                    .font(.callout)
                    .frame(minHeight: minHeight)
                    .scrollContentBackground(.hidden)
                    .onChange(of: text) { _ in
                        if text.count > limit {
                            text = String(text.prefix(limit))
                        }
                    }
            }
            Text("\(text.count)/\(limit)")
                .font(.caption2)
                .foregroundStyle(text.count >= limit ? .orange : .secondary)
        }
    }
}

private extension String {
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
