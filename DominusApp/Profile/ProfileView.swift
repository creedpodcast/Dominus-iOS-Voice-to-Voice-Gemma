import SwiftUI

struct ProfileView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var store = ProfileStore.shared

    // Editing state for adding a new fact
    @State private var newKey   = ""
    @State private var newValue = ""
    @State private var showAddFact = false

    // Local mirror of persona so edits are applied on dismissal
    @State private var personaDraft = ""

    var body: some View {
        NavigationStack {
            List {
                // ── Persona section ────────────────────────────────────────
                Section {
                    ZStack(alignment: .topLeading) {
                        if personaDraft.isEmpty {
                            Text("e.g. Be concise. Use casual language. Explain things with analogies.")
                                .foregroundStyle(.secondary)
                                .font(.callout)
                                .padding(.top, 8)
                                .padding(.leading, 4)
                                .allowsHitTesting(false)
                        }
                        TextEditor(text: $personaDraft)
                            .font(.callout)
                            .frame(minHeight: 100)
                            .scrollContentBackground(.hidden)
                    }
                } header: {
                    Label("How should Dominus talk to you?", systemImage: "bubble.left.and.bubble.right")
                } footer: {
                    Text("This is injected into every system prompt. Keep it short — it counts against the context window.")
                        .font(.caption)
                }

                // ── Known facts section ────────────────────────────────────
                Section {
                    if store.facts.isEmpty {
                        Text("No facts yet. Dominus learns them automatically from conversation, or you can add them below.")
                            .foregroundStyle(.secondary)
                            .font(.callout)
                    } else {
                        ForEach(store.facts) { fact in
                            HStack(alignment: .top, spacing: 8) {
                                Text(fact.key)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 110, alignment: .leading)
                                Text(fact.value)
                                    .font(.callout)
                            }
                        }
                        .onDelete { offsets in
                            offsets.forEach { store.delete(store.facts[$0]) }
                        }
                    }
                } header: {
                    HStack {
                        Label("What Dominus knows about you", systemImage: "person.text.rectangle")
                        Spacer()
                        Button {
                            showAddFact = true
                        } label: {
                            Image(systemName: "plus")
                        }
                        .font(.callout)
                    }
                } footer: {
                    Text("Swipe left to delete a fact.")
                        .font(.caption)
                }

                // ── Danger zone ────────────────────────────────────────────
                if !store.facts.isEmpty {
                    Section {
                        Button(role: .destructive) {
                            store.deleteAll()
                        } label: {
                            Label("Clear all facts", systemImage: "trash")
                        }
                    }
                }
            }
            .navigationTitle("Your Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        store.persona = personaDraft
                        dismiss()
                    }
                }
            }
            .onAppear {
                personaDraft = store.persona
            }
            .sheet(isPresented: $showAddFact) {
                AddFactSheet(store: store)
                    .presentationDetents([.medium])
            }
        }
    }
}

// MARK: - Add Fact Sheet

private struct AddFactSheet: View {
    @Environment(\.dismiss) private var dismiss
    var store: ProfileStore

    @State private var key   = ""
    @State private var value = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Label (e.g. \"name\", \"occupation\")") {
                    TextField("Label", text: $key)
                        .autocorrectionDisabled()
                }
                Section("Value") {
                    TextField("Value", text: $value)
                }
            }
            .navigationTitle("Add Fact")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
                        let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !k.isEmpty && !v.isEmpty {
                            store.upsert(key: k, value: v)
                        }
                        dismiss()
                    }
                    .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                              value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}
