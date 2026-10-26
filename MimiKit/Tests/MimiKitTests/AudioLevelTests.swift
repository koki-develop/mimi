import AVFAudio
import MimiKit
import Testing

struct AudioLevelTests {
    private func makeBuffer(channels: AVAudioChannelCount, interleaved: Bool, value: Float) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: channels, interleaved: interleaved)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480)!
        buffer.frameLength = 480
        let channelCount = interleaved ? 1 : Int(channels)
        for channel in 0..<channelCount {
            for index in 0..<(480 * buffer.stride) {
                buffer.floatChannelData![channel][index] = value
            }
        }
        return buffer
    }

    @Test(arguments: [(1, false), (2, false), (2, true)])
    func constantSignal(channels: Int, interleaved: Bool) {
        let buffer = makeBuffer(channels: AVAudioChannelCount(channels), interleaved: interleaved, value: 0.5)
        #expect(abs(AudioLevel.rmsDecibels(buffer) - 20 * log10(0.5)) < 0.001)
    }

    @Test func silenceIsFloor() {
        let buffer = makeBuffer(channels: 1, interleaved: false, value: 0)
        #expect(AudioLevel.rmsDecibels(buffer) == -.infinity)
        #expect(AudioLevel.normalized(buffer) == 0)
    }

    @Test func fullScaleIsOne() {
        let buffer = makeBuffer(channels: 1, interleaved: false, value: 1)
        #expect(AudioLevel.normalized(buffer) == 1)
    }

    @Test func normalizedIsLinearInDecibels() {
        let buffer = makeBuffer(channels: 1, interleaved: false, value: pow(10, -30 / 20))
        #expect(abs(AudioLevel.normalized(buffer, floorDecibels: -60) - 0.5) < 0.001)
    }
}
