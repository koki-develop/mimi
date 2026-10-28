#ifndef MIMI_ECHO_CANCELLER_H
#define MIMI_ECHO_CANCELLER_H

#ifdef __cplusplus
extern "C" {
#endif

/// WebRTC AEC3 configured for one mono reference (render) signal and one mono captured signal.
/// Not thread-safe: calls on one instance must not overlap.
typedef struct mimi_echo_canceller mimi_echo_canceller;

/// Returns NULL when `sample_rate` is not supported (16000, 32000, and 48000 are) or setting up fails.
mimi_echo_canceller *mimi_echo_canceller_create(int sample_rate);
void mimi_echo_canceller_destroy(mimi_echo_canceller *canceller);

/// Analyzes one 10 ms frame (`sample_rate / 100` samples) of the reference signal.
/// Each reference frame must be followed by the capture frame recorded at the same time.
/// Returns 0 on success, or a negative WebRTC AudioProcessing error code.
int mimi_echo_canceller_analyze_render(mimi_echo_canceller *canceller, const float *frame);

/// Removes the echo of the reference from one 10 ms frame of the captured signal, in place.
/// Returns 0 on success, or a negative WebRTC AudioProcessing error code.
int mimi_echo_canceller_process_capture(mimi_echo_canceller *canceller, float *frame);

#ifdef __cplusplus
}
#endif

#endif
