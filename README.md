# Dominus

Dominus is a local-first SwiftUI assistant. It runs a quantized Gemma 2B model through SwiftLlama, records and transcribes voice with WhisperKit, uses a bundled Silero VAD Core ML model for speech endpointing, speaks through an Apple TTS audio pipeline, and stores conversations, profile facts, and memory data on device.

It targets iPhone first and the same codebase also builds and runs on Apple Silicon Macs through Mac Catalyst.

The current local Xcode project is the source of truth for this document.

## Current State

Dominus currently supports:

- On-device chat with streaming Gemma responses.
- Push-to-talk voice-to-voice mode with automatic send after the user stops speaking.
- WhisperKit live transcript preview and final transcription.
- Silero VAD speech detection layered over raw microphone activity.
- Background-noise tolerance so room noise does not hold the turn forever.
- Sequence-aware endpointing so counting, alphabet tests, and long utterances are less likely to be cut off.
- Sentence-by-sentence TTS while the model streams.
- High-gain speaker TTS through `AVSpeechSynthesizer.write`, `AVAudioEngine`, vDSP gain, and a peak limiter.
- Route-aware voice volume for speaker, headphones, AirPods, Bluetooth, CarPlay, and AirPlay.
- A full-screen voice orb with mic/TTS amplitude, emoji display, idle faces, and inactivity states.
- Conversation threads with create, rename, delete, switch, generated titles, and local disk persistence.
- A context ring and context inspector showing the assembled model prompt.
- User profile facts and persona instructions injected into every prompt.
- A Memory Journal for long-term saved memories, plus current-chat recall and memory traces.
- Local startup, voice-entry, voice-exit, user-finished, and AI-finished sound effects.
- Audio settings for sound volumes, haptics, voice selection, speech rate, speech pitch, inactivity timeout, and orb appearance.

## Privacy Model

Runtime inference is local. Gemma, Whisper transcription, Silero VAD, Apple TTS, profile storage, conversation storage, and memory storage all run on the device.

Network access can still be needed during development or first setup for Swift Package resolution and for any model assets WhisperKit needs to fetch/cache. Once assets are present, the app logic is designed around on-device execution rather than cloud APIs.

## Platforms And Mac Catalyst

Dominus builds for two destinations from one codebase:

- iPhone (primary).
- Apple Silicon Mac via Mac Catalyst.

Cross-platform handling lives behind compile-time guards so the iPhone path is unchanged:

- `#if canImport(UIKit)` / `#else import AppKit` bridges. A `PlatformImage` typealias maps to `UIImage` on iOS and `NSImage` on macOS for orb glyph rasterisation, and color component extraction falls back from `UIColor` to `NSColor`.
- `#if !targetEnvironment(macCatalyst)` guards around iOS-only audio behavior. On Catalyst the voice-mode `AVAudioSession` is configured without the iOS-only `.defaultToSpeaker` / `.allowBluetooth*` options, protected-route volume capping is skipped, and `UIImpactFeedbackGenerator` haptics compile out.
- macOS microphone access is requested explicitly. Unlike iOS, starting the audio engine on Mac does not reliably trigger the permission prompt, so `WhisperManager` checks `AVAudioApplication.shared.recordPermission`, prompts when undetermined, retries once granted, and bails cleanly if denied. It also guards against the macOS input format reporting `0 Hz / 0 channels` before a device/permission is bound, which would otherwise crash Core Audio on tap install.
- `Dominus17ProMax/Dominus17ProMax.entitlements` enables `com.apple.security.device.audio-input` for the sandboxed Mac app.

The bundled `llama.xcframework` ships iOS and macOS slices but not a Mac Catalyst slice, so a build-time patch adds one by reusing the macOS slice. `Scripts/patch_llama_xcframework.sh` is intended as a pre-build Run Script phase (above Compile Sources, with "Based on dependency analysis" unchecked) and is idempotent — it no-ops once the framework is already patched.

## Build And Run

Open the Xcode project:

```text
Dominus17ProMax.xcodeproj
```

Build and run from Xcode. This repository is not set up with a supported CLI build flow.

