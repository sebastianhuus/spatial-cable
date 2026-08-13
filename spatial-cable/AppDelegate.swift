import AppKit
import AVFoundation
import Combine
import CoreAudio

/// Owns every long-lived Core Audio object and wires the tap → relay pipeline together.
/// Lives for the app's whole lifetime (unlike SwiftUI views), which is what Core Audio
/// device/tap handles need.
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    /// What's currently selected as the relay source — either one specific process, or the
    /// whole system mix. Only one is ever active at a time, matching the "only one tap active"
    /// constraint `AudioTapManager` already enforces.
    enum RelaySource: Equatable {
        case process(AudioProcess)
        case allSystemAudio
    }

    let processController = AudioProcessController()
    let tapManager = AudioTapManager()
    let relayEngine = AudioRelayEngine()
    let deviceWatcher = AudioDeviceWatcher()
    // No longer used now that AudioRelayEngine targets a device directly via
    // AVSampleBufferAudioRenderer.audioOutputDeviceUniqueID — kept as a fallback in case
    // that turns out to be insufficient and default-output hijacking is needed again.
    let outputSwitcher = SystemOutputDeviceSwitcher()

    private var deviceWatcherCancellable: AnyCancellable?

    @Published private(set) var outputDevices: [AudioOutputDevice] = []
    @Published private(set) var relaySource: RelaySource?
    @Published private(set) var selectedOutputDevice: AudioOutputDevice?
    @Published private(set) var isRelaying = false
    @Published private(set) var statusText = "Idle"

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        refreshOutputDevices()
        restoreSelection()
        if selectedOutputDevice == nil {
            selectedOutputDevice = outputDevices.first
        }
        deviceWatcherCancellable = deviceWatcher.$devices
            .dropFirst() // initial value came from deviceWatcher's own init; refreshOutputDevices() above already covered it
            .sink { [weak self] devices in
                self?.reconcileOutputDevices(devices)
            }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if isRelaying {
            stopRelay()
        }
    }

    /// Manually re-triggers the device watcher and reconciles — the "Refresh Devices" button's
    /// entry point, and also called once on launch. Hotplug events reconcile automatically via
    /// deviceWatcherCancellable; this exists as an explicit fallback/no-op if detection is current.
    func refreshOutputDevices() {
        deviceWatcher.refresh()
        reconcileOutputDevices(deviceWatcher.devices)
    }

    /// Applies a freshly-known device list: publishes it, and if the currently selected device is
    /// no longer present, clears the selection (stopping the relay first if it was active). Never
    /// auto-picks a replacement — matches the app's rule of never silently redirecting audio to a
    /// device the user didn't explicitly choose. A replugged device just reappears in the list;
    /// re-selecting it is always an explicit user action.
    private func reconcileOutputDevices(_ devices: [AudioOutputDevice]) {
        outputDevices = devices

        guard let selected = selectedOutputDevice,
              !devices.contains(where: { $0.uid == selected.uid }) else {
            return
        }

        Log.devices.info("Selected output device disconnected: \(selected.name, privacy: .public)")
        if isRelaying {
            stopRelay()
            statusText = "Stopped — \(selected.name) disconnected"
        }
        selectedOutputDevice = nil
    }

    private func restoreSelection() {
        if let uid = DeviceStore.shared.lastOutputDeviceUID {
            selectedOutputDevice = outputDevices.first { $0.uid == uid } ?? selectedOutputDevice
        }
        switch DeviceStore.shared.relaySourceMode {
        case .allSystemAudio:
            relaySource = .allSystemAudio
        case .process, nil:
            if let bundleID = DeviceStore.shared.lastTargetBundleID,
               let process = processController.processes.first(where: { $0.bundleID == bundleID }) {
                relaySource = .process(process)
            }
        }
    }

    func selectProcess(_ process: AudioProcess) {
        relaySource = .process(process)
        DeviceStore.shared.lastTargetBundleID = process.bundleID
        DeviceStore.shared.relaySourceMode = .process
        if isRelaying {
            startRelay()
        }
    }

    func selectAllSystemAudio() {
        relaySource = .allSystemAudio
        DeviceStore.shared.relaySourceMode = .allSystemAudio
        if isRelaying {
            startRelay()
        }
    }

    func selectOutputDevice(_ device: AudioOutputDevice) {
        selectedOutputDevice = device
        DeviceStore.shared.lastOutputDeviceUID = device.uid
        if isRelaying {
            relayEngine.setOutputDevice(uid: device.uid)
        }
    }

    func toggleRelay() {
        if isRelaying {
            stopRelay()
        } else {
            startRelay()
        }
    }

    private func startRelay() {
        guard let source = relaySource, let device = selectedOutputDevice else {
            statusText = "Pick a source and an output device first"
            return
        }

        let tapTarget: AudioTapManager.TapTarget
        let sourceLabel: String
        switch source {
        case .process(let process):
            tapTarget = .process(process.id)
            sourceLabel = process.name
            Log.app.info("startRelay: process=\(process.name, privacy: .public) (pid=\(process.pid, privacy: .public)) -> device=\(device.name, privacy: .public) (uid=\(device.uid, privacy: .public))")
        case .allSystemAudio:
            tapTarget = .allSystemAudio
            sourceLabel = "All System Audio"
            Log.app.info("startRelay: allSystemAudio -> device=\(device.name, privacy: .public) (uid=\(device.uid, privacy: .public))")
        }

        tapManager.onAudioBuffer = { [weak self] buffer in
            self?.relayEngine.enqueue(buffer)
        }

        tapManager.start(target: tapTarget)

        guard tapManager.isRunning, let format = tapManager.currentFormat else {
            statusText = tapManager.lastError ?? "Failed to start tap"
            isRelaying = false
            return
        }

        relayEngine.start(format: format, outputDeviceUID: device.uid)

        isRelaying = relayEngine.isRunning
        if isRelaying {
            statusText = "Relaying \(sourceLabel) → \(device.name)"
            Log.app.info("Relay started successfully: \(self.statusText, privacy: .public)")
        } else {
            statusText = relayEngine.lastError ?? "Failed to start relay"
            Log.app.error("Relay failed to start: \(self.statusText, privacy: .public)")
            tapManager.stop()
        }
    }

    private func stopRelay() {
        Log.app.info("stopRelay")
        tapManager.stop()
        relayEngine.stop()
        isRelaying = false
        statusText = "Idle"
    }
}
