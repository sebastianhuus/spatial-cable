status: draft
date: 2026-08-11
tagline: Tap all system audio at once instead of one selected process, so everything gets spatialized

# global-audio-tap

## Intent

Right now spatial-cable taps and relays exactly one selected process's audio at a time. The goal of this feature is a second source mode — "All System Audio" — that captures the entire system audio mix via a Core Audio global process tap, so every app playing sound gets spatialized simultaneously, not just whichever single app is currently selected. This is the original "cable" vision the project started from (a BlackHole-style catch-all), now buildable on top of the already-validated tap → `AVSampleBufferAudioRenderer` pipeline.

## Acceptance criteria

- [ ] A new "All System Audio" option is selectable as the relay source in the menu bar, alongside the existing per-process picker (not a replacement for it)
- [ ] With "All System Audio" selected and relaying active, audio from two or more simultaneously-playing apps (e.g. Spotify + a Safari tab) is all audible and spatialized on the target output device at once
- [ ] Starting/stopping relay repeatedly in "All System Audio" mode produces no feedback loop, echo, or runaway audio — spatial-cable's own relayed output must not be picked back up by its own tap
- [ ] Switching between "All System Audio" mode and a specific single-process selection works cleanly in both directions without requiring an app restart
- [ ] The existing single-process tap mode continues to work exactly as it does today (no regression)

## Notes

**Planned technical approach** (from prior design discussion, not yet implemented):
- Use `CATapDescription`'s global-tap initializer (`stereoGlobalTapButExcludeProcesses:`) instead of the current `stereoMixdownOfProcesses:` used in [AudioTapManager.swift](../spatial-cable/CoreAudio/AudioTapManager.swift). This captures everything headed for default output as one stream, muted at source the same way the per-process tap works today.
- **Must exclude spatial-cable's own process** from the global tap's process list, or its own relayed output — itself a process on the Mac — gets captured by the same tap and feeds back into itself. No existing helper resolves "this app's own `AudioObjectID`" today; `ProcessInfo.processInfo.processIdentifier` cross-referenced against the process list in `AudioProcess.swift` is the natural way to get it, following the same pattern `AudioProcessController` already uses for other processes.
- [AudioRelayEngine.swift](../spatial-cable/Relay/AudioRelayEngine.swift) is confirmed source-agnostic (only handles `AVAudioPCMBuffer` in / device UID target) — should need zero changes.
- [AppDelegate.swift](../spatial-cable/AppDelegate.swift) currently requires both `selectedProcess` and `selectedOutputDevice` to start relaying; needs a mode concept (e.g. `enum RelaySource { case process(AudioProcess), allSystemAudio }`) rather than overloading `selectedProcess` with a sentinel value.
- [MenuBarContentView.swift](../spatial-cable/Menu/MenuBarContentView.swift) already has a `checkmarkLabel` helper for selection state — a new "All System Audio" menu item should reuse it for visual consistency with the existing process/device pickers.
- Persistence: `DeviceStore` persists selections by stable identifier only, never name/index. A persisted "tap mode" flag should follow the same `spatial-cable.*` `UserDefaults` key convention rather than overloading `lastTargetBundleID`.
- Conventions to match: `AudioTapManager`'s existing shape (`ObservableObject`, `@Published isRunning`/`lastError`, `start()`/`stop()`, `deinit { stop() }`, every Core Audio call wrapped via `CoreAudioError.osStatus`, a dedicated `Log.*` category in `Logging.swift` for any new component).

**Deferred, lower priority than this spec** (noted for later, not part of this feature):
- Output-device blacklist UI — the original project ask (restrict targets to AirPods Max/Pro specifically), still not built.
- Deleting the now-dead `SystemOutputDeviceSwitcher.swift` (superseded by `audioOutputDeviceUniqueID` targeting, left in the tree unused).

**Open question for next session**: whether "All System Audio" and a specific single process should ever be simultaneously active (probably not for v1 — one tap active at a time, matching the existing "only one tap active" constraint), and how the menu should visually distinguish "no source selected" from "All System Audio selected" from "specific process selected."
