import Foundation
import LiveKit
import MWDATCamera
import MWDATCore
import QuartzCore
import VideoToolbox

@MainActor
final class GlassesSource: VideoPublisher {
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

        let bufferTrack = LocalVideoTrack.createBufferTrack(
            name: "glasses-camera",
            source: .camera,
            options: BufferCaptureOptions()
        )
        self.bufferTrack = bufferTrack
        let capturer = bufferTrack.capturer as! BufferCapturer

        let smoother = FrameSmoothingBuffer()
        let pump = SmoothingBufferPump(buffer: smoother, capturer: capturer)
        self.smoother = smoother
        self.pump = pump
        pump.start()

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
            let counters = GlassesProfilerCounters.shared
            counters.reset()
            self.frameToken = stream.videoFramePublisher.listen { frame in
                counters.recordCallback()
                let sampleBuffer = frame.sampleBuffer
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
                ) { status, _, imageBuffer, _, _ in
                    guard status == noErr, let imageBuffer else {
                        if status != noErr {
                            counters.recordDecodeError()
                        }
                        return
                    }
                    counters.recordDecodedFrame()
                    // Smoother decouples the LiveKit encoder's input cadence
                    // from DAT's bursty delivery. The pump thread pulls at a
                    // steady 30 fps and calls capturer.capture(...) with a
                    // pull-time timestamp; the original PTS is intentionally
                    // discarded so the encoder sees evenly-spaced frames.
                    smoother.push(imageBuffer)
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

        publication = try await room.localParticipant.publish(
            videoTrack: bufferTrack,
            options: VideoPublishOptions(simulcast: false)
        )
        print("[glasses] track published to LiveKit")
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
                for await state in stateStream {
                    print("[glasses] session state → \(state)")
                    if state == .started { return }
                    if state == .stopped {
                        throw GlassesSourceError.sessionStoppedBeforeStart
                    }
                }
            }
            group.addTask {
                for await error in errorStream {
                    print("[glasses] session error → \(error)")
                    throw error
                }
            }
            _ = try await group.next()
            group.cancelAll()
        }
    }
}

enum GlassesSourceError: Error {
    case streamCreationFailed
    case sessionStoppedBeforeStart
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
