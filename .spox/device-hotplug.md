status: completed
date: 2026-08-12
tagline: React live to output devices connecting/disconnecting instead of going stale until a manual refresh

# device-hotplug

## Intent

spatial-cable currently has no way to notice that the physical output device it's relaying to has been unplugged, or that a new device has just been plugged in — the device list (`DeviceEnumerator.listPhysicalOutputDevices()`) is only ever re-read on launch or via the manual "Refresh Devices" button in [MenuBarContentView.swift](../spatial-cable/Menu/MenuBarContentView.swift). If the selected device (e.g. AirPods) disconnects mid-relay, the app has no idea and keeps trying to feed audio into a device that's gone. This is the first Core Audio *listener* code the project will need — everything today is one-shot reads (see `AudioObjectID.readDeviceList()` in [AudioObjectID+Properties.swift:35](../spatial-cable/CoreAudio/AudioObjectID+Properties.swift)), not live device-list watching.

## Acceptance criteria

- [x] When the currently-targeted output device disconnects while relaying is active, the relay stops cleanly and the menu bar status text reflects that the device disconnected (no silent failure, no audio left trying to route into a dead device)
- [x] When a new output device is connected, it appears in the output-device picker automatically — no manual "Refresh Devices" click required
- [x] When a device disconnects while relaying is *not* active (idle, or a different device is selected), the output-device picker updates to drop it without user action
- [x] The existing manual "Refresh Devices" button continues to work as a fallback/no-op if hotplug detection is already current

## Notes

**Scope decision from this session**: disconnect triggers a clean stop, not an automatic fallback to a different device. Matches the app's existing pattern of never silently redirecting audio to a device the user didn't explicitly pick (mirrors how `selectedOutputDevice` is only ever set by explicit user action or exact-UID restore, never guessed). No auto-reselect-on-replug behavior is in scope here either — left as an open question below.

**Planned technical approach** (from exploration this session, not yet implemented):
- No existing Core Audio property-listener code anywhere in the project (`AudioObjectAddPropertyListener`/`AudioObjectRemovePropertyListener` are never called) — this feature adds the first one, watching `kAudioHardwarePropertyDevices` on `AudioObjectID.system`.
- Closest structural precedent is [AudioProcessController](../spatial-cable/CoreAudio/AudioProcess.swift) (lines 17-74): `init()` calls `refresh()` then registers observers (there, `NSWorkspace` launch/terminate notifications; here, a Core Audio property listener), with teardown in `deinit`. A comparable device-watching component should follow the same shape rather than inventing a new one.
- [AudioRelayEngine.recreateRenderer()](../spatial-cable/Relay/AudioRelayEngine.swift) (lines 246-261) is the closest existing "device state changed under us" recovery pattern (tear down and rebuild rather than patch in place) even though it's triggered by AVFoundation notifications, not Core Audio ones — worth reading before implementing this.
- [AppDelegate.refreshOutputDevices()](../spatial-cable/AppDelegate.swift) (lines 43-48) is the existing manual entry point; hotplug detection should likely call into this same method rather than duplicating its logic.
- Every raw Core Audio call in the project wraps its `OSStatus` via `CoreAudioError.osStatus` ([AudioObjectID+Properties.swift](../spatial-cable/CoreAudio/AudioObjectID+Properties.swift)) — the new property-listener registration should follow suit.
- A new `Log.*` category (e.g. `Log.devices`) in [Logging.swift](../spatial-cable/Logging.swift) fits the existing per-component logging convention.
- Needs a decision on where `selectedOutputDevice` should point after a disconnect-triggered stop — likely `nil` (forcing an explicit re-pick), but worth confirming against `DeviceStore.lastOutputDeviceUID` persistence behavior when implementing.

**Resolved (2026-08-13)**: replugging the exact previously-selected device does *not* auto-reselect it — it just reappears in the picker like any other device, and the user re-picks explicitly. `selectedOutputDevice` clears to `nil` on a disconnect of the selected device; `DeviceStore.lastOutputDeviceUID` is left untouched (it's a launch-restore preference, not a live-selection mirror). Implemented in `AudioDeviceWatcher.swift` (new), `AudioObjectID+Properties.swift` (`addPropertyListener`/`removePropertyListener`), and `AppDelegate.reconcileOutputDevices(_:)`. Verified working by the user on real hardware.
