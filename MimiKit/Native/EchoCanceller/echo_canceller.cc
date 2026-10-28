#include "echo_canceller.h"

#include "api/audio/audio_processing.h"

struct mimi_echo_canceller {
  rtc::scoped_refptr<webrtc::AudioProcessing> apm;
  webrtc::StreamConfig stream;
};

extern "C" mimi_echo_canceller *mimi_echo_canceller_create(int sample_rate) {
  if (sample_rate != 16000 && sample_rate != 32000 && sample_rate != 48000) return nullptr;

  auto apm = webrtc::AudioProcessingBuilder().Create();
  if (!apm) return nullptr;

  // Only echo cancellation, which is AEC3 outside mobile mode: the output feeds speech recognition, which does its
  // own level and noise handling.
  webrtc::AudioProcessing::Config config;
  config.echo_canceller.enabled = true;
  config.echo_canceller.mobile_mode = false;
  config.noise_suppression.enabled = false;
  config.gain_controller1.enabled = false;
  config.gain_controller2.enabled = false;
  apm->ApplyConfig(config);

  webrtc::StreamConfig stream(sample_rate, 1);
  if (apm->Initialize(webrtc::ProcessingConfig{{stream, stream, stream, stream}}) != webrtc::AudioProcessing::kNoError) {
    return nullptr;
  }
  return new mimi_echo_canceller{apm, stream};
}

extern "C" void mimi_echo_canceller_destroy(mimi_echo_canceller *canceller) { delete canceller; }

extern "C" int mimi_echo_canceller_analyze_render(mimi_echo_canceller *canceller, const float *frame) {
  const float *data[] = {frame};
  return canceller->apm->AnalyzeReverseStream(data, canceller->stream);
}

extern "C" int mimi_echo_canceller_process_capture(mimi_echo_canceller *canceller, float *frame) {
  // Required whenever echo cancellation is enabled. Render and capture frames are passed in step, so no audio is
  // buffered between them; AEC3 estimates the delay of the echo itself.
  canceller->apm->set_stream_delay_ms(0);
  const float *source[] = {frame};
  float *destination[] = {frame};
  return canceller->apm->ProcessStream(source, canceller->stream, canceller->stream, destination);
}
