import AVFoundation
import CoreMedia
import Foundation

/// Plays tapped audio back out through AVFoundation's actual media-playback pipeline,
/// targeted directly at a chosen physical device.
///
/// This replaced an AVAudioEngine-based relay (even with AVAudioEnvironmentNode inserted)
/// after confirming empirically that neither engaged macOS's spatializer: Safari and a
/// relayed app both playing to the same default-output device simultaneously showed only
/// Safari spatializing, proving the differentiator wasn't the device or default-output
/// status but the render path itself. Per Apple's own docs, the Spatial Audio control in
/// Control Center is only available for audio going through AVPlayer or
/// AVSampleBufferAudioRenderer — a raw AVAudioEngine graph, regardless of node topology,
/// isn't part of that pipeline at all. AVSampleBufferAudioRenderer also exposes
/// audioOutputDeviceUniqueID, which targets a specific physical device directly — so unlike
/// the AVAudioEngine version, this doesn't need to hijack the system default output device.
final class AudioRelayEngine: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var lastError: String?

    /// Reassigned (not just reconfigured) whenever recovery requires a fresh connection to
    /// the device — see recreateRenderer(). Guarded by rendererLock since it's read from
    /// enqueue() (called on the tap's realtime IOProc thread) and written from notification
    /// handlers (delivered on an arbitrary thread, per Apple's docs).
    private var renderer = AVSampleBufferAudioRenderer()
    private let rendererLock = NSLock()
    private let synchronizer = AVSampleBufferRenderSynchronizer()
    private var formatDescription: CMAudioFormatDescription?
    private var sampleRate: Double = 0
    private var buffersEnqueued = 0
    private var currentOutputDeviceUID: String?

    /// The synchronizer's rate is only ever set once, the moment the first real buffer
    /// shows up — the tap can take over a second to warm up, and starting the clock
    /// immediately at start() meant every buffer arrived "late" relative to an
    /// already-running synchronizer and was silently dropped.
    private var hasStartedSynchronizer = false

    /// Enqueued timestamps are anchored to the synchronizer's *current* time, re-anchored
    /// whenever recovery invalidates our old numbering — continuing a monotonic counter
    /// across a flush/renderer swap means new buffers keep landing at stale timestamps
    /// relative to a clock that kept running.
    private var needsAnchor = true
    private var anchorTime: CMTime = .zero
    private var samplesSinceAnchor: Int64 = 0

    private var statusObservation: NSKeyValueObservation?
    private var errorObservation: NSKeyValueObservation?
    private var outputConfigChangeObserver: NSObjectProtocol?
    private var autoFlushObserver: NSObjectProtocol?

    func start(format: AVAudioFormat, outputDeviceUID: String) {
        stop()
        Log.relay.info("start: incoming format sampleRate=\(format.sampleRate, privacy: .public) channels=\(format.channelCount, privacy: .public) interleaved=\(format.isInterleaved, privacy: .public)")

        var asbd = format.streamDescription.pointee
        var formatDesc: CMAudioFormatDescription?
        let status = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDesc
        )
        guard status == noErr, let formatDesc else {
            lastError = "CMAudioFormatDescriptionCreate failed: OSStatus \(status)"
            Log.relay.error("\(self.lastError!, privacy: .public)")
            return
        }
        formatDescription = formatDesc
        sampleRate = format.sampleRate
        buffersEnqueued = 0
        needsAnchor = true
        anchorTime = .zero
        samplesSinceAnchor = 0
        hasStartedSynchronizer = false
        currentOutputDeviceUID = outputDeviceUID

        let newRenderer = AVSampleBufferAudioRenderer()
        configure(newRenderer, outputDeviceUID: outputDeviceUID)
        rendererLock.lock()
        renderer = newRenderer
        rendererLock.unlock()
        attachObservers(to: newRenderer)
        synchronizer.addRenderer(newRenderer)

        isRunning = true
        lastError = nil
        Log.relay.info("Renderer attached, waiting for first buffer to start synchronizer")
    }

    /// Switch the physical target device live, without tearing down the tap.
    func setOutputDevice(uid: String) {
        currentOutputDeviceUID = uid
        currentRenderer.audioOutputDeviceUniqueID = uid
        Log.relay.info("audioOutputDeviceUniqueID updated to \(uid, privacy: .public)")
    }

    /// Feed a buffer captured from the tap's IOProc.
    func enqueue(_ buffer: AVAudioPCMBuffer) {
        guard isRunning, let formatDescription else { return }
        let renderer = currentRenderer
        guard renderer.isReadyForMoreMediaData else {
            Log.relay.debug("Renderer not ready for more data, dropping buffer")
            return
        }

        if needsAnchor {
            anchorTime = synchronizer.currentTime()
            samplesSinceAnchor = 0
            needsAnchor = false
            Log.relay.info("Anchored to time=\(self.anchorTime.value, privacy: .public)/\(self.anchorTime.timescale, privacy: .public)")
        }
        let presentationTime = CMTimeAdd(anchorTime, CMTime(value: samplesSinceAnchor, timescale: Int32(sampleRate)))

        guard let sampleBuffer = makeSampleBuffer(from: buffer, formatDescription: formatDescription, presentationTime: presentationTime) else {
            Log.relay.error("Failed to build CMSampleBuffer from captured audio")
            return
        }
        renderer.enqueue(sampleBuffer)

        if !hasStartedSynchronizer {
            synchronizer.setRate(1.0, time: presentationTime)
            hasStartedSynchronizer = true
            Log.relay.info("Synchronizer started at time=\(presentationTime.value, privacy: .public)/\(presentationTime.timescale, privacy: .public)")
        }

        samplesSinceAnchor += Int64(buffer.frameLength)
        buffersEnqueued += 1
        if buffersEnqueued == 1 {
            Log.relay.info("First sample buffer enqueued: frameLength=\(buffer.frameLength, privacy: .public)")
        } else if buffersEnqueued % 500 == 0 {
            Log.relay.debug("Buffers enqueued so far: \(self.buffersEnqueued, privacy: .public)")
        }
    }

    private var currentRenderer: AVSampleBufferAudioRenderer {
        rendererLock.lock()
        defer { rendererLock.unlock() }
        return renderer
    }

    private func makeSampleBuffer(from buffer: AVAudioPCMBuffer, formatDescription: CMAudioFormatDescription, presentationTime: CMTime) -> CMSampleBuffer? {
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: Int32(sampleRate)),
            presentationTimeStamp: presentationTime,
            decodeTimeStamp: .invalid
        )

        var sampleBuffer: CMSampleBuffer?
        var status = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: nil,
            dataReady: false,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDescription,
            sampleCount: CMItemCount(buffer.frameLength),
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr, let sampleBuffer else {
            Log.relay.error("CMSampleBufferCreate failed: OSStatus \(status, privacy: .public)")
            return nil
        }

        status = CMSampleBufferSetDataBufferFromAudioBufferList(
            sampleBuffer,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0,
            bufferList: buffer.audioBufferList
        )
        guard status == noErr else {
            Log.relay.error("CMSampleBufferSetDataBufferFromAudioBufferList failed: OSStatus \(status, privacy: .public)")
            return nil
        }

        return sampleBuffer
    }

    private func configure(_ renderer: AVSampleBufferAudioRenderer, outputDeviceUID: String) {
        renderer.audioOutputDeviceUniqueID = outputDeviceUID
        // Our tap format is plain 2-channel stereo, not multichannel/Atmos — .multichannel
        // (the default) would ignore it. This is the property Apple's docs point to as the
        // actual opt-in for spatializing ordinary stereo content.
        renderer.allowedAudioSpatializationFormats = .monoStereoAndMultichannel
        Log.relay.info("Renderer configured: audioOutputDeviceUniqueID=\(outputDeviceUID, privacy: .public) allowedAudioSpatializationFormats=monoStereoAndMultichannel")
    }

    private func attachObservers(to renderer: AVSampleBufferAudioRenderer) {
        statusObservation = renderer.observe(\.status, options: [.new]) { renderer, _ in
            Log.relay.info("Renderer status changed: \(String(describing: renderer.status), privacy: .public)")
        }
        errorObservation = renderer.observe(\.error, options: [.new]) { renderer, _ in
            if let error = renderer.error {
                Log.relay.error("Renderer error: \(String(describing: error), privacy: .public)")
            }
        }
        outputConfigChangeObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name.AVSampleBufferAudioRendererOutputConfigurationDidChange,
            object: renderer,
            queue: nil
        ) { [weak self] _ in
            Log.relay.info("Output configuration changed — recreating renderer")
            self?.recreateRenderer()
        }
        autoFlushObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name.AVSampleBufferAudioRendererWasFlushedAutomatically,
            object: renderer,
            queue: nil
        ) { [weak self] _ in
            Log.relay.info("Renderer flushed automatically — recreating renderer")
            self?.recreateRenderer()
        }
    }

    private func detachObservers() {
        statusObservation = nil
        errorObservation = nil
        if let outputConfigChangeObserver {
            NotificationCenter.default.removeObserver(outputConfigChangeObserver)
            self.outputConfigChangeObserver = nil
        }
        if let autoFlushObserver {
            NotificationCenter.default.removeObserver(autoFlushObserver)
            self.autoFlushObserver = nil
        }
    }

    /// A plain flush() turned out not to be enough: Xcode's console showed the real failure
    /// happening below AVFoundation entirely — HALC_ProxyIOContext::IOWorkLoop reporting a
    /// lost/desynced batch of buffer handoffs between coreaudiod and the Bluetooth driver,
    /// triggered by the AirPods renegotiating their audio profile when Spatial Audio mode
    /// changes. Our own buffer bookkeeping stayed healthy through every occurrence (proven
    /// by logs), confirming the break is in a transport-level connection a mere .flush()
    /// doesn't reset. Recreating the renderer object forces AVFoundation to open a fresh
    /// connection to the device, which should reset that transport state.
    private func recreateRenderer() {
        guard isRunning, let outputDeviceUID = currentOutputDeviceUID else { return }
        detachObservers()
        let oldRenderer = currentRenderer
        synchronizer.removeRenderer(oldRenderer, at: synchronizer.currentTime(), completionHandler: nil)

        let newRenderer = AVSampleBufferAudioRenderer()
        configure(newRenderer, outputDeviceUID: outputDeviceUID)
        rendererLock.lock()
        renderer = newRenderer
        rendererLock.unlock()
        attachObservers(to: newRenderer)
        synchronizer.addRenderer(newRenderer)
        needsAnchor = true
        Log.relay.info("Renderer recreated")
    }

    func stop() {
        guard isRunning else { return }
        Log.relay.info("stop: buffersEnqueued=\(self.buffersEnqueued, privacy: .public)")
        detachObservers()
        let renderer = currentRenderer
        synchronizer.setRate(0, time: synchronizer.currentTime())
        renderer.flush()
        synchronizer.removeRenderer(renderer, at: synchronizer.currentTime(), completionHandler: nil)
        formatDescription = nil
        hasStartedSynchronizer = false
        needsAnchor = true
        currentOutputDeviceUID = nil
        isRunning = false
    }
}
