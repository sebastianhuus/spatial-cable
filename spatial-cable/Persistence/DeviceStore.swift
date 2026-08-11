import Foundation

/// Persists user selections by stable identifier (device UID, bundle ID) — never by name or
/// list index, since both can shift between launches.
final class DeviceStore {
    static let shared = DeviceStore()

    private let defaults = UserDefaults.standard

    private enum Key {
        static let outputDeviceUID = "spatial-cable.lastOutputDeviceUID"
        static let targetBundleID = "spatial-cable.lastTargetBundleID"
    }

    var lastOutputDeviceUID: String? {
        get { defaults.string(forKey: Key.outputDeviceUID) }
        set { defaults.set(newValue, forKey: Key.outputDeviceUID) }
    }

    var lastTargetBundleID: String? {
        get { defaults.string(forKey: Key.targetBundleID) }
        set { defaults.set(newValue, forKey: Key.targetBundleID) }
    }
}
