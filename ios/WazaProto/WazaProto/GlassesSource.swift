import Foundation
import LiveKit
import MWDATCamera
import MWDATCore

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

        guard let stream = try session.addStream(config: StreamConfiguration(
            videoCodec: .raw,
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
            self.frameToken = stream.videoFramePublisher.listen { frame in
                capturer.capture(frame.sampleBuffer)
                if !fired {
                    fired = true
                    continuation.yield()
                    continuation.finish()
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
