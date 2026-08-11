import AppKit
import CoreAudio
import Darwin
import Foundation

/// A running process that Core Audio knows has (or could have) an audio render path —
/// this is the source picker's data model.
struct AudioProcess: Identifiable, Hashable {
    let id: AudioObjectID
    let pid: pid_t
    let name: String
    let bundleID: String?
}

/// Enumerates tappable processes via kAudioHardwarePropertyProcessObjectList, cross-referenced
/// against NSWorkspace for human-friendly names, and keeps the list live as apps launch/quit.
final class AudioProcessController: ObservableObject {
    @Published private(set) var processes: [AudioProcess] = []

    private var observers: [NSObjectProtocol] = []

    init() {
        refresh()
        observeWorkspace()
    }

    deinit {
        let center = NSWorkspace.shared.notificationCenter
        observers.forEach { center.removeObserver($0) }
    }

    func refresh() {
        do {
            let objectIDs = try AudioObjectID.readProcessList()
            var seenPIDs = Set<pid_t>()
            var result: [AudioProcess] = []

            for objectID in objectIDs {
                guard let pid = try? objectID.readProcessPID(), pid > 0 else { continue }
                guard !seenPIDs.contains(pid) else { continue }
                seenPIDs.insert(pid)

                if let app = NSRunningApplication(processIdentifier: pid) {
                    let name = app.localizedName ?? app.bundleIdentifier ?? "PID \(pid)"
                    result.append(AudioProcess(id: objectID, pid: pid, name: name, bundleID: app.bundleIdentifier))
                } else if let name = Self.processName(for: pid) {
                    result.append(AudioProcess(id: objectID, pid: pid, name: name, bundleID: nil))
                }
            }

            processes = result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        } catch {
            NSLog("AudioProcessController: failed to read process list: \(error)")
        }
    }

    private func observeWorkspace() {
        let center = NSWorkspace.shared.notificationCenter
        let launch = center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            self?.refresh()
        }
        let terminate = center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            self?.refresh()
        }
        observers = [launch, terminate]
    }

    private static func processName(for pid: pid_t) -> String? {
        var nameBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let length = proc_name(pid, &nameBuffer, UInt32(nameBuffer.count))
        guard length > 0 else { return nil }
        return String(cString: nameBuffer)
    }
}
