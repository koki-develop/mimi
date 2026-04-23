import AVFoundation
import CoreGraphics
import Foundation

public enum PermissionError: Error, Equatable {
    case screenRecordingDenied
    case microphoneDenied
}

public enum PermissionChecker {
    public static func ensureAll() async throws {
        try await ensureScreenRecording()
        try await ensureMicrophone()
    }

    static func ensureScreenRecording() async throws {
        if CGPreflightScreenCaptureAccess() { return }
        _ = CGRequestScreenCaptureAccess()
        if CGPreflightScreenCaptureAccess() { return }
        throw PermissionError.screenRecordingDenied
    }

    static func ensureMicrophone() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return
        case .notDetermined:
            if await AVCaptureDevice.requestAccess(for: .audio) {
                return
            }
            throw PermissionError.microphoneDenied
        case .denied, .restricted:
            throw PermissionError.microphoneDenied
        @unknown default:
            throw PermissionError.microphoneDenied
        }
    }
}
