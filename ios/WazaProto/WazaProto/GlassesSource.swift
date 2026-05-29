import Foundation
import LiveKit
import MWDATCamera
import MWDATCore
import QuartzCore
import VideoToolbox

@MainActor
final class GlassesSource: VideoPublisher {
    // Process-wide singleton TCP listener — bound once and kept across
    // publish→unpublish cycles. Recreating per cycle hits a port-reuse race
    // (kernel hasn't released the socket by the time the next start() runs;
    // allowLocalEndpointReuse only helps cross-process). On unpublish we
    // only drop the active client connection, not the listener itself.
    private static var sharedTcpServer: EncodedFrameTCPServer?

    private let wearables: WearablesInterface
    private let deviceSelector: AutoDeviceSelector
    private let onTerminated: @MainActor () -> Void
    private var deviceSession: DeviceSession?
    private var stream: MWDATCamera.Stream?
    private var frameToken: AnyListenerToken?
    private var bufferTrack: LocalVideoTrack?
    private var publication: LocalTrackPublication?
    private var watchdogTask: Task<Void, Never>?
    private var smoother: FrameSmoothingBuffer?
    private var pump: SmoothingBufferPump?
    private var tcpServer: EncodedFrameTCPServer?

    init(
        wearables: WearablesInterface,
        deviceSelector: AutoDeviceSelector,
        onTerminated: @escaping @MainActor () -> Void
    ) {
        self.wearables = wearables
        self.deviceSelector = deviceSelector
        self.onTerminated = onTerminated
    }

