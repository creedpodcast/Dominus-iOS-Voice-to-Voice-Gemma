# Dominus — On-Device iOS AI Assistant

Dominus is a fully local, privacy-first AI assistant for iPhone. No internet connection required. No data leaves your device. Everything — model inference, speech recognition, text-to-speech, and memory — runs entirely on-device.

---

## Current State (Foundation Build)

This branch represents the stable foundation of the project. Text chat with long-term memory and user profile is fully working. Voice mode is next to be rebuilt using industry-standard architecture.

### Working
- Text chat with Gemma 2B (streaming, token-by-token)
- RAG long-term memory (semantic search + keyword fallback)
- User profile with auto-extraction ("my name is X" → stored as fact)
- Multiple conversation threads (create, rename, delete, switch)
- Generation interrupt (send new message cancels current response)
- Stop button (cancel generation without sending)
- Llama artifact filtering (strips template tokens from output)

### Planned (to be built on feature branches)
- [ ] Hands-free voice-to-voice conversation mode
- [ ] VAD (Voice Activity Detection) for barge-in / interrupting AI mid-sentence
- [ ] Echo cancellation via unified audio session
- [ ] Pre-roll audio buffer for syllable-safe STT handoff
- [ ] Persistent LlamaService (fix Metal memory churn)
- [ ] Context window increase (2048 → 4096)
- [ ] Memory retrieval clamping (prevent context overflow)
- [ ] WhisperKit for more accurate on-device STT
- [ ] Silero VAD for smarter silence detection

---

## Architecture

### Model
| Component | Details |
|---|---|
| LLM | Gemma 2 2B IT Q4_K_M (GGUF) |
| Inference engine | [SwiftLlama](https://github.com/pgorzelany/swift-llama-cpp) v1.2.0 (llama.cpp wrapper) |
| Context window | 2048 tokens (to be increased to 4096) |
| Batch size | 512 |
| GPU acceleration | Metal (on-device) |

### Voice (basic — rebuild planned)
| Component | Details |
|---|---|
| Speech-to-Text | `SFSpeechRecognizer` + `AVAudioEngine` (Apple, on-device) |
| Text-to-Speech | `AVSpeechSynthesizer` (Apple, on-device, best available English voice) |
| Silence detection | Auto-stop after 0.9s of no new transcript |
| Streaming TTS | Response spoken in chunks as tokens arrive |

### Memory (RAG)
| Component | Details |
|---|---|
| Vector embeddings | `NLEmbedding.sentenceEmbedding` — Apple built-in 512-dim model |
| Similarity | vDSP cosine similarity (hardware-accelerated via Accelerate framework) |
| Storage | SwiftData (on-device persistence) |
| Retrieval | Top-5 semantically relevant past exchanges injected into system prompt |
| Raw history | Last 4 turns kept in context — older turns covered by RAG |

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
├── ContentView.swift                UI — sidebar, chat view, input bar
├── ChatStore.swift                  State — conversations, send(), RAG + profile wiring
├── GemmaEngine.swift                LLM — model loading, streaming generation
├── SpeechManager.swift              TTS — AVSpeechSynthesizer queue
├── SpeechRecognitionManager.swift   STT — AVAudioEngine + SFSpeechRecognizer
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
| Storage | ~1.5 GB for model file |

---

## Known Issues (to be fixed)

- **Fresh LlamaService per generation** — creates a new llama.cpp context every turn, churning Metal GPU memory. Causes crashes after ~10 turns. Fix: use persistent LlamaService.
- **Context window too small** — 2048 tokens overflows when system prompt + profile + memories + history exceed ceiling. Fix: increase to 4096.
- **Memory retrieval unclamped** — top-5 full exchanges with no character limit can push 1000+ tokens into system prompt. Fix: clamp to top-3 at 400 chars each.
- **Voice mode primitive** — no hands-free loop, no VAD, no echo cancellation. Needs full rebuild.
