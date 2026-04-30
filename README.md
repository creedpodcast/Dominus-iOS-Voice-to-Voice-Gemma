# Dominus — On-Device iOS Voice-to-Voice AI

Dominus is a fully local, privacy-first AI assistant for iPhone. No internet connection required. No data leaves your device. Everything — model inference, speech recognition, text-to-speech, and memory — runs entirely on-device.

---

## What It Does

Talk to an AI that talks back. Tap once to speak, then pause — after real words are transcribed and no new words arrive for 1.5 seconds, Dominus sends the message automatically and responds with text and voice simultaneously. Tap at any point while the AI is speaking to cut it off and speak again. Fully on-device, fully private.

---

## Current State

### Working
- **Push-to-talk (PTT) voice-to-voice conversation**
  - Tap mic → speak → pause for 1.5 seconds → AI responds with text + voice
  - Tap again while listening to manually send before the timer finishes
  - Tap during AI response → interrupts voice and generation, waits briefly for audio to drain, then starts listening again
  - Animated pulse ring while recording, live transcript shown as you speak
  - TTS auto-enables during voice turns, restores your previous setting after
- **Full-screen loading splash on launch** — blocks interaction until both Gemma and Whisper are fully ready; shows live progress bars per component
- **In-use status indicators** — floating pill appears whenever the app is processing in the background (transcribing, thinking, generating)
- **WhisperKit on-device STT** — accurate Whisper-based transcription with live preview while recording
- **Hidden ambient cue awareness** — Whisper non-speech markers such as `[coughing]`, `(keyboard typing)`, `[silence]`, and `[laughter]` are removed from the visible transcript/chat while still being tracked privately per conversation. Dominus can acknowledge them naturally with a 12-turn cooldown, answer later if asked what it heard, and check in after roughly one minute of silence.
- **Stable live voice transcript** — live preview keeps the best partial transcript during a recording, so a brief pause to think no longer erases previously transcribed words.
- **Transcript-based voice auto-send** — voice mode waits for actual visible words, resets the timer whenever more words appear, and sends automatically after 1.5 seconds of transcript silence.
- **Voice punctuation cleanup** — dictated words such as "period", "comma", and "question mark" are converted into punctuation pauses before voice text is sent or spoken aloud.
- **Male TTS voice** — prefers Evan (Enhanced), falls back to Reed, Nathan, Tom, etc.
- **Loud, clear voice output** — `.videoChat` audio session mode removes the automatic-gain-control ceiling that `.voiceChat` imposes; device volume rocker now controls the full range
- **Half-duplex voice with no echo** — orb stays green until *every* queued TTS sentence has fully drained from the speaker (350 ms hardware grace included), then flips to listening — the mic never picks up the AI's tail
- **Sentence-complete TTS chunking** — sentences fire to TTS the instant their punctuation lands, never mid-sentence; only true runaways (>300 chars) ever get cut
- **Per-message action bar on AI replies** — Copy (clipboard, ✓ flash confirms), Share (system share sheet), and Speaker button under every assistant bubble. Tap the speaker to hear any past response read aloud; tap it again to stop mid-playback. Speaker icon swaps to a stop icon while that specific message is playing so state is always visible.
- **Selectable bubble text** — long-press any message (user or AI) to select and copy partial text.
- **Input field auto-clears on send** — text field empties the moment the send button is tapped; no manual deletion required before typing the next message.
- **Larger action icons and context ring** — per-message action icons at 18 pt and the context usage ring at 40 × 40 pt for readability at any text size.
- Text chat with Gemma 2B (streaming, token-by-token)
- RAG long-term memory (semantic search + keyword fallback) — scoped per conversation (no cross-chat bleed)
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

Both bars animate a left-to-right fill with a live percentage. The app becomes interactive only when both hit 100%.

### During Use
A small floating pill appears at the top of the screen whenever the app is processing:

| State | Pill |
|---|---|
| User tapped send in voice mode | `waveform` · Transcribing your speech… |
| AI generating, TTS not started yet | `brain` · Thinking… |
| AI generating in text mode | `cpu` · Generating… |

The pill slides in from the top and disappears automatically when the operation completes.

### Background Return
If the app is foregrounded after a long background session and either model needs to reload, the splash screen reappears with live progress until ready.

---

## How Voice Works (PTT Flow)

```
[idle]
  ↓ tap mic
[listening]  — waveform icon (red) + animated pulse ring + live transcript
  ↓ 1.5 seconds with no new transcribed words, or tap again to send manually
[transcribing] — "Transcribing your speech…" pill appears
  ↓ Whisper done
[AI talking] — "Thinking…" pill → then mic.fill icon (green) as TTS begins
  ↓ AI finishes naturally
[listening]
```

The same single button controls every step. No hold-to-talk. Auto-send only starts after visible words have been transcribed, so silence or hidden ambient cues alone do not send a user message.

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

### Voice
| Component | Details |
|---|---|
| Speech-to-Text | WhisperKit (on-device Whisper base-English, ~145 MB) |
| Hidden ambient cues | Bracketed or parenthesized non-speech markers are stripped from visible text, stored as per-chat ambient events, and injected only as hidden context when relevant |
| Text-to-Speech | `AVSpeechSynthesizer.speak()` + delegate (Apple Neural Engine, fully local) |
| TTS voice | Evan Enhanced (male, en-US) — falls back to best available |
| Input mode | Push-to-talk start with transcript-based auto-send after 1.5 seconds of no new visible words |
| Silence handling | Ambient-only silence is stored silently unless the recording lasts about 60 seconds, then Dominus may briefly check in |
| Interrupt | Button tap stops generation + TTS immediately, then restarts STT after a short audio-drain grace period |
| Audio session | `AVAudioSession` `.videoChat` mode — keeps hardware echo cancellation, drops the AGC volume cap that `.voiceChat` applies |
| Half-duplex gating | `outstandingUtterances` counter tracks every queued sentence; mic engine stays off until counter hits zero + 350 ms hardware drain |
| Streaming TTS | Spoken sentence-by-sentence as tokens arrive — `preUtteranceDelay`/`postUtteranceDelay` set to 0 so Apple cross-fades sentences with no gap |

### Memory (RAG)
| Component | Details |
|---|---|
| Vector embeddings | `NLEmbedding.sentenceEmbedding` — Apple built-in 512-dim model |
| Similarity | vDSP cosine similarity (hardware-accelerated) |
| Storage | SwiftData (on-device persistence) |
| Retrieval | Top-5 semantically relevant past exchanges injected into system prompt |
| Raw history | Last 10 turns kept in context — older turns covered by RAG |

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
├── Memory/
│   ├── MemoryEmbedder.swift         NLEmbedding vectorisation + cosine similarity
│   ├── MemoryStore.swift            SwiftData persistence layer
│   └── MemoryRetriever.swift        remember() + retrieve() public interface
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
- **Live transcript delay** — WhisperKit live preview runs every 2.5 seconds; first preview requires at least 0.5s of audio. Final transcript on send is always complete.
