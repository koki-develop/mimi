import CoreAudio
import Foundation

public enum AudioCaptureError: LocalizedError {
    case coreAudio(operation: String, status: OSStatus)
    case unsupportedFormat
    case inputDeviceUnavailable

    public var errorDescription: String? {
        switch self {
        case let .coreAudio(operation, status):
            "\(operation) failed (OSStatus \(status))"
        case .unsupportedFormat:
            "Unsupported audio format"
        case .inputDeviceUnavailable:
            "No audio input device is available"
        }
    }
}

func check(_ status: OSStatus, _ operation: String) throws(AudioCaptureError) {
    guard status == noErr else {
        throw .coreAudio(operation: operation, status: status)
    }
}
