import CoreAudio
import Foundation

/// Temporarily makes a chosen device the system's default output device, and restores
/// whatever was default before, on stop.
///
/// This turned out to be necessary, not optional: macOS's spatializer only engages for
/// audio flowing through the actual default-output pipeline. An AVAudioEngine graph that
/// explicitly targets a *non-default* physical device via
/// kAudioOutputUnitProperty_CurrentDevice does not get spatialized — confirmed empirically,
/// since even Safari (which spatializes fine as plain default output) sounded flat and
/// reported "Spatial Audio not available" when relayed to a pinned non-default device.
///
/// Side effect worth knowing: while active, this redirects *all* system audio to the
/// target device, not just the tapped app's — that's inherent to how default output works,
/// not a bug.
final class SystemOutputDeviceSwitcher {
    private var savedDefaultDeviceID: AudioObjectID?

    /// True once we've swapped the default device and are holding a previous value to
    /// restore — distinguishes "haven't activated" from "activated but somehow read back
    /// our own target as the saved value" (which would make restore() a no-op forever).
    var isActive: Bool { savedDefaultDeviceID != nil }

    func activate(targetDeviceID: AudioObjectID) throws {
        if savedDefaultDeviceID == nil {
            let saved = try AudioObjectID.readDefaultOutputDevice()
            savedDefaultDeviceID = saved
            let savedName = (try? saved.readDeviceName()) ?? "?"
            Log.outputSwitcher.info("Saved previous default output: id=\(saved, privacy: .public) name=\(savedName, privacy: .public)")
        }
        let targetName = (try? targetDeviceID.readDeviceName()) ?? "?"
        do {
            try AudioObjectID.setDefaultOutputDevice(targetDeviceID)
            Log.outputSwitcher.info("Default output set to: id=\(targetDeviceID, privacy: .public) name=\(targetName, privacy: .public)")
        } catch {
            Log.outputSwitcher.error("Failed to set default output to id=\(targetDeviceID, privacy: .public) name=\(targetName, privacy: .public): \(String(describing: error), privacy: .public)")
            throw error
        }
    }

    func restore() {
        guard let saved = savedDefaultDeviceID else { return }
        let savedName = (try? saved.readDeviceName()) ?? "?"
        do {
            try AudioObjectID.setDefaultOutputDevice(saved)
            Log.outputSwitcher.info("Restored default output to: id=\(saved, privacy: .public) name=\(savedName, privacy: .public)")
        } catch {
            Log.outputSwitcher.error("Failed to restore default output to id=\(saved, privacy: .public) name=\(savedName, privacy: .public): \(String(describing: error), privacy: .public)")
        }
        savedDefaultDeviceID = nil
    }
}
