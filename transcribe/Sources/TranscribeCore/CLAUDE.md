# Sources/TranscribeCore

**Two WhisperKit instances are loaded for the same model** in `DefaultTranscriberFactory.makeTranscribers` — mic uses `.cpuAndNeuralEngine` for the three compute slots (`melCompute` / `audioEncoderCompute` / `textDecoderCompute`); system uses `.cpuAndGPU` for the same three. This is intentional to avoid ANE contention when both streams decode concurrently; don't "dedupe" it.
