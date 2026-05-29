import AVFoundation
import Combine
import LiveKit
import SwiftUI

/// Adapter that knows how to publish (and tear down) a single video track on a
/// given Room. Each concrete source — phone front camera, glasses — implements
/// this; `RoomConnection` is source-agnostic.
@MainActor
protocol VideoPublisher: AnyObject {
    func publish(to room: Room) async throws -> VideoTrack?
    func unpublish(from room: Room) async
}

@MainActor
final class RoomConnection: NSObject, ObservableObject {
    enum Source: String, CaseIterable, Identifiable {
        case frontCamera = "Front"
        case rearCamera = "Rear"
        case glasses = "Glasses"
        var id: String { rawValue }
        var profileID: String {
            switch self {
            case .frontCamera: return "frontCamera"
            case .rearCamera:  return "rearCamera"
            case .glasses:     return "glasses"
            }
        }
    }

    enum Status: Equatable {
        case disconnected
        case connecting
        case connected
        case switching
        case failed(String)

        var label: String {
            switch self {
            case .disconnected:     return "Disconnected"
            case .connecting:       return "Connecting…"
            case .connected:        return "Publishing as ios-publisher"
            case .switching:        return "Switching source…"
            case .failed(let msg):  return "Error: \(msg)"
            }
        }
    }

    @Published private(set) var status: Status = .disconnected
    @Published private(set) var localVideoTrack: VideoTrack?
    @Published private(set) var watcherCount: Int = 0
    @Published private(set) var profileRunID: String?
    // The AI coach (agent_name=waza-coach) is an opt-in participant: present
    // reflects whether it's currently in the room; busy guards a dispatch
    // request in flight. The button in ContentView reads both.
    @Published private(set) var coachPresent: Bool = false
    @Published private(set) var coachBusy: Bool = false
    // Set when a summon produces no coach (almost always: no worker registered
    // to fulfill the dispatch). Cleared on the next attempt or when one joins.
    @Published private(set) var coachError: String?

    // suspendLocalVideoTracksInBackground=false: otherwise LiveKit calls
    // .suspend() on any track with source=.camera (which includes our
    // glasses BufferCapturer) the moment the app backgrounds, regardless
    // of UIBackgroundModes. See livekit/client-sdk-swift#832.
    let room = Room(roomOptions: RoomOptions(suspendLocalVideoTracksInBackground: false))
    private var publisher: VideoPublisher?
    private let tokenClient: PublisherTokenClient
    private let coachClient = CoachDispatchClient()
    private let profiler = VideoQualityProfiler()
    private var profileStopTask: Task<Void, Never>?
    private var profileRunCounts: [Source: Int] = [:]

    init(tokenClient: PublisherTokenClient = PublisherTokenClient()) {
        self.tokenClient = tokenClient
        super.init()
        room.add(delegate: self)
    }

    // The coach's voice reaches the glasses over the platform Bluetooth route.
    // In practice iOS picks HFP (the glasses expose it for their mic too), which
    // is 8 kHz but perfectly intelligible for speech and uses the glasses' own
    // well-placed mic. We deliberately do NOT force A2DP: LiveKit's default
    // engine observer hardcodes `.playAndRecordSpeaker` and ignores
    // `AudioManager.shared.sessionConfiguration`, so the property route is a
    // no-op anyway — switching to A2DP (hi-fi, output-only) would require a
    // custom AudioEngineObserver and would move capture to the phone mic. Not
    // worth it unless we ever need music-grade coach audio.

    // Diagnostic: where is iOS actually sending output? Printed to the
    // devicectl --console stream. Tells coach-audio-inaudible apart into its
    // two cases: wrong route (audio reaches iOS, plays out earpiece/speaker
    // instead of the glasses) vs. no playout at all.
    static func logAudioRoute(_ reason: String) {
        let s = AVAudioSession.sharedInstance()
        let outs = s.currentRoute.outputs
            .map { "\($0.portType.rawValue):\($0.portName)" }.joined(separator: ", ")
        let ins = s.currentRoute.inputs
            .map { "\($0.portType.rawValue):\($0.portName)" }.joined(separator: ", ")
        print("[audio-route] (\(reason)) category=\(s.category.rawValue) "
            + "mode=\(s.mode.rawValue) options=\(s.categoryOptions.rawValue) "
            + "outputs=[\(outs)] inputs=[\(ins)]")
    }

