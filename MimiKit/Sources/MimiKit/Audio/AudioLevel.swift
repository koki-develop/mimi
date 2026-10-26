import Accelerate
import AVFAudio
import Foundation

public enum AudioLevel {
    /// Returns the RMS level of `buffer` mapped linearly from `floorDecibels`...0 dBFS to 0...1.
    public static func normalized(_ buffer: AVAudioPCMBuffer, floorDecibels: Float = -60) -> Float {
        let decibels = max(rmsDecibels(buffer), floorDecibels)
        return (decibels - floorDecibels) / -floorDecibels
    }

    public static func rmsDecibels(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData else { return -.infinity }
        // Interleaved audio is held in a single buffer with all channels.
        let bufferCount = buffer.format.isInterleaved ? 1 : Int(buffer.format.channelCount)
        let samplesPerBuffer = Int(buffer.frameLength) * buffer.stride
        guard bufferCount > 0, samplesPerBuffer > 0 else { return -.infinity }

        // Buffers have the same length, so the overall mean square is the mean of theirs.
        var sumOfMeanSquares: Float = 0
        for index in 0..<bufferCount {
            let rms = vDSP.rootMeanSquare(UnsafeBufferPointer(start: channelData[index], count: samplesPerBuffer))
            sumOfMeanSquares += rms * rms
        }
        return 20 * log10((sumOfMeanSquares / Float(bufferCount)).squareRoot())
    }
}
