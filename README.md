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
- **WhisperKit on-device STT** — more accurate transcription via Whisper model
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
- [ ] Persistent LlamaService (fix Metal memory churn between turns)
- [ ] Context window increase (2048 → 4096)
- [ ] Memory retrieval clamping (prevent context overflow)
- [ ] Silero VAD for optional auto-send on silence
- [ ] Core ML TTS (custom voice via Neural Engine — no synthesis gaps)

---

## How Voice Works (PTT Flow)

```
[idle]
  ↓ tap mic
[listening]  — waveform icon (red) + animated pulse ring
  ↓ tap again
[AI talking] — mic.fill icon (green) — tap anytime to interrupt
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
| Speech-to-Text | WhisperKit (on-device Whisper model, high accuracy) |
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
├── ContentView.swift                UI — sidebar, chat view, PTT input bar
├── ChatStore.swift                  State — conversations, send(), RAG + profile wiring
├── GemmaEngine.swift                LLM — model loading, streaming generation
├── SpeechManager.swift              TTS — AVSpeechSynthesizer, male voice selection
├── SpeechRecognitionManager.swift   STT — AVAudioEngine + SFSpeechRecognizer + VAD
├── WhisperManager.swift             STT — WhisperKit on-device Whisper transcription
├── LoadingView.swift                Model loading progress overlay
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

- **Fresh LlamaService per generation** — creates a new llama.cpp context every turn, churning Metal GPU memory. Can cause instability after many turns. Fix: persistent LlamaService.
- **Context window** — 2048 tokens can overflow when system prompt + profile + memories + history are large. Fix: increase to 4096.
- **STT 1-minute OS limit** — Apple's `SFSpeechRecognizer` auto-cancels after ~60 seconds of continuous listening. PTT resets gracefully when this happens.
