# Dominus — On-Device iOS Voice-to-Voice AI

Dominus is a fully local, privacy-first AI assistant for iPhone. No internet connection required. No data leaves your device. Everything — model inference, speech recognition, text-to-speech, and memory — runs entirely on-device.

---

## What It Does

Talk to an AI that talks back. Tap once to speak, tap again when done — the AI responds with text and voice simultaneously. Tap at any point while the AI is speaking to instantly cut it off and speak again. Fully manual, fully on-device, fully private.

---

## Current State

### Working
- **Push-to-talk (PTT) voice-to-voice conversation**
  - Tap mic → speak → tap again → AI responds with text + voice
  - Tap during AI response → instantly interrupts voice and generation, starts listening immediately
  - Animated pulse ring while recording, live transcript shown as you speak
  - TTS auto-enables during voice turns, restores your previous setting after
- **Full-screen loading splash on launch** — blocks interaction until both Gemma and Whisper are fully ready; shows live progress bars per component
- **In-use status indicators** — floating pill appears whenever the app is processing in the background (transcribing, thinking, generating)
- **WhisperKit on-device STT** — accurate Whisper-based transcription with live preview while recording
- **Male TTS voice** — prefers Evan (Enhanced), falls back to Reed, Nathan, Tom, etc.
- Text chat with Gemma 2B (streaming, token-by-token)
- RAG long-term memory (semantic search + keyword fallback)
- User profile with auto-extraction ("my name is X" → stored as fact)
- Multiple conversation threads (create, rename, delete, switch)
- Generation interrupt (send new message cancels current response)
- Stop button (cancel generation without sending)
- Echo cancellation via unified `voiceChat` audio session
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
  ↓ tap again
[transcribing] — "Transcribing your speech…" pill appears
  ↓ Whisper done
[AI talking] — "Thinking…" pill → then mic.fill icon (green) as TTS begins
  ↓ AI finishes naturally
[idle]
```

The same single button controls every step. No hold-to-talk. No automatic silence detection (manual = intentional).

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
| Text-to-Speech | `AVSpeechSynthesizer` (Apple Neural Engine, fully local) |
| TTS voice | Evan Enhanced (male, en-US) — falls back to best available |
| Input mode | Push-to-talk (manual start/stop) |
| Interrupt | Button tap stops generation + TTS instantly, restarts STT |
| Echo cancellation | `AVAudioSession` `.voiceChat` mode (built-in, no feedback loop) |
| Streaming TTS | Spoken in sentence-boundary chunks as tokens arrive |

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
| Storage | SwiftData (`ProfileFact` entity) |
| Injection | All known facts prepended to every system prompt |

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
    ├── ProfileStore.swift           Fact extraction, storage, and system prompt injection
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
