# Dominus — On-Device iOS Voice-to-Voice AI

Dominus is a fully local, privacy-first AI assistant for iPhone. No internet connection required. No data leaves your device. Everything — model inference, speech recognition, text-to-speech, and memory — runs entirely on-device.

---

## What It Does

Talk to an AI that talks back. Tap once to speak, then pause — after real words are transcribed and the transcript has been stable for 1.5 seconds, Dominus sends the message automatically and responds with text and voice simultaneously. Tap at any point while the AI is speaking to cut it off and speak again. Fully on-device, fully private.

---

## Current State

### Working
- **Push-to-talk (PTT) voice-to-voice conversation**
  - Tap mic → speak → transcript stable for 1.5 seconds → AI responds with text + voice
  - Mute button and ambient noise do not block auto-send — only transcript stability matters
  - Tap again while listening to manually send before the timer fires
  - Tap during AI response → interrupts voice and generation, waits briefly for audio to drain, then starts listening again
  - Full-screen black voice surface hides the chat title, chat log, transcript field, and input bar while the orb is active
  - Orb color reflects state: gray when idle, green while user speaks, red while AI speaks
  - Processing states appear as status pills on the black voice screen
  - TTS auto-enables during voice turns, restores your previous setting after
- **Grounded, human-feel responses**
  - System prompt instructs Dominus to answer only what was asked, admit uncertainty rather than guess, and match response length to question length
  - Short questions get short answers; longer questions get appropriately longer ones
  - Robotic openers ("Sure!", "Certainly!", "Of course!") are stripped automatically before text is displayed or spoken
  - Noise turns ("ok", "yeah", "uh huh") are filtered out of LLM history before inference so they don't inflate context or shift tone
