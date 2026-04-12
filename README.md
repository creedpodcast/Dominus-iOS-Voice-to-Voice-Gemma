# Dominus — On-Device iOS Voice-to-Voice AI

Dominus is a fully local, privacy-first AI chat app for iPhone. No internet connection required. No data leaves your device. The model runs entirely on-device using llama.cpp.

---

## What it does

- **Voice-to-voice conversation** — speak to Dominus, it responds out loud
- **Text chat** — full keyboard input with streaming token-by-token responses
- **Long-term memory** — remembers past conversations using on-device semantic search
- **Multiple chat sessions** — create, rename, and delete conversation threads
- **Fully offline** — model inference, speech recognition, and text-to-speech all run locally

---

## How it thinks

Dominus is prompted to think like Socrates. It never just answers — it questions, challenges, and pushes the conversation deeper. It explores philosophy, religion, science, consciousness, and human nature without restriction. It disagrees when warranted and admits uncertainty honestly.

---

## Architecture

### Model
| Component | Details |
|---|---|
| LLM | Gemma 2B IT Q4_K_M (GGUF) |
| Inference engine | [SwiftLlama](https://github.com/pgorzelany/swift-llama-cpp) v1.2.0 (llama.cpp wrapper) |
| Context window | 2048 tokens |
| Batch size | 512 |
| GPU acceleration | Metal (on-device) |

### Voice
| Component | Details |
|---|---|
| Speech-to-Text | `SFSpeechRecognizer` + `AVAudioEngine` (Apple, on-device) |
| Text-to-Speech | `AVSpeechSynthesizer` (Apple, on-device, best available English voice) |
| Silence detection | Auto-stop after 0.9s of no new transcript — triggers send |
| Streaming TTS | Response is spoken in chunks as tokens arrive, not after full generation |

### Memory (RAG)
| Component | Details |
|---|---|
| Vector embeddings | `NLEmbedding.sentenceEmbedding` — Apple built-in 512-dim model |
| Similarity | vDSP cosine similarity (hardware-accelerated via Accelerate framework) |
| Storage | SQLite3 (system-provided `libsqlite3`, no third-party dependency) |
| Retrieval | Top-5 semantically relevant past exchanges injected into system prompt |
| Raw history | Last 4 turns kept in context (down from 12) — older turns live in RAG |

### Token budget per generation (approximate)
```
System prompt       ~20 tokens
RAG memory context  ~350 tokens  (5 retrieved exchanges)
Raw recent turns    ~400 tokens  (4 turns)
Response headroom   ~1,024 tokens
─────────────────────────────────
Total               ~1,794 / 2,048 tokens
```

---

## App structure

```
DominusApp/
├── DominusAppApp.swift          Entry point
├── ContentView.swift            UI — sidebar, chat view, input bar
├── ChatStore.swift              State manager — conversations, send(), RAG wiring
├── GemmaEngine.swift            LLM engine — model loading, streaming generation
├── SpeechManager.swift          TTS — AVSpeechSynthesizer queue
├── SpeechRecognitionManager.swift  STT — AVAudioEngine + SFSpeechRecognizer
├── LoadingView.swift            Model loading progress overlay
└── Memory/
    ├── MemoryEmbedder.swift     NLEmbedding vectorisation + vDSP cosine similarity
    ├── MemoryStore.swift        SQLite3 persistence layer
    └── MemoryRetriever.swift    remember() + retrieve() public interface
```

---

## UI features

- **Swipe left** on a chat → Delete
- **Swipe right** on a chat → Rename
- **Long-press** any chat → context menu (Rename / Delete)
- Chat title auto-generated from first user message (up to 7 words)
- Voice / Text toggle in the detail header
- New Chat button in the sidebar toolbar

---

## Device requirements

| Requirement | Details |
|---|---|
| Device | iPhone 13 Pro Max or newer recommended |
| RAM | 6 GB unified memory (model uses ~1.4 GB) |
| iOS | 17.0+ |
| Storage | ~1.5 GB for model file |

---

## Known constraints

- **TTS quality** — currently uses `AVSpeechSynthesizer`. A neural TTS model (e.g. Kokoro-82M) would sound more natural but requires ~1.6 GB additional RAM, which exceeds safe limits on a 6 GB device when combined with the LLM.
- **Context cutoffs** — partially mitigated by RAG + reduced raw history. Full fix requires a model with a larger native context window.
- **Cold start** — model takes ~10–15 seconds to load on first launch.

---

## Planned

- [ ] Upgrade to Gemma 3n E2B Q4_K_M (~3.4 GB, better quality, same device)
- [ ] WhisperKit for more accurate on-device STT
- [ ] Silero VAD for smarter silence detection
- [ ] User profile / persistent facts injected into system prompt
