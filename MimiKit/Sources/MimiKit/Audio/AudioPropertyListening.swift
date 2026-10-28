import CoreAudio
import Dispatch

/// A property of a Core Audio object, such as the system's default input device or a device's liveness.
struct AudioProperty: Sendable {
    let object: AudioObjectID
    let selector: AudioObjectPropertySelector
    var scope = kAudioObjectPropertyScopeGlobal

    var address: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }
}

/// A listener added with ``AudioPropertyListening/listen(to:on:handler:)``.
protocol AudioPropertyListener: AnyObject {
    /// Must not be called on the queue the listener is called on, since Core Audio may wait for a call in progress.
    func remove()
}

/// Listens for changes of Core Audio properties.
protocol AudioPropertyListening: Sendable {
    /// Calls `handler` on `queue` whenever `property` changes, until the listener is removed.
    func listen(
        to property: AudioProperty,
        on queue: DispatchQueue,
        handler: @escaping @Sendable () -> Void
    ) throws(AudioCaptureError) -> any AudioPropertyListener
}

struct CoreAudioPropertyListening: AudioPropertyListening {
    func listen(
        to property: AudioProperty,
        on queue: DispatchQueue,
        handler: @escaping @Sendable () -> Void
    ) throws(AudioCaptureError) -> any AudioPropertyListener {
        try CoreAudioPropertyListener(property: property, queue: queue, handler: handler)
    }
}

private final class CoreAudioPropertyListener: AudioPropertyListener {
    private let property: AudioProperty
    private let queue: DispatchQueue
    private var block: AudioObjectPropertyListenerBlock?

    init(property: AudioProperty, queue: DispatchQueue, handler: @escaping @Sendable () -> Void) throws(AudioCaptureError) {
        self.property = property
        self.queue = queue
        let block: AudioObjectPropertyListenerBlock = { _, _ in handler() }
        var address = property.address
        try check(
            AudioObjectAddPropertyListenerBlock(property.object, &address, queue, block),
            "AudioObjectAddPropertyListenerBlock(\(property.selector))"
        )
        self.block = block
    }

    func remove() {
        guard let block else { return }
        var address = property.address
        // Fails once the object is gone, which also removes its listeners.
        AudioObjectRemovePropertyListenerBlock(property.object, &address, queue, block)
        self.block = nil
    }
}
