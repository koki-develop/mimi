# Sources/TranscribeCore/Transcription

**Transcription language is configurable via `TranscriberConfiguration.language`** (default `"ja"`). The CLI exposes `--language` / `-l`; library consumers pass it via `DaemonConfiguration.transcriber`.

**`LoadedModel` is internal** to this directory. It's a wrapper around WhisperKit and is **not part of the library API**; consumers depend on `TranscriberProtocol` / `TranscriberFactory`, not `LoadedModel` directly. `ModelLoader.load` is also internal — call sites are limited to `DefaultTranscriberFactory.loadModels` (called once at daemon boot). `LoadedModel.kit` is `Optional<WhisperKit>` to allow test fakes to construct sentinel `LoadedModels` without a real WhisperKit; production paths always hold non-nil `kit` and `Transcriber.init` precondition-checks this.