    func publish(to room: Room) async throws -> VideoTrack? {
        print("[glasses] publish() begin — activeDevice=\(deviceSelector.activeDevice ?? "nil")")
        let useEncodedIngest = Config.glassesEncodedIngest

        let bufferTrack: LocalVideoTrack?
        let capturer: BufferCapturer?
        let smoother: FrameSmoothingBuffer?
        let tcpServer: EncodedFrameTCPServer?

        if useEncodedIngest {
            // Trigger + verify Local Network privacy before binding the listener.
            // Listeners created pre-grant inherit a denied auth handle even if the
            // user later flips the Settings toggle (Apple TN3179 + DTS thread 768666);
            // running the NWBrowser preflight here is the deterministic way to
            // both surface the prompt AND wait for actual grant.
            let lnp = LocalNetworkAuthorization()
            let granted = await lnp.requestAuthorization()
            guard granted else {
                throw GlassesSourceError.localNetworkDenied
            }
            let server: EncodedFrameTCPServer
            if let existing = Self.sharedTcpServer {
                server = existing
            } else {
                server = EncodedFrameTCPServer(port: Config.glassesEncodedIngestPort)
                try server.start()
                Self.sharedTcpServer = server
            }
            self.tcpServer = server
            tcpServer = server
            print("[glasses] encoded-ingest mode: TCP server on port \(Config.glassesEncodedIngestPort)")
            bufferTrack = nil
            capturer = nil
            smoother = nil
        } else {
            let track = LocalVideoTrack.createBufferTrack(
                name: "glasses-camera",
                source: .camera,
                options: BufferCaptureOptions()
            )
            self.bufferTrack = track
            bufferTrack = track
            capturer = (track.capturer as! BufferCapturer)

            let smoothingDepth = Config.glassesSmoothingDepth
            let s: FrameSmoothingBuffer? = smoothingDepth > 0
                ? FrameSmoothingBuffer(maxDepth: Config.glassesSmoothingMaxDepth, primeDepth: smoothingDepth)
                : nil
            if let s, let capturer {
                let pump = SmoothingBufferPump(buffer: s, capturer: capturer)
                self.smoother = s
                self.pump = pump
                pump.start()
                print("[glasses] smoothing buffer enabled (depth=\(smoothingDepth))")
            } else {
                print("[glasses] smoothing buffer bypassed (depth=0)")
            }
            smoother = s
            tcpServer = nil
        }

        print("[glasses] createSession()…")
        let session = try wearables.createSession(deviceSelector: deviceSelector)
        self.deviceSession = session

        let stateStream = session.stateStream()
        let errorStream = session.errorStream()

        print("[glasses] session.start()…")
        try session.start()

        if session.state != .started {
            try await waitForSessionStart(stateStream: stateStream, errorStream: errorStream)
        }
        print("[glasses] session reached .started")

        // .hvc1 (compressed HEVC) keeps frames flowing while backgrounded;
        // .raw is documented foreground-only and stops the publisher's frame
        // callback the instant the app loses foreground. We decode locally with
        // VideoToolbox below before handing pixel buffers to LiveKit.
        // https://wearables.developer.meta.com/docs/reference/ios_swift/dat/0.6/mwdatcamera_videocodec
        guard let stream = try session.addStream(config: StreamConfiguration(
            videoCodec: .hvc1,
            resolution: .high,
            frameRate: 30
        )) else {
            throw GlassesSourceError.streamCreationFailed
        }
        self.stream = stream
        print("[glasses] addStream succeeded (resolution=.high, frameRate=30)")

        // Watchdog: after start, monitor session state/error streams so a
        // mid-stream termination (e.g. user folds the glasses' hinges) tears
        // down cleanly instead of leaving a stale LiveKit track + frozen
        // preview/viewer frame.
        startWatchdog(for: session)

        // Finish the continuation after the first yield — the listener stays
        // live for the rest of the session pushing decoded frames into the
        // smoother, but subsequent yields become no-ops instead of accumulating
        // in an unbounded buffer.
        let firstFrame = AsyncStream<Void> { continuation in
            var fired = false
            var decompressionSession: VTDecompressionSession?
            var extractor = HEVCAnnexBExtractor()
            let counters = GlassesProfilerCounters.shared
            counters.reset()
            self.frameToken = stream.videoFramePublisher.listen { frame in
                counters.recordCallback()
                let sampleBuffer = frame.sampleBuffer

                if let tcpServer {
                    // Encoded-ingest path (plan 15, flag-gated): HVCC → Annex-B
                    // → TCP listener. The lk relay consumes from there and
                    // forwards raw HEVC to the SFU. Pristine image but PLI-
                    // deadlock prone; see plans/completed/17-encoded-freeze-recovery.md.
                    guard let bytes = extractor.annexB(from: sampleBuffer) else { return }
                    tcpServer.send(bytes)
                    counters.recordCapturedFrame()
                    if !fired {
                        fired = true
                        continuation.yield()
                        continuation.finish()
                    }
                    return
                }

                guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }

                // DAT's adaptive-quality ladder silently swaps resolutions on
                // weak Bluetooth links (e.g. high → medium); each switch ships
                // new parameter sets, so the cached decoder must be rebuilt or
                // every subsequent frame returns kVTVideoDecoderBadDataErr.
                let needsNewSession: Bool = {
                    guard let existing = decompressionSession else { return true }
                    return !VTDecompressionSessionCanAcceptFormatDescription(existing, formatDescription: formatDescription)
                }()
                if needsNewSession {
                    if let existing = decompressionSession {
                        VTDecompressionSessionInvalidate(existing)
                        decompressionSession = nil
                    }
                    let attributes: [CFString: Any] = [
                        kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                    ]
                    var session: VTDecompressionSession?
                    let status = VTDecompressionSessionCreate(
                        allocator: kCFAllocatorDefault,
                        formatDescription: formatDescription,
                        decoderSpecification: nil,
                        imageBufferAttributes: attributes as CFDictionary,
                        outputCallback: nil,
                        decompressionSessionOut: &session
                    )
                    if status == noErr {
                        decompressionSession = session
                        counters.recordDecoderRebuild()
                        let dims = CMVideoFormatDescriptionGetDimensions(formatDescription)
                        print("[glasses] decoder (re)built for \(dims.width)x\(dims.height)")
                    } else {
                        counters.recordDecodeError()
                        print("[glasses] VTDecompressionSessionCreate failed: \(status)")
                        return
                    }
                }
                guard let session = decompressionSession else { return }
                VTDecompressionSessionDecodeFrame(
                    session,
                    sampleBuffer: sampleBuffer,
                    flags: [],
                    infoFlagsOut: nil
                ) { status, _, imageBuffer, presentationTimeStamp, _ in
                    guard status == noErr, let imageBuffer else {
                        if status != noErr {
                            counters.recordDecodeError()
                        }
                        return
                    }
                    counters.recordDecodedFrame()
                    if let smoother {
                        // Smoother decouples the LiveKit encoder's input cadence
                        // from DAT's bursty delivery. The pump thread pulls at
                        // 30 fps and calls capturer.capture(...) with a
                        // pull-time timestamp; the original PTS is intentionally
                        // discarded so the encoder sees evenly-spaced frames.
                        smoother.push(imageBuffer)
                    } else {
                        // Bypass (Config.glassesSmoothingDepth == 0): pre-plan-12
                        // path — VT decode callback feeds BufferCapturer directly,
                        // encoder sees DAT's bursty cadence.
                        let timeStampNs = Int64(presentationTimeStamp.seconds * 1_000_000_000)
                        capturer?.capture(imageBuffer, timeStampNs: timeStampNs, rotation: ._0)
                        counters.recordCapturedFrame()
                    }
                    if !fired {
                        fired = true
                        continuation.yield()
                        continuation.finish()
                    }
                }
            }
        }

