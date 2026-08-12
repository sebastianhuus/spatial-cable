import Foundation

/// Persists user selections by stable identifier (device UID, bundle ID) — never by name or
/// list index, since both can shift between launches.
final class DeviceStore {
    static let shared = DeviceStore()

    /// Which relay source mode was last selected — kept as its own key rather than overloading
    /// `lastTargetBundleID`, since "all system audio" mode has no bundle ID to store.
    enum RelaySourceMode: String {
        case process
        case allSystemAudio
    }

    private let defaults = UserDefaults.standard

    private enum Key {
        static let outputDeviceUID = "spatial-cable.lastOutputDeviceUID"
        static let targetBundleID = "spatial-cable.lastTargetBundleID"
        static let relaySourceMode = "spatial-cable.relaySourceMode"
    }

    var lastOutputDeviceUID: String? {
        get { defaults.string(forKey: Key.outputDeviceUID) }
        set { defaults.set(newValue, forKey: Key.outputDeviceUID) }
    }

    var lastTargetBundleID: String? {
        get { defaults.string(forKey: Key.targetBundleID) }
        set { defaults.set(newValue, forKey: Key.targetBundleID) }
    }

    var relaySourceMode: RelaySourceMode? {
        get { defaults.string(forKey: Key.relaySourceMode).flatMap(RelaySourceMode.init) }
        set { defaults.set(newValue?.rawValue, forKey: Key.relaySourceMode) }
    }
}
