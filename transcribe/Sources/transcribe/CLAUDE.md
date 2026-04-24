# Sources/transcribe

**Two WhisperKit instances are loaded for the same model** in `App.run` — mic on `.cpuAndNeuralEngine`, system on `.cpuAndGPU`. This is intentional to avoid ANE contention when both streams decode concurrently; don't "dedupe" it.
