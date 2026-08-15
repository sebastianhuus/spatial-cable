status: pending-verification
date: 2026-08-15
tagline: Hide known-incompatible outputs (built-in speakers) from the target device picker by transport type

# device-compatibility-filter

## Intent

`DeviceEnumerator.listPhysicalOutputDevices()` in [AudioOutputDevice.swift](../spatial-cable/CoreAudio/AudioOutputDevice.swift) currently lists every physical output device with no compatibility filtering beyond excluding aggregate/virtual transports — built-in MacBook Pro speakers and any Bluetooth device (AirPods, etc.) show up identically in the menu bar's output picker. This was the original project ask, noted as deferred in [global-audio-tap.md](global-audio-tap.md): restrict relay targets to devices that make sense for spatial audio, rather than offering every physical output including ones the user never wants to pick. The approach chosen is a transport-type blacklist: exclude known-incompatible transports (starting with built-in) while leaving everything else — Bluetooth devices in particular — listed exactly as today.

## Acceptance criteria

- [ ] Built-in MacBook Pro speakers no longer appear in the "Output" menu picker
- [ ] Bluetooth output devices (e.g. AirPods) continue to appear in the picker exactly as they do today — no regression from this filter
- [ ] Any other previously-listed non-built-in, non-aggregate, non-virtual device (wired/USB/etc.) continues to appear unless explicitly added to the blacklist during implementation
- [ ] If a device that's now blacklisted was previously persisted as the last-selected output (via `DeviceStore`), the app treats it as unavailable on launch the same way it already treats a disconnected device — clears the selection rather than silently allowing it, matching the existing hotplug-disconnect handling in `AppDelegate.reconcileOutputDevices(_:)`
- [ ] Toggling relay on/off and switching between devices still works with no regression to existing single-process or "All System Audio" tap modes

## Notes

**Chosen approach**: blacklist by `kAudioDeviceTransportType*`, not an allowlist by device name. Reasoning: fewer devices to enumerate/maintain (no list of AirPods/Beats model names that goes stale as Apple ships new hardware), and matches the observed reality that the only currently-visible unwanted output is the built-in speakers — everything else (Bluetooth) is fine to leave as-is.

**Implementation sketch** (from prior exploration, not yet built):
- Add the exclusion in [AudioOutputDevice.swift:20-22](../spatial-cable/CoreAudio/AudioOutputDevice.swift), alongside the existing `transportType != kAudioDeviceTransportTypeAggregate` / `!= kAudioDeviceTransportTypeVirtual` guards — same pattern, one more excluded case: `kAudioDeviceTransportTypeBuiltIn`.
- `readTransportType()` already exists on `AudioObjectID` ([AudioObjectID+Properties.swift](../spatial-cable/CoreAudio/AudioObjectID+Properties.swift)) and returns the raw `UInt32` constant — no new Core Audio plumbing needed for the built-in-only case.
- Open question for implementation: whether to blacklist only `kAudioDeviceTransportTypeBuiltIn`, or also wired/line/USB outputs. The user's own observation only flagged built-in speakers as unwanted; wired headphones/USB DACs weren't mentioned. Default to excluding only `BuiltIn` unless a concrete unwanted wired device turns up — easy to extend the same guard list later.
- Follow [device-hotplug.md](device-hotplug.md)'s hard rule: never silently redirect/select audio to a device the user didn't explicitly pick. This filter narrows the *offered* list; it must not auto-select a "compatible" fallback if the current selection gets filtered out — reuse the existing disconnect-handling path in `AppDelegate.reconcileOutputDevices(_:)` ([AppDelegate.swift:68-82](../spatial-cable/AppDelegate.swift)).
- Fail-soft convention: if `readTransportType()` throws for a given device, `listPhysicalOutputDevices()` already `continue`s past it (skips the device) rather than crashing or including it — no change needed to that behavior.
- No new persistence needed for this spec (unlike a user-configurable allowlist, which was considered and deferred) — the blacklist is a fixed set of transport-type constants in code, not user-editable state.