For the Mac Catalyst destination, add `Scripts/patch_llama_xcframework.sh` as a pre-build Run Script phase (see the Mac Catalyst section above) so the `llama.xcframework` gains a Catalyst slice before Compile Sources.

Required local app resources:

- `Dominus17ProMax/gemma-2-2b-it-Q4_K_M.gguf` - Gemma 2 2B IT Q4_K_M model, about 1.6 GB (tracked via Git LFS).
- `Dominus17ProMax/SileroVADModel.mlpackage` - bundled Core ML VAD model.
- `Dominus17ProMax/SoundEffects/*.wav` - local cue sounds.
- `Dominus17ProMax/Dominus17ProMax.entitlements` - app entitlements (microphone/audio input).
- Swift packages from `Package.resolved`.

The Xcode project uses a file-system synchronized app group for `Dominus17ProMax/`, so source and resource files in that folder are picked up by the project without hand-maintaining every file entry in `project.pbxproj`.

## Package Pins

`Dominus17ProMax.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` currently pins:

| Package | Source | Version / Revision |
|---|---|---|
| `swift-llama-cpp` | `https://github.com/pgorzelany/swift-llama-cpp` | `1.2.0`, revision `5496bc7c9820f04bba7268dc8a271235deae436d` |
| `WhisperKit` | `https://github.com/argmaxinc/WhisperKit` | branch `main`, revision `80d96762fa727f816ffceab76a6529cd12c2726f` |
| `swift-argument-parser` | `https://github.com/apple/swift-argument-parser.git` | `1.7.1`, transitive |

Key Xcode settings:

- Bundle identifier: `com.creed.dominus1`.
- Deployment target in the project file: `26.5`.
- Default actor isolation: `MainActor`.
- Microphone usage description is configured.
- Speech recognition usage description remains configured, though active STT is WhisperKit rather than the old SFSpeech path.

## Runtime Architecture

Main data flow:

```text
ContentView
  -> ChatStore
  -> GemmaEngine
  -> SwiftLlama / LlamaService
```

Voice flow:

```text
ContentView voice state
  -> WhisperManager records and transcribes
  -> SileroVAD classifies speech activity
  -> ChatStore sends the turn to Gemma
  -> SpeechManager speaks streamed response chunks
  -> ContentView returns to listening when TTS and cue audio drain
```

Core roles:

- `ContentView` owns the visible app workflow: sidebar, chat, input, push-to-talk state, voice auto-send, warmup, overlays, status pills, and voice-mode routing.
- `ChatStore` is the conversation source of truth. It owns send/cancel, prompt assembly, response streaming, title generation, context trimming, memory wiring, profile wiring, and disk persistence.
- `GemmaEngine` wraps a persistent `LlamaService` instance and streams tokens from the bundled GGUF model.
- `WhisperManager` owns AVAudioEngine recording, live transcript passes, final transcription, raw sound activity, adaptive noise floor, and Silero VAD feeding.
- `SileroVAD` wraps the bundled Core ML model and tracks recurrent VAD state.
- `SpeechManager` owns TTS, route-aware gain, sound effects, voice selection, queue drain, and the shared audio engine used by speech and cue sounds.

## Voice Endpointing

The current voice fix is a middle ground between two bad extremes:

- Sending too early while the user is still talking.
- Never sending because the mic keeps hearing background noise.

Dominus solves this by separating speech from sound.

`WhisperManager` publishes:

- `lastSpeechActivityAt` from Silero VAD. This means actual likely speech.
- `lastSoundActivityAt` from raw microphone level over an adaptive noise floor. This means something audible happened, but not necessarily speech.
- `audioLevel` for orb animation.
- `transcript` for live preview.

`ContentView` auto-send uses:

