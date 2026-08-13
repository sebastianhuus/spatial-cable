import CoreAudio
import Foundation

/// Keeps the physical output device list live by watching kAudioHardwarePropertyDevices via
/// Core Audio's property-listener API, instead of only re-reading it on launch or on a manual
/// refresh. Purely "what output devices exist right now" — no relay/selection awareness, same
/// boundary AudioProcessController keeps from process-targeting logic.
final class AudioDeviceWatcher: ObservableObject {
    @Published private(set) var devices: [AudioOutputDevice] = []

    private var listenerBlock: AudioObjectPropertyListenerBlock?
    private let listenerAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    init() {
        refresh()
        observeDeviceList()
    }

    deinit {
        guard let listenerBlock else { return }
        do {
            try AudioObjectID.system.removePropertyListener(
                address: listenerAddress, queue: .main, handler: listenerBlock
            )
        } catch {
            Log.devices.error("Failed to remove device listener: \(String(describing: error), privacy: .public)")
        }
    }

    func refresh() {
        devices = DeviceEnumerator.listPhysicalOutputDevices()
    }

    private func observeDeviceList() {
        do {
            listenerBlock = try AudioObjectID.system.addPropertyListener(
                address: listenerAddress,
                queue: .main
            ) { [weak self] _, _ in
                Log.devices.info("Device list changed — refreshing")
                self?.refresh()
            }
        } catch {
            Log.devices.error("Failed to register device listener: \(String(describing: error), privacy: .public)")
        }
    }
}
