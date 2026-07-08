# CLAUDE.md

This file gives coding agents the current project assumptions for Dominus.

## Project Overview

Dominus is a SwiftUI iOS app for a fully local AI assistant. It runs a bundled Gemma 2 2B IT Q4_K_M GGUF model through `SwiftLlama`, uses a bundled WhisperKit base.en Core ML model for on-device STT, uses a bundled Silero VAD Core ML model for speech endpointing, speaks with Apple TTS through a custom `AVAudioEngine` path, and stores conversations, profile facts, and memory data locally. No component requires a network connection.

The current local Xcode project is the source of truth.

## Building

Build and run from Xcode only. Open:

```text
Dominus17ProMax.xcodeproj
```

There is no supported CLI build command for this repository.

Required app resources:

- `Dominus17ProMax/gemma-2-2b-it-Q4_K_M.gguf`
- `Dominus17ProMax/SileroVADModel.mlpackage`
- `Dominus17ProMax/openai_whisper_base_en.bundle/` (bundled WhisperKit model + tokenizer, loaded via `modelFolder:` — no network download)
- `Dominus17ProMax/SoundEffects/*.wav`
- Swift packages pinned by `Dominus17ProMax.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`

## Architecture

Main data flow:

```text
ContentView -> ChatStore -> GemmaEngine -> SwiftLlama / LlamaService
```

Voice flow:

```text
ContentView voice state
  -> WhisperManager records/transcribes
  -> SileroVAD detects speech activity
  -> ChatStore sends to Gemma
  -> SpeechManager speaks streamed TTS
  -> ContentView resumes listening after TTS/cue drain
```

Core responsibilities:

- `ContentView` owns the SwiftUI shell, sidebar, chat UI, push-to-talk state, voice auto-send endpointing, warmup, status pills, orb overlay, and user interaction.
- `ChatStore` is the single source of truth for conversations, generation state, prompt assembly, context trimming, current-chat memory, profile wiring, title generation, persistence, and cancellation.
- `GemmaEngine` owns the persistent `LlamaService` instance and streams from the bundled GGUF model.
- `WhisperManager` owns WhisperKit loading, AVAudioEngine recording, live/final transcription, adaptive raw-sound tracking, and VAD feeding.
- `SileroVAD` wraps the bundled Core ML model and scores 16 kHz `576`-sample chunks.
- `SpeechManager` owns TTS, sound effects, route-aware gain, queue drain, message playback, and the coordinated voice-mode audio session.

## Current Voice Endpointing

Do not treat all microphone activity as user speech. The current fix separates:

- `lastSpeechActivityAt`: real speech activity from Silero VAD.
- `lastSoundActivityAt`: raw sound over the adaptive noise floor.

`ContentView` waits for transcript stability, then checks VAD speech silence. Recent VAD speech blocks sending. Raw sound without VAD speech only gets a short grace period, then the app sends so background noise cannot hold the turn forever.

Important constants in `ContentView`:

- `defaultVoiceAutoSendDelay = 1.35`
- `fastVoiceAutoSendDelay = 0.95`
- `shortVoiceAutoSendDelay = 1.05`
- `sequenceVoiceAutoSendDelay = 1.65`
- `voiceSpeechSilenceRequirement = 0.95`
- `rawSoundOnlyMaxHoldSeconds = 0.9`
- `hardSendAfterContentSilenceSeconds = 3.0`
- `substantialGrowthWordThreshold = 2`

Continuing sequences such as counting or alphabet tests use the longer sequence delay.

## Context Strategy

`GemmaEngine` uses:

- `batchSize = 512`
- `maxTokenCount = 2048`
- `useGPU = true`

`ChatStore` currently uses:

- `maxTurnsToKeep = 3`
- `minTurnsToKeep = 2`
- `targetContextUsage = 0.10`
- `approximateContextTokenLimit = 2048`

Prompt shape:

```text
system identity
+ profile/persona
+ recent deterministic context
+ current-chat summary/memory when recall is requested
+ ambient context when relevant
+ recent raw turns
```

Current-chat memory retrieval is gated by recall-style prompts such as "earlier", "remember when", or "summarize this chat". Cross-chat long-term memory is not automatically injected into every prompt; stable cross-chat user context belongs in `ProfileStore`.

## Memory And Profile

- `MemoryStore` uses SwiftData with `DominusMemory.store`.
- `MemoryEmbedder` uses Apple's `NLEmbedding.sentenceEmbedding(for: .english)` with vDSP cosine similarity.
- `MemoryRetriever.retrieve()` currently returns current-chat context for prompt injection.
- `MemoryView` is the user-facing Memory Journal for long-term saved memories.
- `ProfileStore` stores stable user facts and persona instructions and injects them into every prompt.

## Audio Constraints

Voice mode depends on a coordinated `.playAndRecord` session with mode `.default` and options:

```swift
[.defaultToSpeaker, .allowBluetooth, .allowBluetoothA2DP]
```

Do not add casual `setCategory` or `setActive` calls in new audio code. Repeated session changes can cause route resets, volume HUD flashes, clipped cue tails, or broken turn timing.

`SpeechManager` uses `AVSpeechSynthesizer.write`, not `speak()`, so it can apply speaker-only gain and peak limiting through `AVAudioEngine`.

Voice selection rules (do not regress these):

- The app default voice is Daniel (en-GB), preinstalled on iOS and macOS. `AudioSettingsStore.defaultVoice()` upgrades to the best installed quality of Daniel automatically.
- The iOS build running on a Mac ("Designed for iPad" compatibility mode, `ProcessInfo.isiOSAppOnMac`) cannot render premium ("maui") voices — the OS logs `Invalid maui voice identifier` and silently substitutes a junk voice. `SpeechManager.isRenderableVoice` filters premium there, and the voice picker hides them.
- Any voice that produces zero audio buffers is session-blocklisted and the utterance retries once with the next usable voice (`handleUnrenderedUtterance`).
- Mic and TTS failures must stay user-visible: `WhisperManager.micErrorMessage` and `SpeechManager.audioErrorMessage` render as a warning status pill in `ContentView.activeStatus`. Do not add new print-only failure paths in the voice pipeline.
- The TTS text cleaner must never filter on `Unicode isEmoji` alone — ASCII digits 0-9 are classified as emoji (keycap sequences) and would be silently deleted from speech.

## Active Vs Archived Voice Code

Active STT is `WhisperManager` plus `SileroVAD`. The old SFSpeech recognizer lives under `Archive/SpeechRecognitionManager.swift` and is not the current app path.

## Key Constraints

- Keep the persistent `GemmaEngine.llama`; do not recreate the model per turn.
- Keep `ChatStore`, `GemmaEngine`, `WhisperManager`, and `SpeechManager` main-actor aligned unless the architecture is deliberately changed.
- Keep Silero VAD input at `576` samples at 16 kHz.
- Keep endpointing based on VAD speech activity plus bounded raw-noise grace, not transcript stability alone.
- Respect the 2048-token context budget unless thermal/performance testing supports a change.
- Build and run through Xcode.

## Repository Notes

- `Archive/` contains historical/reference code.
- `Build Stack Notes/` contains old architecture/build notes.
- `Packages/kokoro-swift/` is a local untracked Kokoro TTS experiment and is not referenced by the current Xcode project.
- Machine-generated files such as `.DS_Store`, Xcode `xcuserdata`, SwiftPM build folders, and the local `Packages/` experiment are ignored by the root `.gitignore`.
