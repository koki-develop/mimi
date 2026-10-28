import AVFAudio

enum AudioConversionError: LocalizedError {
    case unsupported(from: AVAudioFormat, to: AVAudioFormat)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case let .unsupported(from, to):
            "\(from) to \(to) is not supported"
        case let .failed(detail):
            detail
        }
    }
}

/// Converts consecutive buffers of one stream, downmixing to the output's channels. The converter keeps samples
/// between calls, such as the tail of a resampling filter, so the output stays continuous across buffers.
struct AudioStreamConverter {
    private let converter: AVAudioConverter

    init(from inputFormat: AVAudioFormat, to outputFormat: AVAudioFormat) throws(AudioConversionError) {
        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw .unsupported(from: inputFormat, to: outputFormat)
        }
        converter.downmix = true
        self.converter = converter
    }

    var inputFormat: AVAudioFormat {
        converter.inputFormat
    }

    /// Converts `buffer`. Returns `nil` when the converter produced no samples.
    func convert(_ buffer: AVAudioPCMBuffer) throws(AudioConversionError) -> AVAudioPCMBuffer? {
        try convert(input: buffer)
    }

    /// Returns the samples held inside the converter, ending the stream. Returns `nil` when there are none.
    func drain() throws(AudioConversionError) -> AVAudioPCMBuffer? {
        try convert(input: nil)
    }

    private func convert(input buffer: AVAudioPCMBuffer?) throws(AudioConversionError) -> AVAudioPCMBuffer? {
        let ratio = converter.outputFormat.sampleRate / converter.inputFormat.sampleRate
        let inputFrames = buffer.map { Double($0.frameLength) } ?? 0
        // Leaves room for samples the converter holds back from earlier calls.
        let capacity = AVAudioFrameCount((inputFrames * ratio).rounded(.up)) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: capacity) else {
            throw .failed("Could not allocate an output buffer of \(capacity) frames")
        }

        // The input block is invoked synchronously within `convert(to:error:withInputFrom:)`.
        nonisolated(unsafe) let input = buffer
        nonisolated(unsafe) var consumed = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            guard let input else {
                inputStatus.pointee = .endOfStream
                return nil
            }
            if consumed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            inputStatus.pointee = .haveData
            return input
        }
        if status == .error {
            throw .failed(error?.localizedDescription ?? "Unknown error")
        }
        return output.frameLength > 0 ? output : nil
    }
}
