import Foundation
import LiveKit
import MWDATCamera
import MWDATCore
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
        // live for the rest of the session capturing frames, but subsequent
        // yields become no-ops instead of accumulating in an unbounded buffer.
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
                ) { status, _, imageBuffer, presentationTimeStamp, _ in
                    guard status == noErr, let imageBuffer else {
                        if status != noErr {
                            counters.recordDecodeError()
                        }
                        return
                    }
                    counters.recordDecodedFrame()
                    let timeStampNs = Int64(presentationTimeStamp.seconds * 1_000_000_000)
                    capturer.capture(imageBuffer, timeStampNs: timeStampNs, rotation: ._0)
                    counters.recordCapturedFrame()
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