- **Instant response start** — the first token always renders immediately when it arrives; subsequent tokens batch every 6 to keep the main thread free for typing and scrolling during generation. Thinking fillers are cancelled automatically if the model responds in under 1.5 seconds so they never talk over a fast answer.
- **Speculative RAG** — memory retrieval starts 300 ms after the user pauses typing, so by the time send is tapped the relevant memories are already loaded and generation begins without waiting for embedding lookup.
- **Haptic feedback** — medium tap on send (text and voice), light tap when the AI's first token arrives. Toggle on/off in Audio settings.
- **Pipeline pre-warming at launch** — all four cold-start costs (LLM inference graph, audio session, STT recognizer, TTS voice file, keyboard) are paid behind the loading screen in parallel; the app becomes interactive only when every component is ready
- **Full-screen loading splash on launch** — blocks interaction until both Gemma and Whisper are fully ready; shows live progress bars per component
- **Startup ready sound** — plays a bundled local sound effect once the loading screen finishes and both models are ready
- **Audio settings** — sidebar audio controls let the user adjust and test startup, voice-mode activation, voice-mode deactivation, AI voice-response volume, and voice-mode inactivity timeout independently
- **In-use status indicators** — floating pill appears whenever the app is processing in the background (transcribing, thinking, generating)
- **WhisperKit on-device STT** — accurate Whisper-based transcription with live preview while recording
- **Hidden ambient cue awareness** — Whisper non-speech markers such as `[coughing]`, `(keyboard typing)`, `[silence]`, and `[laughter]` are removed from the visible transcript/chat while still being tracked privately per conversation. Dominus can acknowledge them naturally with a 12-turn cooldown, answer later if asked what it heard, and check in after roughly one minute of silence.
- **Stable live voice transcript** — live preview keeps the best partial transcript during a recording, so a brief pause to think no longer erases previously transcribed words.
- **Voice punctuation cleanup** — dictated words such as "period", "comma", and "question mark" are converted into punctuation pauses before voice text is sent or spoken aloud.
- **Male TTS voice** — prefers Evan (Enhanced), falls back to Reed, Nathan, Tom, etc.
- **Loud, clear voice output** — `.videoChat` audio session mode removes the automatic-gain-control ceiling that `.voiceChat` imposes; device volume rocker now controls the full range
- **Bluetooth/AirPods voice routing** — voice mode supports Bluetooth and wired headphone output/input, handles headset mic sample-rate changes, and keeps TTS at a safer headphone volume
- **Headphone volume safety warning** — while voice mode is active, Dominus watches headphone/Bluetooth system volume and shows a persistent dismissible warning if volume is very high or very low
- **Half-duplex voice with no echo** — orb stays green until *every* queued TTS sentence has fully drained from the speaker (350 ms hardware grace included), then flips to listening — the mic never picks up the AI's tail
- **Sentence-complete TTS chunking** — sentences fire to TTS the instant their punctuation lands, never mid-sentence; only true runaways (>300 chars) ever get cut
- **Voice thinking fillers** — while Gemma is preparing a voice response, Dominus can speak short local filler phrases such as quick greetings, light thinking sounds, or deeper-thinking phrases without adding them to the LLM prompt or chat log
- **Smart voice idle timer** — inactivity only counts during true silence; the timer resets to zero while the user is speaking or while the AI is speaking, so neither side triggers an early exit
- **Voice inactivity check-in (once per session)** — if no user speech is detected for the configured timeout, Dominus speaks a single check-in ("Are you still there?") and then exits voice mode; the check-in never loops
- **Voice-mode entry/exit cues** — local sounds play during voice-mode entry and exit without blocking the first recording; voice mode exits after the selected listening-only inactivity timeout without renewed user activity
- **Per-message action bar on AI replies** — Copy (clipboard, ✓ flash confirms), Share (system share sheet), and Speaker button under every assistant bubble. Tap the speaker to hear any past response read aloud; tap it again to stop mid-playback. Speaker icon swaps to a stop icon while that specific message is playing so state is always visible.
- **Tappable context ring → inspector** — tap the context usage ring in the chat header to open a sheet showing every section of the assembled LLM context (system prompt, profile, rolling summary, memories, raw turns) with token counts; helps verify what Dominus actually sees each turn
- **Selectable bubble text** — long-press any message (user or AI) to select and copy partial text.
- **Input field auto-clears on send** — text field empties the moment the send button is tapped; no manual deletion required before typing the next message.
- **Larger action icons and context ring** — per-message action icons at 18 pt and the context usage ring at 40 × 40 pt for readability at any text size; the ring mirrors the same rolling prompt-trim estimate used before sending context to Gemma.
- **Cinematic response streaming** — text chat still streams from Gemma in real time, but assistant bubbles reveal response chunks with a soft blurred ghost/fade treatment instead of harsh token-by-token typing.
- **Stable response scroll behavior** — when a new assistant response starts, chat scrolls to the top of the AI bubble once, then stops following the reveal so the user can scroll freely while text unfolds.
- **Conversation compaction** — turns that age out of the 10-turn raw context window are summarised by a side-channel LLM call (temperature 0.3, max 400 chars). The rolling summary is appended to every system prompt so prior context is always reachable without burning the main token budget. Compaction runs only when the model is idle, never during active generation.
- **Memory Journal** — one editable long-term memory page where users can view, add, edit, delete, and summarize approved memories without separate memory titles
- **Memory suggestions** — Dominus can detect possible memories, show Yes/No controls, accept spoken/text confirmation, and show darkened "Added to Memory" / "Forgot Memory" status bubbles in the chat
- RAG long-term memory (semantic search + keyword fallback) — retrieves from the Memory Journal and current-chat summaries while filtering memory status bubbles out of the LLM prompt
- **Rich memory records** — saved memories track topics, entities, meaning signals, emotional tone, importance, recurrence, source IDs, and generated semantic context for less literal recall
- **Multiple memory embeddings** — each memory can carry literal, topical, emotional, preference, and identity/style vectors; retrieval uses the strongest matching meaning angle
- **Context-aware "remember this" flow** — deictic memory requests ask Gemma to summarize what should be remembered from recent turns, then show the interpreted memory as a Yes/No suggestion before journal storage
- **Diverse memory recall** — broad questions such as "what do you remember about me?" use category diversity, importance boosts, and recent-recall penalties so Dominus avoids repeating the same facts
- **Multi-signal memory retrieval** — scoring blends semantic, keyword, entity, topic, recency, profile, and active-conversation signals so retrieval reflects the user's profile and the live conversation, not just literal phrasing
- **Memory retrieval trace** — Memory Journal shows why recent memory candidates were retrieved, including semantic score, matched semantic aspect, keyword score, entity/topic/recency/profile/active-conversation boosts, importance boost, repetition penalty, final score, source, and category
- **AI-managed memory cleanup** — saved memories are first normalized into Creed-focused facts, then Gemma refines messy entries into concise third-person summaries in the background when the app is idle
- LLM-generated chat titles (after 5 user turns or on chat exit) and absolute-date timestamps in the sidebar
- User profile with auto-extraction ("my name is X" → stored as fact) **plus an editable Profile sheet** (person.circle button) for manual facts and a free-text "How should Dominus talk to you?" persona prompt
- Multiple conversation threads (create, rename, delete, switch)
- Generation interrupt (send new message cancels current response)
- Stop button (cancel generation without sending)
- Raw SwiftLlama generation errors are logged to Xcode instead of appearing as assistant chat bubbles
- Echo cancellation via `.videoChat` audio session (hardware AEC) + half-duplex software gating
- Llama artifact filtering (strips template tokens from output)