    func connect(source: Source, glasses: GlassesGateway) {
        Task {
            status = .connecting
            let publisher = makePublisher(source: source, glasses: glasses)
            self.publisher = publisher
            do {
                let minted = try await tokenClient.mint()
                try await room.connect(url: minted.url, token: minted.token)
                watcherCount = currentWatcherCount()
                // Publish the mic to activate an AVAudioSession — iOS only
                // honors UIBackgroundModes=audio's network keepalive while an
                // audio session is actually active. Without this, WebRTC's
                // sockets pause when the app backgrounds even though the
                // process keeps running. See livekit/client-sdk-swift#510.
                try await room.localParticipant.setMicrophone(enabled: true)
                localVideoTrack = try await publisher.publish(to: room)
                await localVideoTrack?.set(reportStatistics: true)
                profiler.attach(to: localVideoTrack)
                status = .connected
                Self.logAudioRoute("connected")
            } catch {
                status = .failed(Self.failureMessage(for: error))
                await publisher.unpublish(from: room)
                await room.disconnect()
                self.publisher = nil
            }
        }
    }

    /// Swap publishers without dropping the room connection. Caller must
    /// already be `.connected`. On failure, status flips to `.failed` and the
    /// caller is expected to revert any UI source selection.
    func switchSource(to source: Source, glasses: GlassesGateway) {
        guard case .connected = status else { return }
        Task {
            status = .switching
            let oldPublisher = publisher
            let newPublisher = makePublisher(source: source, glasses: glasses)
            do {
                await stopProfiling(incomplete: true)
                if let oldPublisher { await oldPublisher.unpublish(from: room) }
                localVideoTrack = nil
                profiler.attach(to: nil)
                publisher = newPublisher
                localVideoTrack = try await newPublisher.publish(to: room)
                await localVideoTrack?.set(reportStatistics: true)
                profiler.attach(to: localVideoTrack)
                status = .connected
            } catch {
                status = .failed(Self.failureMessage(for: error))
                await newPublisher.unpublish(from: room)
                await room.disconnect()
                publisher = nil
            }
        }
    }

    func disconnect() {
        Task {
            await stopProfiling(incomplete: true)
            if let publisher { await publisher.unpublish(from: room) }
            await room.disconnect()
            publisher = nil
            localVideoTrack = nil
            profiler.attach(to: nil)
            watcherCount = 0
            coachPresent = false
            coachBusy = false
            coachError = nil
            status = .disconnected
        }
    }

    /// Summon the AI coach into the room (explicit dispatch — the worker isn't
    /// auto-dispatched). `coachPresent` flips once the agent participant joins.
    func summonCoach() { dispatchCoach(.summon) }

    /// Dismiss the AI coach — removes the agent participant, ending its billed
    /// Gemini session. `coachPresent` flips once it disconnects.
    func dismissCoach() { dispatchCoach(.dismiss) }

    private func dispatchCoach(_ action: CoachDispatchClient.Action) {
        guard case .connected = status, !coachBusy else { return }
        coachBusy = true
        coachError = nil
        Task {
            do {
                try await coachClient.dispatch(action)
                // Stay busy until the room actually reflects the change —
                // the coach takes ~3s to join after the HTTP call returns, and
                // releasing the button at HTTP-return let rapid taps dispatch
                // duplicate coaches. `refreshParticipants` clears coachBusy
                // when coachPresent flips. This sleep is the fallback: if it's
                // still busy when it ends, the dispatch was a no-op — almost
                // always because no worker is registered to fulfill the summon.
                try? await Task.sleep(for: .seconds(8))
                if coachBusy {
                    coachBusy = false
                    if case .summon = action, !coachPresent {
                        coachError = "Coach unavailable — the worker may be offline."
                    }
                }
            } catch {
                print("[coach] \(action.rawValue) failed: \(error)")
                coachBusy = false
                coachError = "Couldn't reach the coach service."
            }
        }
    }