| Constant | Value | Purpose |
|---|---:|---|
| `defaultVoiceAutoSendDelay` | `1.35s` | Normal transcript-stability delay. |
| `fastVoiceAutoSendDelay` | `0.95s` | Faster send when punctuation suggests a clear ending. |
| `shortVoiceAutoSendDelay` | `1.05s` | Short prompt / empty visible transcript delay. |
| `sequenceVoiceAutoSendDelay` | `1.65s` | Longer delay for alphabet/counting/continuing sequences. |
| `voiceSpeechSilenceRequirement` | `0.95s` | Required silence after real VAD speech. |
| `rawSoundOnlyMaxHoldSeconds` | `0.9s` | Maximum hold for raw noise that Silero does not classify as speech. |
| `hardSendAfterContentSilenceSeconds` | `3.0s` | Forces send when content exists but Whisper keeps trickling tiny noise changes. |
| `substantialGrowthWordThreshold` | `2 words` | Marks real transcript growth versus one-word hallucination noise. |

How send is decided:

1. Wait for the visible transcript to stop changing for the adaptive delay.
2. If Silero VAD saw recent speech, wait only the remaining required speech silence.
3. If there is only raw noise, hold briefly.
4. If raw noise keeps happening without VAD speech, ignore it and send.
5. If the transcript still grows by meaningful chunks, restart the timer.
6. If it only jitters with tiny changes for too long after real content, hard-send.

This is the practical middle ground used by mature voice systems: endpoint on speech activity, not microphone activity, while keeping a bounded grace window for uncertain audio.

## Whisper And VAD

`WhisperManager`:

- Loads `WhisperKit(model: "openai_whisper-base.en")`.
- Uses `DecodingOptions(noSpeechThreshold: 0.7, chunkingStrategy: .vad)`.
- Starts an AVAudioEngine input tap with the active hardware format.
- Keeps raw samples for final transcription.
- Runs live transcription every `1.0s` while recording.
- Resamples audio to 16 kHz mono for Whisper.
- Preserves the best live transcript so brief pauses do not erase the preview.
- Offers `stopAndTranscribe()` for final transcription and `stopRecordingWithoutTranscribing()` for fast/manual paths.

`SileroVAD`:

- Loads `SileroVADModel.mlpackage`.
- Uses Core ML compute units `.all`.
- Scores 16 kHz chunks of `576` samples.
- Keeps LSTM state tensors between chunks.
- Uses a speech threshold of `0.5`.

The `576` sample size matters. The bundled model expects `1 x 576`; feeding `512` samples makes VAD scoring fail and breaks endpointing.

## Audio And TTS

`SpeechManager` uses a high-gain local TTS pipeline:

```text
AVSpeechSynthesizer.write
  -> PCM buffers
  -> vDSP gain when using built-in speaker
  -> AVAudioPlayerNode
  -> peak limiter
  -> output
```

Current behavior:

- Voice mode locks the audio session to `.playAndRecord`, mode `.default`.
- Session options are `.defaultToSpeaker`, `.allowBluetooth`, and `.allowBluetoothA2DP`.
- The same audio engine plays TTS and sound effects, avoiding competing hardware activations.
- Speaker output gets the boosted TTS path.
- Private listening routes bypass the extra gain and keep safer volume behavior.
- `outstandingUtterances` tracks queued speech.
- `onAllSpeechFinished` fires only after queued speech drains.
- AI-finished cue audio can wait for full duration so the mic does not capture its tail.

Do not casually add separate `setCategory` or `setActive` calls from new audio code. Repeated session changes can cause volume HUD flashes, route resets, clipped tails, or broken voice-mode timing.

Default audio/orb settings:

| Setting | Default |
|---|---:|
| Startup sound | `5%` |
| Voice mode activation | `7%` |
| Voice mode deactivation | `3%` |
| User message sent | `8%` |
| AI reply finished | `14%` |
| AI voice | `Zoe (Premium)` when installed |
| AI voice response | `50%` |
| AI voice speed | `44%` |
| AI voice pitch | `1.05x` |
| Voice activity timeout | `1 min` |
| Orb size | `174%` |
| Halftone dots | white |
| Halftone density | `100%` |
| Emoji size | `80%` |

Protected routes such as headphones, AirPods, Bluetooth, car audio, and AirPlay never receive the boosted speaker path. Their TTS and sound-effect volume is scaled inside a safe app-level cap, while still respecting the user's in-app volume sliders.

## Push-To-Talk State Machine

The core state enum in `ContentView` is:

