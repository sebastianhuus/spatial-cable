import os

/// Unified-logging categories for the app. Using os.Logger (not NSLog/print) means logs are
/// visible live in Xcode's console, in Console.app, and can be followed from the shell with
/// `log stream` — the same data both a human and an outside process can inspect, instead of
/// having to infer what happened from audible behavior alone.
///
/// Every interpolated value below is marked `privacy: .public` deliberately: unified logging
/// redacts dynamic string interpolations as `<private>` by default outside of a debugger
/// attached via Xcode, which would make `log stream`/`log show` output useless for this kind
/// of debugging. Nothing logged here (device names, formats, PIDs) is sensitive.
enum Log {
    static let subsystem = "com.sebastianhuus.spatial-cable"

    static let app = Logger(subsystem: subsystem, category: "App")
    static let tap = Logger(subsystem: subsystem, category: "Tap")
    static let relay = Logger(subsystem: subsystem, category: "Relay")
    static let outputSwitcher = Logger(subsystem: subsystem, category: "OutputSwitcher")
}
