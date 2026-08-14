status: discarded
date: 2026-08-13
tagline: Stop the tap's capture clock from sharing (and stalling with) the AirPods render target — tried, made things worse, reverted

# tap-clock-decoupling

## Intent

Diagnostic/investigation-driven spec, not a from-scratch feature — this documents *why* a change is being made to already-working code, not a new capability. Full investigation history (log excerpts, timestamps, reasoning) lives in the project memory file (`spatial-cable-project.md`); this spec tracks the fix itself and whether it worked.

Users (confirmed by the project owner, who doesn't hear this on native Apple apps) hear an audible pitch-bend/warble when toggling macOS's Spatial Audio mode (Fixed/Head-Tracked/Off) in Control Center while spatial-cable is relaying. Investigation this session (two rounds of instrumentation — `SampleRateProbe.swift`, plus buffer-arrival-gap logging added to `AudioTapManager`'s IOProc) found the mechanism:

- Toggling Spatial Audio mode makes Apple's own `BTAudioHALPlugin` (inside `coreaudiod`) tear down and rebuild the AirPods' internal Spatial Audio Queue, producing a real `StopIO`/`StartIO` cycle on the physical device — confirmed directly in `coreaudiod`'s own logs, timestamped to the same moment as `AVSampleBufferAudioRendererWasFlushedAutomaticallyNotification` firing on our render side.
- The `actualSampleRate` of both the tap's aggregate device and the physical output device never deviates from nominal during this — ruling out a gradual drift-compensation ramp as the mechanism.
- The tap's own buffer-arrival timing *does* show real gaps exactly coincident with those events: 96–320ms with no captured audio, confirmed content loss, not just a presentation-timeline renumbering.
- Root cause of why this is audible here and apparently isn't in native apps: `AudioTapManager` builds its capture aggregate device with `kAudioHardwarePropertyDefaultSystemOutputDevice` (in practice, the AirPods) as `kAudioAggregateDeviceMainSubDeviceKey` — the *same physical device* `AudioRelayEngine` targets for output. A native app only depends on that device once (render). spatial-cable depends on it twice (capture *and* render), so the same driver-level disruption hits it twice.

Planned fix: anchor the tap's aggregate device to a different, stable device instead of whatever the render target happens to be, so the capture clock stops being coupled to the AirPods' own `StopIO`/`StartIO` churn. Existing drift compensation (`kAudioSubTapDriftCompensationKey: true`, already enabled) should reconcile the resulting clock mismatch between the aggregate's new anchor and the process audio actually being tapped.

## Acceptance criteria

- [x] Repeating the same Spatial-Audio-mode-toggle repro (relay running, toggle Fixed/Head-Tracked/Off in Control Center a few times) no longer produces `Buffer arrival gap` log lines over ~15ms clustered around a mode switch — confirmed: the built-in-output anchor did eliminate those transient capture gaps (verified in logs, no gap/flush lines after the fix engaged in the test session)
- [x] The audible bend/warble is reduced or gone by ear on the same repro — **failed**: still audible, and the user reported it now sounds *stronger*
- [ ] Existing single-process tap mode and "All System Audio" mode both continue to work with no regression — not reached; discarded before this was checked

## Postmortem — why this was discarded

The transient-gap fix worked exactly as intended (see checked box above), but it traded the original problem for a worse one: **a persistent, sustained detune that returns per Spatial Audio mode (notably when Off)**, rather than the original brief transient bend at the switch moment. User feedback: "the detune is permanent per listening mode now, returning when spatial audio is OFF" — and it reproduced with *no* `Buffer arrival gap` or `flushed automatically` log lines at all, meaning the original StopIO/StartIO mechanism this spec targeted genuinely wasn't firing anymore — this is a different, second problem, introduced by the fix.

**Why**: built-in output and the AirPods are independent physical clocks with no shared reference. Before this change, the tap's aggregate and the renderer's target were forced onto the *same* clock (the AirPods itself) — so despite the transient stalls, there was never a standing mismatch between captured and expected audio. Anchoring the aggregate to built-in output removed that transient coupling but introduced a continuous one: `kAudioSubTapDriftCompensationKey` (still enabled) has to resample continuously to reconcile two genuinely different clocks, which is itself an audible, sustained pitch/time distortion — worse to listen to than an occasional multi-hundred-ms stall, even though each individual correction is smaller. The per-mode variance (worse when Off) is consistent with the AirPods negotiating different internal timing/buffering by mode over the Bluetooth link, changing the *size* of the mismatch against a now-unrelated fixed clock.

**Reverted** — `AudioTapManager` is back to anchoring its aggregate on `kAudioHardwarePropertyDefaultSystemOutputDevice` (i.e., the same device the renderer targets), and `AudioObjectID.findBuiltInOutputDevice()` was removed as dead code. The original transient-stall problem (this spec's actual target) is real and still present; the fix attempt for it now lives in `.spox/duck-on-flush.md`, which masks the stall instead of trying to avoid it by changing clock domains.

**Lesson for next time a fix here is tempting**: anything that puts the tap's capture clock and the render target on different physical devices is suspect by default — verify with `SampleRateProbe` over a longer, steady-state window (not just the first ~15s) *and* by ear across more than one Spatial Audio mode before considering it settled, since this failure mode was silent to the transient-focused instrumentation and only surfaced through sustained listening.

## Notes

- Relevant files: [AudioTapManager.swift](../spatial-cable/CoreAudio/AudioTapManager.swift) (the actual change — `start()`'s aggregate device description, currently anchored to `kAudioHardwarePropertyDefaultSystemOutputDevice` via `AudioObjectID.readDefaultSystemOutputDevice()`), [SampleRateProbe.swift](../spatial-cable/CoreAudio/SampleRateProbe.swift) and the gap-detection block in `AudioTapManager`'s IOProc (both diagnostic instrumentation added this session — safe to strip once this investigation concludes, per `SampleRateProbe`'s own doc comment).
- Candidate stable anchor device: the Mac's built-in output — always present, not Bluetooth, not subject to Spatial Audio Control Center churn. Needs a real device UID lookup at tap-start time (built-in output isn't guaranteed to have a fixed `AudioObjectID` across boots, same reasoning already applied elsewhere in this codebase for device identification — always resolve by UID, never cache an ID).
- Open question: whether decoupling the anchor changes tap-warmup latency or introduces any new drift-compensation artifacts of its own — worth listening for regressions here, not just confirming the original bug is gone.
- If built-in output isn't present (e.g. a Mac without one, or it's disabled), needs a fallback — matching the existing pattern of graceful degradation rather than a hard failure.
