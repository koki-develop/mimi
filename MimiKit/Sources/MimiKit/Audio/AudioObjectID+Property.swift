import CoreAudio

extension AudioObjectID {
    static let system = AudioObjectID(kAudioObjectSystemObject)
    static let unknown = AudioObjectID(kAudioObjectUnknown)

    var isValid: Bool { self != .unknown }

    static func readDefaultInputDevice() throws(AudioCaptureError) -> AudioDeviceID {
        try AudioObjectID.system.read(kAudioHardwarePropertyDefaultInputDevice, defaultValue: AudioDeviceID.unknown)
    }

    /// Whether the device is still present. A device that has gone away reads as not alive.
    func readIsAlive() -> Bool {
        (try? read(kAudioDevicePropertyDeviceIsAlive, defaultValue: UInt32(0))) == 1
    }

    func readStreams(scope: AudioObjectPropertyScope) throws(AudioCaptureError) -> [AudioStreamID] {
        try readArray(kAudioDevicePropertyStreams, scope: scope, of: AudioStreamID.self)
    }

    /// The format of the samples a stream exchanges with an IOProc.
    func readVirtualFormat() throws(AudioCaptureError) -> AudioStreamBasicDescription {
        try read(kAudioStreamPropertyVirtualFormat, defaultValue: AudioStreamBasicDescription())
    }

    func readTapFormat() throws(AudioCaptureError) -> AudioStreamBasicDescription {
        try read(kAudioTapPropertyFormat, defaultValue: AudioStreamBasicDescription())
    }

    private func read<T>(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        defaultValue: T
    ) throws(AudioCaptureError) -> T {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<T>.size)
        var value = defaultValue
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(self, &address, 0, nil, &size, pointer)
        }
        try check(status, "AudioObjectGetPropertyData(\(selector))")
        return value
    }

    private func readArray<T>(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope,
        of _: T.Type
    ) throws(AudioCaptureError) -> [T] {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(self, &address, 0, nil, &size), "AudioObjectGetPropertyDataSize(\(selector))")
        let count = Int(size) / MemoryLayout<T>.stride
        guard count > 0 else { return [] }
        let pointer = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<T>.alignment)
        defer { pointer.deallocate() }
        try check(AudioObjectGetPropertyData(self, &address, 0, nil, &size, pointer), "AudioObjectGetPropertyData(\(selector))")
        let values = pointer.bindMemory(to: T.self, capacity: count)
        return Array(UnsafeBufferPointer(start: values, count: Int(size) / MemoryLayout<T>.stride))
    }
}

extension AudioStreamBasicDescription {
    /// Whether both describe the same format. The struct has no equality of its own.
    func matches(_ other: AudioStreamBasicDescription) -> Bool {
        mSampleRate == other.mSampleRate
            && mFormatID == other.mFormatID
            && mFormatFlags == other.mFormatFlags
            && mBytesPerPacket == other.mBytesPerPacket
            && mFramesPerPacket == other.mFramesPerPacket
            && mBytesPerFrame == other.mBytesPerFrame
            && mChannelsPerFrame == other.mChannelsPerFrame
            && mBitsPerChannel == other.mBitsPerChannel
    }
}
