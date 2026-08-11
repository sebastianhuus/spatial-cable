import AVFoundation
import CoreAudio
import Foundation

/// Owns the lifecycle of a single Core Audio process tap: create a tap for one target
/// process, wrap it in a private aggregate device, and pull audio from that aggregate via
/// an IOProc. Only one tap is ever active at a time for the MVP — selecting a new target
/// tears down and recreates.
final class AudioTapManager: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var lastError: String?

    /// The tap's native format, valid once `isRunning` is true. The relay engine needs this
    /// to build a matching AVAudioEngine graph.
    private(set) var currentFormat: AVAudioFormat?

    /// Called from a Core Audio realtime IO thread — do the minimum possible work here.
    var onAudioBuffer: ((AVAudioPCMBuffer) -> Void)?

    private var tapID: AudioObjectID = .unknown
    private var aggregateDeviceID: AudioObjectID = .unknown
    private var deviceProcID: AudioDeviceIOProcID?
    private var buffersReceived = 0

    func start(targetProcessID: AudioObjectID) {
        stop()
        Log.tap.info("start: targetProcessID=\(targetProcessID, privacy: .public)")

        do {
            let tapDescription = CATapDescription(stereoMixdownOfProcesses: [targetProcessID])
            tapDescription.uuid = UUID()
            // Without this, the source app keeps playing out its own path *and* we relay a
            // second copy — the user hears everything twice, out of phase.
            tapDescription.muteBehavior = .mutedWhenTapped

            var newTapID = AudioObjectID.unknown
            var status = AudioHardwareCreateProcessTap(tapDescription, &newTapID)
            guard status == noErr else {
                throw CoreAudioError.osStatus(status, "AudioHardwareCreateProcessTap")
            }
            tapID = newTapID
            Log.tap.info("AudioHardwareCreateProcessTap succeeded: tapID=\(newTapID, privacy: .public) uuid=\(tapDescription.uuid.uuidString, privacy: .public) muteBehavior=\(String(describing: tapDescription.muteBehavior), privacy: .public)")

            var streamDescription = try newTapID.readTapFormat()
            guard let format = AVAudioFormat(streamDescription: &streamDescription) else {
                throw CoreAudioError.osStatus(-1, "AVAudioFormat(streamDescription:)")
            }
            currentFormat = format
            let isInterleaved = (streamDescription.mFormatFlags & kAudioFormatFlagIsNonInterleaved) == 0
            Log.tap.info("Tap format: sampleRate=\(streamDescription.mSampleRate, privacy: .public) channels=\(streamDescription.mChannelsPerFrame, privacy: .public) bitsPerChannel=\(streamDescription.mBitsPerChannel, privacy: .public) interleaved=\(isInterleaved, privacy: .public)")

            let defaultOutputID = try AudioObjectID.readDefaultSystemOutputDevice()
            let outputUID = try defaultOutputID.readDeviceUID()
            Log.tap.info("Aggregate anchor device (kAudioHardwarePropertyDefaultSystemOutputDevice): id=\(defaultOutputID, privacy: .public) uid=\(outputUID, privacy: .public)")

            let aggregateDescription: [String: Any] = [
                kAudioAggregateDeviceNameKey: "spatial-cable-tap-\(targetProcessID)",
                kAudioAggregateDeviceUIDKey: UUID().uuidString,
                kAudioAggregateDeviceMainSubDeviceKey: outputUID,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceSubDeviceListKey: [
                    [kAudioSubDeviceUIDKey: outputUID]
                ],
                kAudioAggregateDeviceTapListKey: [
                    [
                        kAudioSubTapDriftCompensationKey: true,
                        kAudioSubTapUIDKey: tapDescription.uuid.uuidString
                    ]
                ]
            ]

            var newAggregateID = AudioObjectID.unknown
            status = AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &newAggregateID)
            guard status == noErr else {
                throw CoreAudioError.osStatus(status, "AudioHardwareCreateAggregateDevice")
            }
            aggregateDeviceID = newAggregateID
            Log.tap.info("AudioHardwareCreateAggregateDevice succeeded: aggregateDeviceID=\(newAggregateID, privacy: .public)")

            buffersReceived = 0
            var procID: AudioDeviceIOProcID?
            status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateDeviceID, nil) { [weak self] _, inputData, _, _, _ in
                guard let self, let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: inputData, deallocator: nil) else {
                    return
                }
                self.buffersReceived += 1
                if self.buffersReceived == 1 {
                    Log.tap.info("First buffer received: frameLength=\(buffer.frameLength, privacy: .public)")
                } else if self.buffersReceived % 500 == 0 {
                    Log.tap.debug("Buffers received so far: \(self.buffersReceived, privacy: .public)")
                }
                self.onAudioBuffer?(buffer)
            }
            guard status == noErr, let ioProcID = procID else {
                throw CoreAudioError.osStatus(status, "AudioDeviceCreateIOProcIDWithBlock")
            }
            deviceProcID = ioProcID

            status = AudioDeviceStart(aggregateDeviceID, ioProcID)
            guard status == noErr else {
                throw CoreAudioError.osStatus(status, "AudioDeviceStart")
            }

            isRunning = true
            lastError = nil
            Log.tap.info("Tap running for targetProcessID=\(targetProcessID, privacy: .public)")
        } catch {
            lastError = String(describing: error)
            Log.tap.error("start failed: \(String(describing: error), privacy: .public)")
            stop()
        }
    }

    func stop() {
        guard isRunning || tapID != .unknown || aggregateDeviceID != .unknown else { return }
        Log.tap.info("stop: buffersReceived=\(self.buffersReceived, privacy: .public)")
        if let procID = deviceProcID {
            AudioDeviceStop(aggregateDeviceID, procID)
            AudioDeviceDestroyIOProcID(aggregateDeviceID, procID)
            deviceProcID = nil
        }
        if aggregateDeviceID != .unknown {
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            aggregateDeviceID = .unknown
        }
        if tapID != .unknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = .unknown
        }
        currentFormat = nil
        isRunning = false
    }

    deinit {
        stop()
    }
}
