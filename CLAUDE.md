# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**Dominus** is an iOS app — a fully on-device AI assistant built in SwiftUI. It runs a quantized Gemma 2B model locally via `SwiftLlama` (llama.cpp wrapper), has a voice-to-voice PTT mode, long-term RAG memory, and a user profile system. No API calls, no cloud — everything runs on device.

## Building

This is an Xcode project. Build and run via Xcode only — there are no CLI build commands. Open `DominusApp.xcodeproj`. The model file (`gemma-2-2b-it-Q4_K_M.gguf`) must be present in the bundle for inference to work.

## Architecture

### Data flow
`ContentView` → `ChatStore` → `GemmaEngine` → `SwiftLlama (LlamaService)`

- **`ChatStore`** is the single source of truth for conversations, generation state, and model loading. All UI binds to it. It owns the generation pipeline end-to-end.
- **`GemmaEngine`** wraps `LlamaService`. It holds a persistent `llama` instance (reused across turns for KV cache continuity) and streams tokens back to `ChatStore`.
- **`LlamaService`** (SwiftLlama package) — not modified directly.

### Context window strategy
Each generation builds the prompt as: `[system prompt + user profile + RAG memories] + [last N messages]`. `trimLLMHistory()` in `ChatStore` enforces the token budget. Key constants:
- `maxTurnsToKeep = 10` → 20 messages in the rolling window
- `maxTokenCount = 2048` in `GemmaEngine` — Gemma's practical on-device limit (thermal constraint)
- The `ContextRingView` in `ContentView` estimates token usage live (chars ÷ 4) and shows a green/yellow/red ring in the header

### Memory system (RAG)
Three files in `Memory/`:
- `MemoryStore` — SQLite-backed persistence via CoreData or flat JSON (stores content + embedding vectors)
- `MemoryEmbedder` — wraps Apple's `NLEmbedding` for semantic vectors; keyword fallback when unavailable
- `MemoryRetriever` — cosine similarity search (semantic) or word-overlap scoring (keyword fallback); top-5 results injected into every system prompt

### User profile
`ProfileStore` auto-extracts personal facts from user messages and injects them as a structured block at the top of every system prompt, before RAG memories.

### Voice pipeline
Three independent managers — they do not call each other:

| Class | Role |
|---|---|
| `SpeechRecognitionManager` | STT via `SFSpeechRecognizer`. Publishes `transcript`, `audioLevel`, `isListening`. Has VAD (amplitude monitor) for detecting user speech while AI talks. |
| `SpeechManager` | TTS via `AVSpeechSynthesizer`. Queued chunk-by-chunk playback. Fires `onAllSpeechFinished` when queue drains. |
| `VoiceOrbOverlay` / `VoiceOrb` | SwiftUI overlay shown during PTT. Three ripple rings + amplitude-reactive core. Defined in `VoiceOrb.swift`. |

PTT state machine lives in `ContentView` as `PTTState` enum: `.idle → .listening → .aiTalking → .listening → ...`

The audio session is owned by `SpeechRecognitionManager.setupVoiceSession()` using `.playAndRecord` / `.voiceChat` mode (echo cancellation). `SpeechManager` deliberately does NOT set its own audio session — it piggybacks on the existing one to prevent echo and choppy audio.

TTS is streamed sentence-by-sentence: `ChatStore._send()` buffers tokens until a sentence boundary or 80-char threshold, then calls `SpeechManager.enqueue()`.

### Known STT limitation
`SFSpeechRecognizer` with on-device recognition has a ~2-3 second silence timeout and a 60-second hard session cap enforced by iOS — these cannot be disabled. Multiple workarounds were attempted (prefix accumulation, session restart with transcript preservation) but the transcript still clears in some race conditions. **The planned fix is to replace `SFSpeechRecognizer` with WhisperKit** on the `feature/whisper-stt` branch. WhisperKit records raw audio continuously with `AVAudioEngine` and transcribes on-demand when the user taps send — no session timeouts.

## Branch Map

| Branch | Status | Purpose |
|---|---|---|
| `main` | ✅ Stable | Persistent KV cache, context ring, voice orb, 20-message rolling window |
| `feature/whisper-stt` | 🚧 In progress | Replace `SFSpeechRecognizer` with WhisperKit for session-free STT |
| `fix/voice-transcript-and-input-ux` | ⚠️ Abandoned | Multiple attempts to fix transcript clearing — did not fully resolve |
| `feature/persistent-kv-cache-main` | ✅ Merged | Origin of KV cache + context ring work |

## Key Constraints

- **Thermal**: 8192 token context caused noticeable heat. `maxTokenCount = 2048` is the practical on-device limit for Gemma 2B Q4_K_M.
- **KV cache**: `GemmaEngine.streamChat()` reuses `self.llama` across turns. SwiftLlama's `initializeCompletion()` detects shared token prefixes and skips reprocessing them. Do not revert to `freshLlama` per generation.
- **Audio session**: There is exactly one `AVAudioSession` active during voice mode. Do not call `setCategory` from `SpeechManager` — it will break echo cancellation and cause choppy TTS.
- **Main actor**: `ChatStore`, `GemmaEngine`, `SpeechRecognitionManager`, and `SpeechManager` are all `@MainActor`. Do not dispatch to background threads for UI state.

## Package Dependencies

- `swift-llama-cpp` v1.2.0 — `https://github.com/pgorzelany/swift-llama-cpp` (pinned in `Package.resolved`)
- WhisperKit — to be added via Xcode: **File → Add Package Dependencies** → `https://github.com/argmaxinc/WhisperKit`