```text
idle -> listening -> aiTalking -> listening
```

User controls:

- Tap while idle: enter voice mode.
- Tap while listening: send manually.
- Tap while AI is talking: interrupt generation/TTS and restart listening after a short drain.
- Mute/exit controls stop recording and return to text mode.

Voice mode also includes:

- Entry and return greetings from `VoiceModeGreetings`.
- One voice inactivity check-in per session.
- True-silence idle timer that pauses while the user or AI is speaking.
- Headphone volume warnings.
- Orb emoji clearing and idle/sleep states.

Voice latency fillers exist in `ThinkingFillerManager`, but current latency testing disables them with `voiceLatencyTestingDisablesFillers = true` in the active flow.

## Generation Pipeline

`ChatStore._send()` does the main work:

1. Cleans ambient cue markers and visible user text.
2. Appends the user message.
3. Handles memory undo phrases like "forget that".
4. Builds profile context from `ProfileStore` (always injected; protected from trimming).
5. Runs current-chat retrieval when the message looks like recall; for positional/ordinal recall also builds a verbatim transcript slice.
6. Adds recent context cache, a grounding instruction + recall context, and ambient context. The unbounded rolling summary is no longer injected.
7. Filters low-signal turns.
8. Applies the structural recency cap, then enforces the real token budget via `fitToContext` so prompt + reply never exceed n_ctx.
9. Captures a context snapshot for the inspector.
10. Streams Gemma tokens.
11. Renders the first token immediately, then batches UI updates every 4 tokens.
12. Sends complete TTS sentences as they arrive.
13. Stores the exchange into current-chat memory.
14. Schedules title generation and memory maintenance when appropriate.

Gemma settings:

| Setting | Current Value |
|---|---:|
| Model resource | `gemma-2-2b-it-Q4_K_M.gguf` |
| Engine | SwiftLlama / llama.cpp |
| Batch size | `512` |
| Context window (n_ctx) | `4096` |
| Generation reserve | `1024` tokens |
| GPU | `true` |
| Main chat temperature | `0.7` |
| Main chat seed | `42` |
| Side-channel temperature | usually `0.3` to `0.4` |

Response length is softly capped by prompt size:

| User input length | Soft response cap |
|---|---:|
| 0-5 words | `200` chars |
| 6-15 words | `500` chars |
| 16-40 words | `1200` chars |
| 41+ words | uncapped |

The cap only stops at a sentence boundary, so normal responses are not cut mid-word.

## Context Strategy

The context window is `n_ctx = 4096`, with `1024` tokens reserved for the reply,
leaving a roughly `3072`-token prompt budget. The assembled prompt is measured
with a conservative character-based token estimate and is hard-clamped to that
budget before generation, so prompt + reply can never exceed the window (the
cause of the prior `LlamaError error 1` context overflow).

Key `ChatStore` / `GemmaEngine` values:

| Constant | Value |
|---|---:|
| `maxTokenCount` (n_ctx) | `4096` |
| `generationReserve` | `1024` |
| `promptBudget` | `n_ctx - reserve` (`3072`) |
| `maxTurnsToKeep` | `3` |

The prompt is built in priority order (highest first):

```text
system identity
+ user profile/persona            (protected; never trimmed)
+ recent deterministic context
+ grounding instruction           (when recall context is present)
+ verbatim transcript slice       (structural/ordinal recall)
+ semantic retrieved memory       (topical recall)
+ ambient context
+ recent raw turns
```

Important behavior:

- Retrieval runs only when the message looks like recall (a broadened phrase list plus a positional/ordinal detector), so ordinary turns aren't taxed with a memory pack or forced into full prompt reprocessing. Ordinary follow-ups rely on the recent raw turns already in context.
- `fitToContext` enforces the token budget with a conservative character estimate — it drops the oldest turns first, then as a last resort tail-truncates the system prompt, shedding ambient and recall before the protected identity/profile text. (An exact tokenizer was tried but removed: it loaded a second full model on the GPU, which was too costly on 8 GB.)
- The unbounded append-only rolling summary is no longer built or injected; out-of-window recall is served by verbatim RAG plus the transcript slice.
- Low-signal turns ("ok", "yeah", "thanks") can be removed from LLM history.
- The context inspector shows exactly what was assembled for the latest turn.

