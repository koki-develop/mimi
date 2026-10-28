import AVFAudio
import CoreAudio
@testable import MimiKit
import Testing

/// Interleaved 32-bit float samples, as Core Audio delivers each input stream.
private func floatFormat(channels: UInt32, sampleRate: Double = 48000) -> AudioStreamBasicDescription {
    AudioStreamBasicDescription(
        mSampleRate: sampleRate,
        mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
        mBytesPerPacket: 4 * channels,
        mFramesPerPacket: 1,
        mBytesPerFrame: 4 * channels,
        mChannelsPerFrame: channels,
        mBitsPerChannel: 32,
        mReserved: 0
    )
}

private func int16Format(channels: UInt32) -> AudioStreamBasicDescription {
    AudioStreamBasicDescription(
        mSampleRate: 48000,
        mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
        mBytesPerPacket: 2 * channels,
        mFramesPerPacket: 1,
        mBytesPerFrame: 2 * channels,
        mChannelsPerFrame: channels,
        mBitsPerChannel: 16,
        mReserved: 0
    )
}

/// Calls `body` with a buffer list holding one buffer per element of `streams`, each with interleaved samples of the
/// given channel count.
private func withBufferList<Result>(
    _ streams: [(channels: UInt32, samples: [Float])],
    _ body: (UnsafePointer<AudioBufferList>) -> Result
) -> Result {
    let list = AudioBufferList.allocate(maximumBuffers: streams.count)
    defer {
        for buffer in list { buffer.mData?.deallocate() }
        free(list.unsafeMutablePointer)
    }
    for (index, stream) in streams.enumerated() {
        let data = UnsafeMutablePointer<Float>.allocate(capacity: max(stream.samples.count, 1))
        data.initialize(from: stream.samples, count: stream.samples.count)
        list[index] = AudioBuffer(
            mNumberChannels: stream.channels,
            mDataByteSize: UInt32(stream.samples.count * MemoryLayout<Float>.size),
            mData: UnsafeMutableRawPointer(data)
        )
    }
    return body(UnsafePointer(list.unsafeMutablePointer))
}

private func channel(_ index: Int, of buffer: AVAudioPCMBuffer) -> [Float] {
    Array(UnsafeBufferPointer(start: buffer.floatChannelData![index], count: Int(buffer.frameLength)))
}

struct InputStreamAssemblerTests {
    @Test func passesASingleStreamThrough() throws {
        let assembler = try InputStreamAssembler(streamFormats: [floatFormat(channels: 2)])
        #expect(assembler.format.channelCount == 2)
        #expect(assembler.format.isInterleaved)

        withBufferList([(2, [1, -1, 2, -2, 3, -3])]) { list in
            let buffer = assembler.buffer(from: list)
            #expect(buffer?.frameLength == 3)
        }
    }

    @Test func passesASingleStreamOfManyChannelsThrough() throws {
        let assembler = try InputStreamAssembler(streamFormats: [floatFormat(channels: 4)])
        #expect(assembler.format.channelCount == 4)

        withBufferList([(4, [Float](repeating: 0.5, count: 8))]) { list in
            #expect(assembler.buffer(from: list)?.frameLength == 2)
        }
    }

    @Test func passesASingleStreamOfAnyLinearFormatThrough() throws {
        let assembler = try InputStreamAssembler(streamFormats: [int16Format(channels: 1)])
        #expect(assembler.format.commonFormat == .pcmFormatInt16)
    }

    @Test func combinesStreamsIntoOneBufferOfAllChannels() throws {
        let assembler = try InputStreamAssembler(streamFormats: [floatFormat(channels: 2), floatFormat(channels: 1)])
        #expect(assembler.format.channelCount == 3)
        #expect(!assembler.format.isInterleaved)
        #expect(assembler.format.sampleRate == 48000)

        withBufferList([(2, [1, 10, 2, 20, 3, 30]), (1, [100, 200, 300])]) { list in
            guard let buffer = assembler.buffer(from: list) else {
                Issue.record("No buffer was assembled")
                return
            }
            #expect(buffer.frameLength == 3)
            #expect(channel(0, of: buffer) == [1, 2, 3])
            #expect(channel(1, of: buffer) == [10, 20, 30])
            #expect(channel(2, of: buffer) == [100, 200, 300])
        }

        // A longer delivery than any before grows the reused buffer.
        withBufferList([(2, [Float](repeating: 1, count: 20000)), (1, [Float](repeating: 2, count: 10000))]) { list in
            let buffer = assembler.buffer(from: list)
            #expect(buffer?.frameLength == 10000)
            #expect(buffer.map { channel(2, of: $0).allSatisfy { $0 == 2 } } == true)
        }
    }

    @Test func dropsBuffersThatDoNotMatchTheStreams() throws {
        let assembler = try InputStreamAssembler(streamFormats: [floatFormat(channels: 2), floatFormat(channels: 1)])
        // One stream missing, as while the device is being reconfigured.
        withBufferList([(2, [1, 10])]) { list in
            #expect(assembler.buffer(from: list) == nil)
        }
        // A stream with another channel count.
        withBufferList([(1, [1, 2]), (1, [3, 4])]) { list in
            #expect(assembler.buffer(from: list) == nil)
        }
        // Streams of different lengths.
        withBufferList([(2, [1, 10, 2, 20]), (1, [3])]) { list in
            #expect(assembler.buffer(from: list) == nil)
        }
    }

    @Test func rejectsStreamsThatCannotBeCombined() {
        #expect(throws: AudioCaptureError.self) {
            try InputStreamAssembler(streamFormats: [int16Format(channels: 1), int16Format(channels: 1)])
        }
        #expect(throws: AudioCaptureError.self) {
            try InputStreamAssembler(streamFormats: [floatFormat(channels: 1), floatFormat(channels: 1, sampleRate: 44100)])
        }
        #expect(throws: AudioCaptureError.self) {
            try InputStreamAssembler(streamFormats: [])
        }
    }
}