### Planned
- [ ] Context window increase (2048 → 4096)
- [ ] Memory retrieval clamping (prevent context overflow)
- [ ] Silero VAD for optional auto-send on silence
- [ ] Core ML TTS (custom voice via Neural Engine — no synthesis gaps)

---

## Loading System

Every component that requires time to initialize shows a dedicated progress indicator so the user always knows what the app is doing.

### App Launch
A full-screen splash covers the app until both models are ready:

| Bar | What it tracks |
|---|---|
| `cpu.fill` · Language Model | Gemma 2B Q4_K_M loading into memory via llama.cpp |
| `waveform` · Voice Recognition | WhisperKit base-English model loading (~145 MB) |

Both bars animate a left-to-right fill with a live percentage. The app becomes interactive only when both hit 100% **and** all four pipeline components (LLM inference graph, audio session, STT recognizer, TTS voice) have been pre-warmed in parallel.

### During Use
A small floating pill appears at the top of the screen whenever the app is processing:

| State | Pill |
|---|---|
| User tapped send in voice mode | `waveform` · Transcribing your speech… |
| AI generating, TTS not started yet | `brain` · Thinking… |
| AI generating in text mode | `cpu` · Generating… |

Voice mode may also speak a short local thinking filler while Gemma prepares the real response. These fillers are generated by Swift orchestration only; they are not part of the LLM prompt and are not saved into the chat log.

The pill slides in from the top and disappears automatically when the operation completes.

### Background Return
If the app is foregrounded after a long background session and either model needs to reload, the splash screen reappears with live progress until ready.

---

## How Voice Works (PTT Flow)

```
[idle]  — waveform icon (gray)
  ↓ tap
[listening]  — full-screen black voice surface + waveform icon (green)
  ↓ transcript stable for 1.5 seconds (unconditional), or tap again to send manually
[transcribing] — "Transcribing your speech…" pill appears
  ↓ Whisper done
[AI talking] — "Thinking…" pill → waveform icon (red) as TTS begins
  ↓ AI finishes naturally
[listening]  — waveform icon (green)
```

The same single button controls every step. No hold-to-talk. Auto-send fires after 2 seconds of transcript stability — mute state and ambient noise do not affect the timer. Empty recordings restart listening instead of returning to text mode.

---

## Architecture

