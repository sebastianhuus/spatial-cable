import CoreAudio
import Foundation

/// Errors raised by the thin Core Audio wrappers below. Every HAL call site wraps its
/// OSStatus so failures are debuggable instead of silently producing empty/garbage data.
enum CoreAudioError: Error, CustomStringConvertible {
    case osStatus(OSStatus, String)

    var description: String {
        switch self {
        case .osStatus(let status, let context):
            return "\(context) failed with OSStatus \(status)"
        }
    }
}

extension AudioObjectID {
    /// The well-known system object, root of every other Core Audio property lookup.
    static let system = AudioObjectID(kAudioObjectSystemObject)

    /// Sentinel for "no device/tap yet" — kAudioObjectUnknown is 0.
    static let unknown = AudioObjectID(kAudioObjectUnknown)

    static func readProcessList() throws -> [AudioObjectID] {
        try AudioObjectID.system.readArray(
            address: AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyProcessObjectList,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            ),
            type: AudioObjectID.self
        )
    }

    static func readDeviceList() throws -> [AudioObjectID] {
        try AudioObjectID.system.readArray(
            address: AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDevices,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            ),
            type: AudioObjectID.self
        )
    }

    /// Resolves spatial-cable's own Core Audio process object, so a global tap can exclude it —
    /// without this, our own relayed output (itself a process on the Mac) would get captured by
    /// the same tap and feed back into itself.
    static func resolveOwnProcessObjectID() throws -> AudioObjectID? {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let objectIDs = try readProcessList()
        for objectID in objectIDs {
            if let pid = try? objectID.readProcessPID(), pid == ownPID {
                return objectID
            }
        }
        return nil
    }

    static func readDefaultSystemOutputDevice() throws -> AudioObjectID {
        try AudioObjectID.system.read(
            address: AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            ),
            type: AudioObjectID.self
        )
    }

    /// The user-facing default output device — what System Settings > Sound > Output shows
    /// and what a plain AVAudioEngine output node follows. Distinct from
    /// kAudioHardwarePropertyDefaultSystemOutputDevice above (that one's for system alert
    /// sounds and is only used here as the tap aggregate's anchor device).
    static func readDefaultOutputDevice() throws -> AudioObjectID {
        try AudioObjectID.system.read(
            address: AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            ),
            type: AudioObjectID.self
        )
    }

    static func setDefaultOutputDevice(_ deviceID: AudioObjectID) throws {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var mutableID = deviceID
        let status = AudioObjectSetPropertyData(
            AudioObjectID.system,
            &address,
            0, nil,
            UInt32(MemoryLayout<AudioObjectID>.size),
            &mutableID
        )
        guard status == noErr else {
            throw CoreAudioError.osStatus(status, "AudioObjectSetPropertyData(kAudioHardwarePropertyDefaultOutputDevice)")
        }
    }

    func readProcessPID() throws -> pid_t {
        try read(
            address: AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyPID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            ),
            type: pid_t.self
        )
    }

    func readDeviceUID() throws -> String {
        try readString(
            address: AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceUID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
        )
    }

    func readDeviceName() throws -> String {
        try readString(
            address: AudioObjectPropertyAddress(
                mSelector: kAudioObjectPropertyName,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
        )
    }

    func readTransportType() throws -> UInt32 {
        try read(
            address: AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyTransportType,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            ),
            type: UInt32.self
        )
    }

    /// True if this device object advertises at least one output stream. Used to filter the
    /// physical-device list down to things that can actually be picked as a relay target.
    func hasOutputStreams() -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(self, &address, 0, nil, &dataSize)
        return status == noErr && dataSize > 0
    }

    /// Registers `handler` to be called whenever the property at `address` changes, delivered on
    /// `queue`. Returns the same block reference passed in — `AudioObjectRemovePropertyListenerBlock`
    /// requires the identical block back to deregister, so callers must hold onto this return value.
    func addPropertyListener(
        address: AudioObjectPropertyAddress,
        queue: DispatchQueue?,
        handler: @escaping AudioObjectPropertyListenerBlock
    ) throws -> AudioObjectPropertyListenerBlock {
        var mutableAddress = address
        let status = AudioObjectAddPropertyListenerBlock(self, &mutableAddress, queue, handler)
        guard status == noErr else {
            throw CoreAudioError.osStatus(status, "AudioObjectAddPropertyListenerBlock")
        }
        return handler
    }

    /// Deregisters a listener previously registered with `addPropertyListener`. `handler` must be
    /// the exact block reference returned from that call.
    func removePropertyListener(
        address: AudioObjectPropertyAddress,
        queue: DispatchQueue?,
        handler: @escaping AudioObjectPropertyListenerBlock
    ) throws {
        var mutableAddress = address
        let status = AudioObjectRemovePropertyListenerBlock(self, &mutableAddress, queue, handler)
        guard status == noErr else {
            throw CoreAudioError.osStatus(status, "AudioObjectRemovePropertyListenerBlock")
        }
    }

    func readTapFormat() throws -> AudioStreamBasicDescription {
        try read(
            address: AudioObjectPropertyAddress(
                mSelector: kAudioTapPropertyFormat,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            ),
            type: AudioStreamBasicDescription.self
        )
    }

    // MARK: - Generic property helpers

    func read<T>(address: AudioObjectPropertyAddress, type: T.Type) throws -> T {
        var address = address
        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(self, &address, 0, nil, &dataSize)
        guard status == noErr else {
            throw CoreAudioError.osStatus(status, "AudioObjectGetPropertyDataSize(\(address.mSelector))")
        }

        let buffer = UnsafeMutableRawPointer.allocate(byteCount: Int(dataSize), alignment: MemoryLayout<T>.alignment)
        defer { buffer.deallocate() }

        status = AudioObjectGetPropertyData(self, &address, 0, nil, &dataSize, buffer)
        guard status == noErr else {
            throw CoreAudioError.osStatus(status, "AudioObjectGetPropertyData(\(address.mSelector))")
        }

        return buffer.load(as: T.self)
    }

    func readArray<T>(address: AudioObjectPropertyAddress, type: T.Type) throws -> [T] {
        var address = address
        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(self, &address, 0, nil, &dataSize)
        guard status == noErr else {
            throw CoreAudioError.osStatus(status, "AudioObjectGetPropertyDataSize(\(address.mSelector))")
        }
        guard dataSize > 0 else { return [] }

        let count = Int(dataSize) / MemoryLayout<T>.stride
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: Int(dataSize), alignment: MemoryLayout<T>.alignment)
        defer { buffer.deallocate() }

        status = AudioObjectGetPropertyData(self, &address, 0, nil, &dataSize, buffer)
        guard status == noErr else {
            throw CoreAudioError.osStatus(status, "AudioObjectGetPropertyData(\(address.mSelector))")
        }

        let typed = buffer.bindMemory(to: T.self, capacity: count)
        return (0..<count).map { typed[$0] }
    }

    func readString(address: AudioObjectPropertyAddress) throws -> String {
        var address = address
        var cfString: CFString = "" as CFString
        var dataSize = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &cfString) { ptr -> OSStatus in
            AudioObjectGetPropertyData(self, &address, 0, nil, &dataSize, ptr)
        }
        guard status == noErr else {
            throw CoreAudioError.osStatus(status, "AudioObjectGetPropertyData(\(address.mSelector) string)")
        }
        return cfString as String
    }
}
