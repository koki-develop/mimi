# Sources/TranscribeCore/Transcription

**Transcription language is configurable via `TranscriberConfiguration.language`** (default `"ja"`). The CLI exposes `--language` / `-l`; library consumers pass it via `PipelineConfiguration.transcriber`.

**`LoadedModel` is internal** to this directory. It's a wrapper around WhisperKit and is **not part of the library API**; consumers depend on `TranscriberProtocol` / `TranscriberFactory`, not `LoadedModel` directly. `ModelLoader.load` is also internal — call sites are limited to `DefaultTranscriberFactory.makeTranscribers`.
