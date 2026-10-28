import AVFAudio
import CoreAudio

/// Presents the input streams of a device, as an IOProc receives them, as one buffer of ``format``.
///
/// A device delivers one buffer per stream. A single stream is passed through in its own format. Several streams,
/// which some interfaces use for groups of channels, are combined into one buffer holding all of their channels.
/// More than two channels get a discrete layout, as the inputs of an audio interface have.
final class InputStreamAssembler: @unchecked Sendable {
    let format: AVAudioFormat
    private let streamFormats: [AudioStreamBasicDescription]
    /// Reused for combining several streams. Only used from the thread delivering the input.
    private var combined: AVAudioPCMBuffer?

    init(streamFormats: [AudioStreamBasicDescription]) throws(AudioCaptureError) {
        guard let first = streamFormats.first else { throw .inputDeviceUnavailable }
        self.streamFormats = streamFormats
        let channelCount = streamFormats.reduce(0) { $0 + $1.mChannelsPerFrame }
        // Formats of more than two channels need a layout.
        let layout = channelCount > 2 ? AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | channelCount) : nil
        if streamFormats.count == 1 {
            var description = first
            guard let format = AVAudioFormat(streamDescription: &description, channelLayout: layout) else { throw .unsupportedFormat }
            self.format = format
            return
        }
        guard streamFormats.allSatisfy({ $0.isPackedFloat32 && $0.mSampleRate == first.mSampleRate }) else {
            throw .unsupportedFormat
        }
        if let layout {
            format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: first.mSampleRate, interleaved: false, channelLayout: layout)
        } else if let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: first.mSampleRate, channels: channelCount, interleaved: false) {
            self.format = format
        } else {
            throw .unsupportedFormat
        }
    }

    /// Returns `nil` when the buffers do not match the stream formats, as while the device is being reconfigured.
    /// The returned buffer is only valid until the next call.
    func buffer(from input: UnsafePointer<AudioBufferList>) -> AVAudioPCMBuffer? {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard buffers.count == streamFormats.count,
              zip(buffers, streamFormats).allSatisfy({ $0.mNumberChannels == $1.mChannelsPerFrame && $1.mBytesPerFrame > 0 })
        else {
            return nil
        }
        let frameCounts = zip(buffers, streamFormats).map { Int($0.mDataByteSize / $1.mBytesPerFrame) }
        guard let frameCount = frameCounts.first, frameCount > 0, frameCounts.allSatisfy({ $0 == frameCount }) else {
            return nil
        }
        if streamFormats.count == 1 {
            return AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: input, deallocator: nil)
        }
        return combine(buffers, frameCount: frameCount)
    }

    private func combine(_ buffers: UnsafeMutableAudioBufferListPointer, frameCount: Int) -> AVAudioPCMBuffer? {
        if combined.map({ Int($0.frameCapacity) < frameCount }) ?? true {
            combined = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount))
        }
        guard let combined, let channels = combined.floatChannelData else { return nil }
        combined.frameLength = AVAudioFrameCount(frameCount)
        var channel = 0
        for buffer in buffers {
            guard let data = buffer.mData else { return nil }
            let samples = data.assumingMemoryBound(to: Float.self)
            let streamChannels = Int(buffer.mNumberChannels)
            for streamChannel in 0..<streamChannels {
                let destination = channels[channel + streamChannel]
                for frame in 0..<frameCount {
                    destination[frame] = samples[frame * streamChannels + streamChannel]
                }
            }
            channel += streamChannels
        }
        return combined
    }
}

private extension AudioStreamBasicDescription {
    /// Interleaved 32-bit float samples, as Core Audio delivers each stream of most devices.
    var isPackedFloat32: Bool {
        mFormatID == kAudioFormatLinearPCM
            && mFormatFlags & kAudioFormatFlagIsFloat != 0
            && mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
            && mBitsPerChannel == 32
            && mBytesPerFrame == 4 * mChannelsPerFrame
    }
}
