# Sources/transcribe/Capture

**A single `SCStream` carries both mic and system audio.** It needs a dummy 2×2 @ 1fps video config even though no video output is registered — `SCStream` refuses audio-only setups.
