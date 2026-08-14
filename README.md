# spatial-cable

Menu bar app that relays system/app audio through Core Audio process taps to trigger native macOS spatialization.

## Build

Open `spatial-cable.xcodeproj` in Xcode, set your own Team under Signing & Capabilities, then ⌘R.

## Known Issues

There's a detune when you switch between Fixed and Head Tracking mode while listening to audio. This is caused by samples being dropped, causing a timing issue. Resolves itself within 1s. 