### Model
| Component | Details |
|---|---|
| LLM | Gemma 2 2B IT Q4_K_M (GGUF) |
| Inference engine | [SwiftLlama](https://github.com/pgorzelany/swift-llama-cpp) v1.2.0 (llama.cpp wrapper) |
| Context window | 2048 tokens |
| Batch size | 512 |
| GPU acceleration | Metal (on-device) |
| Temperature | 0.7 (main chat) · 0.3–0.4 (side-channel: titles, summaries) |

### Response quality
| Behaviour | Details |
|---|---|
| Grounded system prompt | Dominus answers only what was asked; admits uncertainty rather than guessing; matches length to the question |
| Length cap | Response length is bounded by the user's input word count: ≤5 words → 200 chars, 6-15 → 500, 16-40 → 1200, >40 → uncapped |
| Robotic opener strip | Opening phrases like "Sure!", "Certainly!", "Of course!" are removed before text is shown or spoken |
| Noise turn filter | Low-signal turns ("ok", "yeah", "uh huh") are dropped from LLM history before inference |

### Voice
| Component | Details |
|---|---|
| Speech-to-Text | WhisperKit (on-device Whisper base-English, ~145 MB) |
| Hidden ambient cues | Bracketed or parenthesized non-speech markers are stripped from visible text, stored as per-chat ambient events, and injected only as hidden context when relevant |
| Text-to-Speech | `AVSpeechSynthesizer.speak()` + delegate (Apple Neural Engine, fully local) |
| TTS voice | Evan Enhanced (male, en-US) — falls back to best available |
| Input mode | Push-to-talk with auto-send after 1.5 seconds of transcript stability (mute/noise do not block) |
| Voice UI | Full-screen black orb surface while voice mode is active; orb is gray (idle), green (user speaking), red (AI speaking) |
| Thinking fillers | Local `ThinkingFillerManager` chooses restrained voice-only filler phrases based on greetings, short prompts, complex prompts, follow-ups, and long delays |
| Smart idle timer | 1-second ticker that only advances during true silence; resets to zero while the user or AI is speaking |
| Inactivity check-in | One check-in fires per voice session after the configured silence timeout; after speaking it, voice mode exits — no loop |
| Auto-exit | Voice mode exits automatically after the configured inactivity timeout plays the deactivation cue |
| Interrupt | Button tap stops generation + TTS immediately, then restarts STT after a short audio-drain grace period |
| Audio session | `AVAudioSession` `.videoChat` / `.voiceChat` voice routing with `.allowBluetooth`, `.allowBluetoothA2DP`, and `.defaultToSpeaker` so AirPods, Bluetooth headsets, wired headphones, and speaker routes work without per-device code |
| Bluetooth input stability | Mic taps use the active hardware input format and resample dynamically, preventing headset sample-rate changes (16-24 kHz vs 48 kHz) from crashing recording |
| Audio settings | Startup cue, voice-mode activation cue, voice-mode deactivation cue, AI voice response volume, and voice-mode inactivity timeout can each be adjusted in-app |
| Headphone safety | TTS volume is route-aware: user-controlled AI voice volume still keeps a lower app-level cap for headphones/Bluetooth, plus persistent high/low system-volume warnings during voice mode |
| Half-duplex gating | `outstandingUtterances` counter tracks every queued sentence; mic engine stays off until counter hits zero + 350 ms hardware drain |
| Streaming TTS | Spoken sentence-by-sentence as tokens arrive — `preUtteranceDelay`/`postUtteranceDelay` set to 0 so Apple cross-fades sentences with no gap |
| Haptic feedback | Medium tap on send (text and voice mode); light tap when AI's first token arrives. Respects user toggle in Audio settings. |

### Context management
| Component | Details |
|---|---|
| Rolling window | Latest 10 turns (20 messages) kept as raw history in every prompt |
| Conversation compaction | Turns that age out of the 10-turn window are summarised by a side-channel LLM call (temperature 0.3, max 400 chars); summary is injected into the system prompt as "Earlier in this conversation:" so prior context is always reachable without burning token budget |
| Compaction timing | Runs only when the model is idle (not generating); append-only so older summaries are never discarded |
| Dual storage | Compacted summaries are also written to RAG so retrieval can surface them when relevant |
| Context inspector | Tap the context ring in the chat header to see every assembled section (system prompt, profile, rolling summary, memories, raw turns) with token counts |
| Speculative RAG | Memory retrieval fires 300 ms after typing pauses so the result is ready before send; `_send()` uses the cache on an exact query match and skips retrieval entirely |
| Token batching | SwiftUI message re-render fires every 6 tokens to keep the main thread free; first token always renders immediately so the response feels instant |

### Memory Journal + RAG
| Component | Details |
|---|---|
| Vector embeddings | `NLEmbedding.sentenceEmbedding` — Apple built-in 512-dim model; memory records can store rich-context plus literal, topical, emotional, preference, and identity/style aspect embeddings |
| Similarity | vDSP cosine similarity (hardware-accelerated) |
| Storage | SwiftData (on-device persistence for memory records, metadata, and embeddings) |
| Memory Journal | Single user-facing long-term memory surface with editable description-first entries |
| Memory suggestions | Conversation-scoped candidates that can be accepted into the Memory Journal or dismissed; "remember this/that/it" asks Gemma to interpret recent turns before showing the suggestion |
| Retrieval | Memory Journal entries and current-chat summaries are scored, filtered, and injected only when relevant |
| Diverse recall | Broad/follow-up memory questions activate exploration mode, balancing semantic relevance with category diversity, importance, and recently-used-memory penalties |
| Recall history | Recently retrieved memory fingerprints are tracked locally in `UserDefaults` and downranked for a short window so repeated questions can surface different facts |
| Multi-signal scoring | Final score blends semantic, keyword, entity, topic, recency, profile, and active-conversation signals minus a repetition penalty, so retrieval considers who the user is and what's being discussed right now |
| Traceability | Memory Journal includes a retrieval trace with source, category, semantic score, matched semantic aspect, keyword score, entity/topic/recency/profile/active-conversation boosts, importance boost, repetition penalty, and final score |
| Normalization | Common first-person memory phrases are converted into Creed-focused facts before storage; idle Gemma refinement rewrites long or messy memories into compact third-person summaries |
| File memory groundwork | `MemoryScope.file` is reserved for future chunked file indexing: file → chunks → embeddings → searchable candidates |

### User Profile
| Component | Details |
|---|---|
| Auto-extraction | Pattern matching on user messages ("my name is X", "I live in Y", etc.) |
| Storage | SwiftData (`ProfileFact` entity) for facts; `UserDefaults` for persona |
| Manual editing | `ProfileView` sheet (person.circle button in sidebar) — add/delete facts, swipe to remove, "Clear all" |
| Persona | Free-text "How should Dominus talk to you?" field (e.g. "Be concise. Use analogies.") |
| Injection | Facts block + persona block both prepended to every system prompt |

---

## App Structure

```
DominusApp/
├── DominusAppApp.swift              Entry point
├── ContentView.swift                UI — sidebar, chat view, PTT input bar, status pills
├── ChatStore.swift                  State — conversations, send(), RAG + profile wiring
├── GemmaEngine.swift                LLM — model loading with progress, streaming generation
├── SpeechManager.swift              TTS — AVSpeechSynthesizer, male voice selection
├── SpeechRecognitionManager.swift   VAD — amplitude monitoring during AI speech
├── WhisperManager.swift             STT — WhisperKit on-device transcription with progress
├── LoadingView.swift                SplashLoadingView + LoadingBarView + StatusPillView
├── VoiceOrb.swift                   Animated voice orb overlay (PTT visual feedback)
├── ThinkingFillerManager.swift      Voice-only local filler orchestration while Gemma prepares responses
├── AudioSettingsStore.swift         Saved per-sound volume preferences
├── AudioSettingsView.swift          In-app audio sliders and preview buttons
├── SoundEffects/                    Bundled local UI audio, including the startup-ready sound
├── MemoryView.swift                 Memory Journal UI — suggested memories plus editable long-term entries
├── Memory/
│   ├── MemoryEmbedder.swift         NLEmbedding vectorisation + cosine similarity
│   ├── MemoryExtractor.swift        Deterministic memory extraction, categorization, and first-person normalization
│   ├── MemorySummaryBuilder.swift   Compact memory summaries for chat bubbles, manual entries, and conversation compaction
│   ├── MemoryStore.swift            SwiftData persistence, embeddings, and memory records
│   ├── MemoryTraceStore.swift       Observable retrieval trace for memory scoring/debug visibility
│   └── MemoryRetriever.swift        remember(), retrieve(), diverse scoring, recall history, candidate accept/delete interface
└── Profile/
    ├── ProfileStore.swift           Fact extraction, persona, storage, system prompt injection
    ├── ProfileView.swift            Editable profile sheet — facts list + persona text field
    └── UserProfile.swift            SwiftData ProfileFact entity
```

---

## Device Requirements

| Requirement | Details |
|---|---|
| Device | iPhone 13 Pro Max or newer recommended |
| RAM | 6 GB unified memory (model uses ~1.5 GB + KV cache) |
| iOS | 17.0+ |
| Storage | ~1.5 GB for Gemma model + ~150 MB for Whisper model |

---

## Known Issues

- **Context window** — 2048 tokens can overflow when system prompt + profile + memories + history are large. Fix: increase to 4096.
- **STT 1-minute OS limit** — Apple's `SFSpeechRecognizer` (used for VAD only) auto-cancels after ~60 seconds. Does not affect WhisperKit transcription.
- **Live transcript delay** — WhisperKit live preview runs every second; first preview requires at least 0.5s of audio. Final transcript on send is always complete.
