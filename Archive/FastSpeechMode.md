# Fast Speech Mode Archive

Archived on the `codex/remove-fast-speech-option` branch.

Fast Speech Mode was a rabbit-button toggle that made individual turns use a smaller prompt path:

- base system prompt
- compact profile block
- latest user message
- optional tiny recent-history slice
- no RAG retrieval
- no rolling summary
- no ambient-context block
- no voice greeting or thinking filler
- lower generation temperature
- faster word-by-word assistant reveal

The active app no longer calls this mode. The branch removes the rabbit UI and the `fastSpeechModeEnabled` runtime checks so future speed work can happen in the default voice/chat pipeline instead of behind a separate mode.