## Memory System

The memory system has two different roles:

- Long-term Memory Journal: user-visible saved memories stored locally.
- Current-chat recall: verbatim conversation exchanges are embedded after every turn and retrieved into the prompt by semantic similarity; each carries a `turnIndex` for chronological/positional ordering.

Retrieval runs when the latest message looks like recall (a broadened phrase list plus a positional/ordinal detector), keeping ordinary turns fast. Positional/ordinal questions ("what was the first thing I asked?") are answered from a verbatim transcript slice built directly from the in-memory conversation, rather than from vector similarity. Cross-chat long-term retrieval is not injected into every prompt; stable cross-chat user information belongs in `ProfileStore`.

Memory components:

- `MemoryStore` uses SwiftData with a local `DominusMemory.store`.
- `MemoryRecord` stores content, kind, scope, category, metadata, embeddings, and a `turnIndex` (1-based user-turn ordinal; -1 for older/non-turn records).
- `MemoryHubRecord` stores category-level summaries.
- `MemoryEmbedder` uses Apple's `NLEmbedding.sentenceEmbedding(for: .english)`.
- Cosine similarity uses Accelerate/vDSP.
- Keyword fallback is used when embeddings are unavailable.
- `MemoryRetriever` scores candidates using semantic, keyword, entity, topic, recency, importance, profile, active-conversation, diversity, and repetition signals.
- `MemoryTraceStore` exposes retrieval traces for UI/debug visibility.
- `MemoryExtractor` normalizes and atomizes user memory text.
- `MemorySummaryBuilder` produces compact display and storage summaries.

The Memory Journal UI supports:

- Search.
- Sort order.
- Date filtering.
- Add memory.
- Edit memory.
- Delete memory.
- AI summary/refinement for long or messy entries.
- Accept/delete for candidate records.

## Profile System

`ProfileStore` stores stable user context separately from chat memory.

It supports:

- Structured fields for preferred name, role/work, app purpose, goals, and behavior preferences.
- A free-text persona field for how Dominus should speak.
- A voice-only emoji preference.
- SwiftData persistence for facts.
- UserDefaults persistence for persona and voice emoji preference.

The profile block is prepended to every prompt. In voice mode, if voice emojis are enabled, the profile block adds an instruction to use one emoji per response for the orb.

## UI Surface

Major UI pieces:

- Sidebar: conversations, profile, memory, audio settings.
- Chat view: streamed bubbles, selectable text, copy/share/speak actions, generation stop.
- Input bar: text send and PTT entry.
- Context ring: estimated prompt pressure and tap-to-open inspector.
- Loading splash: model and voice readiness.
- Voice overlay: black full-screen orb surface with state-dependent controls.
- Audio settings: volumes, haptics, voice picker, speech rate/pitch, orb scale, halftone controls.
- Memory Journal: long-term memory management.
- Profile sheet: stable user facts and persona.

## File Map