        await stream.start()
        print("[glasses] stream started, waiting for first frame…")

        var iterator = firstFrame.makeAsyncIterator()
        _ = await iterator.next()
        print("[glasses] first frame received")

        if let bufferTrack {
            // plan 17: re-encode to H.265 with a generous 4 Mbps ceiling (~5× the
            // ~0.79 Mbps glasses source) so the second-generation encode adds no
            // visible loss. It's a cap, not a floor — WebRTC adapts down under
            // congestion. Removes the ~0.75 Mbps resolution-default that softened
            // the medium rung.
            publication = try await room.localParticipant.publish(
                videoTrack: bufferTrack,
                options: VideoPublishOptions(
                    encoding: VideoEncoding(maxBitrate: 4_000_000, maxFps: 30),
                    simulcast: false,
                    preferredCodec: .h265
                )
            )
            print("[glasses] track published to LiveKit")
        }
        return bufferTrack
    }

    func unpublish(from room: Room) async {
        watchdogTask?.cancel()
        watchdogTask = nil
        frameToken = nil
        // Stop the pump first so it can't fire one last capture against a
        // torn-down track; then drain the buffer.
        pump?.stop()
        pump = nil
        smoother?.drain()
        smoother = nil
        // Drop the active client connection but leave the shared listener
        // bound — recreating per cycle hits a port-reuse race.
        tcpServer?.dropClient()
        tcpServer = nil
        if let stream { await stream.stop() }
        stream = nil
        deviceSession?.stop()
        deviceSession = nil
        if let publication {
            try? await room.localParticipant.unpublish(publication: publication)
        }
        publication = nil
        bufferTrack = nil
    }

    private func startWatchdog(for session: DeviceSession) {
        watchdogTask = Task { [weak self] in
            let stateStream = session.stateStream()
            let errorStream = session.errorStream()
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    for await state in stateStream {
                        print("[glasses] (live) session state → \(state)")
                        if state == .stopped { return }
                    }
                }
                group.addTask {
                    for await error in errorStream {
                        print("[glasses] (live) session error → \(error)")
                        return
                    }
                }
                _ = await group.next()
                group.cancelAll()
            }
            guard !Task.isCancelled else { return }
            print("[glasses] watchdog: session terminated, notifying connection")
            await MainActor.run { [weak self] in self?.onTerminated() }
        }
    }

    private func waitForSessionStart(
        stateStream: AsyncStream<DeviceSessionState>,
        errorStream: AsyncStream<DeviceSessionError>
    ) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                for await error in errorStream {
                    print("[glasses] session error → \(error)")
                    throw GlassesSourceError.sessionRefusedByDevice(reason: Self.refusalReason(error))
                }
            }
            group.addTask {
                for await state in stateStream {
                    print("[glasses] session state → \(state)")
                    if state == .started { return }
                    if state == .stopped {
                        // The device usually delivers the real DeviceSessionError
                        // a beat *after* the .stopped transition. Give the error
                        // stream a short grace window to win the race, so we
                        // surface the actual reason ("Session ended by device")
                        // with recovery advice instead of this bare fallback.
                        try? await Task.sleep(for: .milliseconds(300))
                        throw GlassesSourceError.sessionStoppedBeforeStart
                    }
                }
            }
            _ = try await group.next()
            group.cancelAll()
        }
    }

    // Extract the device's own reason string; `.unexpectedError` carries the
    // human text we saw in logs ("Session ended by device", "Device unavailable"),
    // and every other case is a LocalizedError with a usable description.
    private nonisolated static func refusalReason(_ error: DeviceSessionError) -> String {
        if case let .unexpectedError(description) = error {
            return description
        }
        return error.localizedDescription
    }
}

enum GlassesSourceError: Error, LocalizedError {
    case streamCreationFailed
    case sessionStoppedBeforeStart
    case localNetworkDenied
    case sessionRefusedByDevice(reason: String)

    var errorDescription: String? {
        switch self {
        case .streamCreationFailed:
            return "Couldn't create the glasses camera stream. Tap Connect to try again."
        case .localNetworkDenied:
            return "Local Network access is off. Enable it for Waza Proto in Settings, then try again."
        case .sessionStoppedBeforeStart:
            return Self.refusalAdvice(reason: nil)
        case .sessionRefusedByDevice(let reason):
            return Self.refusalAdvice(reason: reason)
        }
    }

