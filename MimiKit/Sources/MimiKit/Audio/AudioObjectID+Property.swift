import CoreAudio

extension AudioObjectID {
    static let system = AudioObjectID(kAudioObjectSystemObject)
    static let unknown = AudioObjectID(kAudioObjectUnknown)

    var isValid: Bool { self != .unknown }

    static func readDefaultSystemOutputDevice() throws(AudioCaptureError) -> AudioDeviceID {
        try AudioObjectID.system.read(kAudioHardwarePropertyDefaultSystemOutputDevice, defaultValue: AudioDeviceID.unknown)
    }

    func readDeviceUID() throws(AudioCaptureError) -> String {
        try read(kAudioDevicePropertyDeviceUID, defaultValue: "" as CFString) as String
    }

    func readTapFormat() throws(AudioCaptureError) -> AudioStreamBasicDescription {
        try read(kAudioTapPropertyFormat, defaultValue: AudioStreamBasicDescription())
    }

    private func read<T>(_ selector: AudioObjectPropertySelector, defaultValue: T) throws(AudioCaptureError) -> T {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<T>.size)
        var value = defaultValue
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(self, &address, 0, nil, &size, pointer)
        }
        try check(status, "AudioObjectGetPropertyData(\(selector))")
        return value
    }
}
