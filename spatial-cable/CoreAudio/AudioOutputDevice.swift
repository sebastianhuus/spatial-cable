import CoreAudio
import Foundation

/// A real, physical (or otherwise non-virtual) output device — what populates the output
/// picker. Deliberately excludes aggregate/virtual transports so the relay can never target
/// its own tap plumbing or another app's virtual cable.
struct AudioOutputDevice: Identifiable, Hashable {
    let id: AudioObjectID
    let uid: String
    let name: String
}

enum DeviceEnumerator {
    static func listPhysicalOutputDevices() -> [AudioOutputDevice] {
        guard let deviceIDs = try? AudioObjectID.readDeviceList() else { return [] }

        var result: [AudioOutputDevice] = []
        for deviceID in deviceIDs {
            guard deviceID.hasOutputStreams() else { continue }
            guard let transportType = try? deviceID.readTransportType() else { continue }
            guard transportType != kAudioDeviceTransportTypeAggregate,
                  transportType != kAudioDeviceTransportTypeVirtual else { continue }
            guard let uid = try? deviceID.readDeviceUID(),
                  let name = try? deviceID.readDeviceName() else { continue }

            result.append(AudioOutputDevice(id: deviceID, uid: uid, name: name))
        }
        return result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
