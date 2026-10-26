import CoreAudio
import Dispatch

/// Observes changes to a property of a Core Audio object, such as the system's default device.
@MainActor
final class AudioPropertyObserver {
    private let objectID: AudioObjectID
    private var address: AudioObjectPropertyAddress
    private var listener: AudioObjectPropertyListenerBlock?

    init(objectID: AudioObjectID = .system, selector: AudioObjectPropertySelector) {
        self.objectID = objectID
        address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    isolated deinit {
        stop()
    }

    func start(onChange: @escaping @MainActor () -> Void) throws(AudioCaptureError) {
        stop()
        // Delivered on the main queue; `@Sendable` keeps the block from inheriting main actor isolation at creation.
        let listener: AudioObjectPropertyListenerBlock = { @Sendable _, _ in
            MainActor.assumeIsolated { onChange() }
        }
        try check(
            AudioObjectAddPropertyListenerBlock(objectID, &address, .main, listener),
            "AudioObjectAddPropertyListenerBlock"
        )
        self.listener = listener
    }

    func stop() {
        guard let listener else { return }
        AudioObjectRemovePropertyListenerBlock(objectID, &address, .main, listener)
        self.listener = nil
    }
}