```text
Dominus17ProMax/
  DominusAppApp.swift
    App entry point.

  ContentView.swift
    Main SwiftUI app, sidebar, chat, input, voice state, endpointing,
    warmup, context inspector, orb overlay wiring, and PTT controls.

  ChatStore.swift
    Conversation source of truth, send/cancel pipeline, prompt assembly,
    streaming, context trimming, current-chat memory, profile integration,
    title generation, ambient cues, and persistence.

  GemmaEngine.swift
    Persistent SwiftLlama model wrapper for bundled Gemma GGUF.

  WhisperManager.swift
    WhisperKit loading, AVAudioEngine recording, live/final transcription,
    adaptive raw sound tracking, and Silero VAD feeding.

  SileroVAD.swift
    Core ML wrapper for the bundled Silero VAD model.

  SpeechManager.swift
    TTS, high-gain speaker path, route safety, sound effects, queue drain,
    message playback, and audio session handling.

  AudioSettingsStore.swift
    UserDefaults-backed audio, voice, haptics, and orb preferences.

  AudioSettingsView.swift
    Settings UI for sound volumes, voice selection, speech controls, and orb controls.

  LoadingView.swift
    Launch splash and progress/status views.

  VoiceOrb.swift
    Full-screen voice overlay and orb state presentation.

  EmojiOrb.swift
  HalftoneEmojiView.swift
  OrbEmojiScanner.swift
  OrbSizeAdjustView.swift
    Emoji/halftone orb rendering, emoji extraction, and orb preview/adjustment.

  ThinkingFillerManager.swift
    Local voice filler phrase scheduler. Present but disabled in active latency testing.

  VoiceModeGreetings.swift
    Local entry/return greeting phrase pools.

  MemoryView.swift
    Memory Journal UI.

  Memory/
    MemoryStore.swift
    MemoryRetriever.swift
    MemoryEmbedder.swift
    MemoryExtractor.swift
    MemorySummaryBuilder.swift
    MemoryTraceStore.swift

  Profile/
    ProfileStore.swift
    ProfileView.swift
    UserProfile.swift

  SoundEffects/
    AppLoadedSoundEffect.wav
    ActivateVoicetoVoice.wav
    DeactivateVoicetoVoice.wav
    UserVoiceResponseConcluded.wav
    AIVoiceResponseConcluded.wav
    xAIxVoiceResponseConcluded.wav

  SileroVADModel.mlpackage/
    Data/com.apple.CoreML/model.mlmodel
    Data/com.apple.CoreML/weights/weight.bin
    Manifest.json

  Assets.xcassets/
    App icon and accent color assets.

  gemma-2-2b-it-Q4_K_M.gguf
    Bundled local LLM model (Git LFS).

  Dominus17ProMax.entitlements
    App entitlements; enables microphone/audio input for the Mac app.
```

Other repository folders:

- `Scripts/` holds build helpers. `patch_llama_xcframework.sh` adds a Mac Catalyst slice to `llama.xcframework` at build time (see the Mac Catalyst section).
- `Archive/` contains old or reference voice work, including the prior SFSpeech recognizer file. It is not the active STT path.
- `Build Stack Notes/` contains historical architecture/build notes.
- `Packages/kokoro-swift/` is a local untracked Kokoro TTS experiment and is not referenced by the current Xcode project.

## Persistence

Local persisted data:

- Conversations: `ChatStore` saves `conversations.json` under the app documents directory.
- Memory records: SwiftData store named `DominusMemory.store`.
- Profile facts: SwiftData model for `ProfileFact`.
- Profile persona and voice emoji preference: UserDefaults.
- Audio/orb/speech settings: UserDefaults.
- Recall/repetition bookkeeping: UserDefaults where applicable.

## Known Constraints

- The context window is `n_ctx = 4096` with `1024` tokens reserved for the reply; `fitToContext` clamps the assembled prompt to the remaining budget using a conservative token estimate, so the prompt can never overflow the window.
- Do not replace the persistent `GemmaEngine.llama` with a fresh llama instance per turn.
- Keep `ChatStore`, `GemmaEngine`, `WhisperManager`, and `SpeechManager` on the main actor unless the app architecture is deliberately changed.
- Be careful with audio session ownership. Voice mode depends on one coordinated `.playAndRecord` session and one shared speech/SFX engine.
- Whisper live partials can jitter; endpointing must use VAD speech activity plus bounded raw-noise grace, not transcript stability alone.
- Silero VAD input must stay at the bundled model's expected `576` sample chunk size.
- Cross-chat long-term memories are currently not injected automatically into every LLM turn.
- The project should be built from Xcode, not from an unsupported command-line build path.

## Git And Project Hygiene Notes

Machine-generated files such as `.DS_Store`, Xcode `xcuserdata`, SwiftPM build folders, and the local `Packages/` experiment are ignored by the root `.gitignore`. Existing tracked machine-local files were removed from the Git index as part of this documentation cleanup while remaining available on disk.

The repository's `origin` remote is `https://github.com/creedpodcast/Dominus-iOS-Voice-to-Voice-Gemma.git`. The large Gemma GGUF model is tracked with Git LFS.