    func startProfiling(source: Source, durationSeconds: Int = 180) {
        guard case .connected = status, profileRunID == nil else { return }
        let count = profileRunCounts[source, default: 0]
        profileRunCounts[source] = count + 1
        let runID = Self.profileRunID(source: source.profileID, runIndex: count)
        let durationMs = durationSeconds * 1000
        profileRunID = runID

        if let data = profiler.start(runID: runID, source: source.profileID, durationMs: durationMs) {
            Task { try? await publishProfileMessage(data) }
        }

        profileStopTask?.cancel()
        profileStopTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(durationSeconds))
            await self?.stopProfiling(incomplete: false)
        }
    }

    func stopProfiling(incomplete: Bool = false) async {
        profileStopTask?.cancel()
        profileStopTask = nil
        profileRunID = nil
        guard let data = profiler.stop(incomplete: incomplete) else { return }
        try? await publishProfileMessage(data)
    }

    // Prefer an error's user-actionable text (GlassesSourceError and
    // DeviceSessionError are LocalizedError) over a type-tagged debug string.
    // The raw error is still printed to the console for diagnostics.
    private static func failureMessage(for error: Error) -> String {
        if let described = (error as? LocalizedError)?.errorDescription, !described.isEmpty {
            return described
        }
        return "\(type(of: error)).\(error) — \(error.localizedDescription)"
    }

    private func makePublisher(source: Source, glasses: GlassesGateway) -> VideoPublisher {
        switch source {
        case .frontCamera:
            return CameraSource(position: .front)
        case .rearCamera:
            return CameraSource(position: .back)
        case .glasses:
            return GlassesSource(
                wearables: glasses.wearables,
                deviceSelector: glasses.deviceSelector,
                onTerminated: { [weak self] in self?.handleGlassesTerminated() }
            )
        }
    }

    // Count only participants that look like our viewers (identity minted by
    // api/viewer-token.js as `viewer-<8chars>`). Filters out stale ghosts and
    // any future agent/system participants in the room.
    private func currentWatcherCount() -> Int {
        Self.watcherCount(identities: room.remoteParticipants.values.map {
            $0.identity?.stringValue ?? ""
        })
    }

    // Recompute room-derived state on any participant change. The coach joins
    // with an `agent-` identity prefix (LiveKit Agents convention); viewers are
    // `viewer-…`. So one scan updates both counts.
    private func refreshParticipants() {
        let identities = room.remoteParticipants.values.map { $0.identity?.stringValue ?? "" }
        watcherCount = Self.watcherCount(identities: identities)
        let present = identities.contains { $0.hasPrefix("agent-") }
        // A presence transition means an in-flight summon/dismiss has landed —
        // release the button. Guarding on the transition avoids an unrelated
        // viewer join/leave clearing coachBusy while a summon is still pending.
        if present != coachPresent {
            coachPresent = present
            coachBusy = false
            if present { coachError = nil }
        }
    }

    nonisolated static func watcherCount(identities: [String]) -> Int {
        identities.filter { $0.hasPrefix("viewer-") }.count
    }

    nonisolated static func profileRunID(source: String, runIndex: Int, date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH-mm-ss'Z'"
        let letterScalar = UnicodeScalar(97 + min(max(runIndex, 0), 25))!
        return "\(formatter.string(from: date))-\(source)-\(Character(letterScalar))"
    }

    private func publishProfileMessage(_ data: Data) async throws {
        try await room.localParticipant.publish(
            data: data,
            options: DataPublishOptions(topic: VideoQualityProfiler.dataTopic, reliable: true)
        )
    }

    private func handleGlassesTerminated() {
        // Called from GlassesSource's watchdog when its DAT DeviceSession ends
        // unexpectedly (e.g. hinge fold). Tear the LiveKit side down cleanly so
        // the viewer flips to "waiting for video" and the user can hit Connect
        // again once the glasses are usable.
        guard publisher is GlassesSource else { return }
        Task {
            await stopProfiling(incomplete: true)
            if let publisher { await publisher.unpublish(from: room) }
            await room.disconnect()
            self.publisher = nil
            localVideoTrack = nil
            profiler.attach(to: nil)
            watcherCount = 0
            status = .failed("Glasses session ended — unfold and reconnect")
        }
    }
}

extension RoomConnection: RoomDelegate {
    nonisolated func room(_ room: Room, participantDidConnect participant: RemoteParticipant) {
        Task { @MainActor in self.refreshParticipants() }
    }

    nonisolated func room(_ room: Room, participantDidDisconnect participant: RemoteParticipant) {
        Task { @MainActor in self.refreshParticipants() }
    }

    // Diagnostic for the coach-audio path: confirm the agent's audio track is
    // actually subscribed, and dump the route once LiveKit's AudioManager has
    // had a moment to (re)configure the session for playout.
    nonisolated func room(_ room: Room, participant: RemoteParticipant, didSubscribeTrack publication: RemoteTrackPublication) {
        let kind = publication.kind == .audio ? "audio" : "video"
        print("[audio-route] subscribed \(kind) track '\(publication.name)' "
            + "from \(participant.identity?.stringValue ?? "?")")
        guard publication.kind == .audio else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(800))
            Self.logAudioRoute("after remote audio subscribed")
        }
    }
}