    // The glasses intermittently refuse a freshly-started camera session
    // (DeviceSessionError "Session ended by device" / "Device unavailable") —
    // a device-side state, reproduced identically on `main`, that the SDK never
    // explains (DeviceSessionState carries no reason). The reliable recovery is
    // a doff/don cycle, which resets the glasses' wear/capture-readiness state,
    // so that's the action we surface rather than a bare error code.
    private static func refusalAdvice(reason: String?) -> String {
        let detail = reason.map { " (\($0))" } ?? ""
        return "The glasses ended the camera session\(detail). Take them off, wait for the chime, and put them back on — then tap Connect."
    }
}

// MARK: - Smoothing buffer (plan 12)

// Ring buffer between the in-app HEVC decoder and BufferCapturer.capture(...).
// Push from the VideoToolbox decode callback; pull from the dedicated pump
// thread @ 30 fps. Drop-oldest on overrun (bounds tail latency); repeat-last
// on underrun (masks short DAT stalls). Primes to primeDepth before the pump
// starts delivering, so steady-state buffer occupancy hovers near primeDepth
// and the per-frame latency contribution is primeDepth * 1/30s (~133 ms at
// depth=4). See plans/active/12-glasses-smoothing-buffer.md.
final class FrameSmoothingBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer: [CVPixelBuffer] = []
    private var lastFrame: CVPixelBuffer?
    private var primed = false
    private let maxDepth: Int
    private let primeDepth: Int

    init(maxDepth: Int = 6, primeDepth: Int = 4) {
        self.maxDepth = maxDepth
        self.primeDepth = primeDepth
    }

    func push(_ frame: CVPixelBuffer) {
        lock.lock()
        var overran = false
        if buffer.count >= maxDepth {
            buffer.removeFirst()
            overran = true
        }
        buffer.append(frame)
        if !primed && buffer.count >= primeDepth {
            primed = true
        }
        lock.unlock()

        if overran {
            GlassesProfilerCounters.shared.recordBufferOverrun()
        }
    }

    func pull() -> CVPixelBuffer? {
        lock.lock()
        let depth = buffer.count
        let isPrimed = primed
        let frame: CVPixelBuffer?
        if !isPrimed {
            frame = nil
        } else if buffer.isEmpty {
            frame = lastFrame
        } else {
            let next = buffer.removeFirst()
            lastFrame = next
            frame = next
        }
        lock.unlock()

        let counters = GlassesProfilerCounters.shared
        counters.recordBufferPull(depth: depth)
        if isPrimed && depth == 0 {
            counters.recordBufferUnderrun()
        }
        return frame
    }

    func drain() {
        lock.lock()
        buffer.removeAll()
        lastFrame = nil
        primed = false
        lock.unlock()
    }
}

// Owns the dedicated worker thread + CFRunLoop + CADisplayLink that drives
// the steady 30 fps pull cadence. The CADisplayLink is added to the worker
// thread's run loop in .common modes — NOT main — so a busy UI cannot stall
// the pump. CFRunLoopStop() is the cross-thread shutdown signal.
final class SmoothingBufferPump: NSObject, @unchecked Sendable {
    private let buffer: FrameSmoothingBuffer
    private let capturer: BufferCapturer
    private let lock = NSLock()
    private let runLoopReady = DispatchSemaphore(value: 0)
    private var runLoop: CFRunLoop?
    private var thread: Thread?

    init(buffer: FrameSmoothingBuffer, capturer: BufferCapturer) {
        self.buffer = buffer
        self.capturer = capturer
    }

    func start() {
        let thread = Thread { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.runLoop = CFRunLoopGetCurrent()
            self.lock.unlock()
            let link = CADisplayLink(target: self, selector: #selector(self.tick))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 30, preferred: 30)
            link.add(to: .current, forMode: .common)
            self.runLoopReady.signal()
            // Blocks until CFRunLoopStop() is called from another thread.
            CFRunLoopRun()
            link.invalidate()
        }
        thread.name = "waza.smoothing-pump"
        thread.qualityOfService = .userInteractive
        thread.start()
        // Wait briefly so callers can rely on the run loop existing after
        // start() returns. 2s is generous; thread spin-up is microseconds.
        _ = runLoopReady.wait(timeout: .now() + 2.0)
        self.thread = thread
    }

    func stop() {
        lock.lock()
        let rl = runLoop
        runLoop = nil
        lock.unlock()
        if let rl { CFRunLoopStop(rl) }
        thread = nil
    }

    @objc private func tick() {
        guard let frame = buffer.pull() else { return }
        let timeStampNs = Int64(ProcessInfo.processInfo.systemUptime * 1_000_000_000)
        capturer.capture(frame, timeStampNs: timeStampNs, rotation: ._0)
        GlassesProfilerCounters.shared.recordCapturedFrame()
    }
}
