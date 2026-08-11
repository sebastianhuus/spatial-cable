import AppKit
import AVFoundation
import CoreAudio

/// Owns every long-lived Core Audio object and wires the tap → relay pipeline together.
/// Lives for the app's whole lifetime (unlike SwiftUI views), which is what Core Audio
/// device/tap handles need.
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    let processController = AudioProcessController()
    let tapManager = AudioTapManager()
    let relayEngine = AudioRelayEngine()
    // No longer used now that AudioRelayEngine targets a device directly via
    // AVSampleBufferAudioRenderer.audioOutputDeviceUniqueID — kept as a fallback in case
    // that turns out to be insufficient and default-output hijacking is needed again.
    let outputSwitcher = SystemOutputDeviceSwitcher()

    @Published private(set) var outputDevices: [AudioOutputDevice] = []
    @Published private(set) var selectedProcess: AudioProcess?
    @Published private(set) var selectedOutputDevice: AudioOutputDevice?
    @Published private(set) var isRelaying = false
    @Published private(set) var statusText = "Idle"

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        refreshOutputDevices()
        restoreSelection()
    }

    func applicationWillTerminate(_ notification: Notification) {
        if isRelaying {
            stopRelay()
        }
    }

    func refreshOutputDevices() {
        outputDevices = DeviceEnumerator.listPhysicalOutputDevices()
        if selectedOutputDevice == nil {
            selectedOutputDevice = outputDevices.first
        }
    }

    private func restoreSelection() {
        if let uid = DeviceStore.shared.lastOutputDeviceUID {
            selectedOutputDevice = outputDevices.first { $0.uid == uid } ?? selectedOutputDevice
        }
        if let bundleID = DeviceStore.shared.lastTargetBundleID {
            selectedProcess = processController.processes.first { $0.bundleID == bundleID }
        }
    }

    func selectProcess(_ process: AudioProcess) {
        selectedProcess = process
        DeviceStore.shared.lastTargetBundleID = process.bundleID
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
        guard let process = selectedProcess, let device = selectedOutputDevice else {
            statusText = "Pick a source and an output device first"
            return
        }
        Log.app.info("startRelay: process=\(process.name, privacy: .public) (pid=\(process.pid, privacy: .public)) -> device=\(device.name, privacy: .public) (uid=\(device.uid, privacy: .public))")

        tapManager.onAudioBuffer = { [weak self] buffer in
            self?.relayEngine.enqueue(buffer)
        }

        tapManager.start(targetProcessID: process.id)

        guard tapManager.isRunning, let format = tapManager.currentFormat else {
            statusText = tapManager.lastError ?? "Failed to start tap"
            isRelaying = false
            return
        }

        relayEngine.start(format: format, outputDeviceUID: device.uid)

        isRelaying = relayEngine.isRunning
        if isRelaying {
            statusText = "Relaying \(process.name) → \(device.name)"
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
