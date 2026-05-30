import Combine
import Foundation
import LiveKit

/// Publishes the whole-device screen as a LiveKit track, captured by the
/// `WazaProtoBroadcast` ReplayKit Broadcast Upload Extension.
///
/// Lifecycle mirrors `GlassesSource`, not `CameraSource`: a separate process
/// (the extension) owns capture, so `publish` is *user-gated* — it pops the
/// system "Screen Broadcast" picker and awaits the broadcast-started signal
/// before it has a track to publish. An out-of-band stop (the red status-bar
/// indicator / Control Center) is surfaced via `onEnded` so the room can drop
/// the video while staying connected — unlike a glasses fold, a stopped
/// broadcast is recoverable in place.
@MainActor
final class ScreenSource: VideoPublisher {
    private let onEnded: () -> Void   // out-of-band stop only; an in-app Stop goes through unpublish()
    private var publication: LocalTrackPublication?
    private var watchdog: AnyCancellable?

    init(onEnded: @escaping () -> Void) { self.onEnded = onEnded }

    func publish(to room: Room) async throws -> VideoTrack? {
        guard Self.appGroupConfigured else { throw ScreenSourceError.extensionMissing }

        // The system picker is a toggle: pressing it starts a broadcast only when
        // none is active, otherwise it *stops* the current one. So if a stale
        // broadcast is still up (a prior source-switch that hasn't fully torn
        // down), stop it and wait for that to land before re-arming — otherwise
        // the picker would silently stop instead of start and we'd time out.
        if BroadcastManager.shared.isBroadcasting {
            print("[screen] stale broadcast active at publish — stopping first")
            BroadcastManager.shared.requestStop()
            await Self.waitUntilBroadcasting(false, timeout: .seconds(5))
        }
        // User-gated start: pop the picker, then wait for the extension's
        // broadcastStarted signal. A dismissed picker never fires → timeout.
        print("[screen] requesting broadcast activation")
        BroadcastManager.shared.requestActivation()
        try await awaitBroadcastStart(timeout: .seconds(30))
        print("[screen] broadcast started — publishing track")

        let track = LocalVideoTrack.createBroadcastScreenCapturerTrack(
            options: ScreenShareCaptureOptions(dimensions: .h720_169, fps: 15)
        )
        let pub = try await room.localParticipant.publish(
            videoTrack: track,
            options: VideoPublishOptions(simulcast: false)
        )
        publication = pub

        // Watch for an out-of-band stop. Installed only after a successful
        // publish; unpublish() tears it down *before* requesting its own stop so
        // an in-app Stop doesn't bounce back through onEnded.
        watchdog = BroadcastManager.shared.isBroadcastingPublisher
            .dropFirst()                    // ignore the replayed current (true) value
            .filter { !$0 }
            .sink { [onEnded] _ in Task { @MainActor in onEnded() } }

        print("[screen] published \(pub.sid)")
        return track
    }

    func unpublish(from room: Room) async {
        watchdog = nil   // clear first → requestStop()'s false event won't trip onEnded
        let wasBroadcasting = BroadcastManager.shared.isBroadcasting
        if wasBroadcasting { BroadcastManager.shared.requestStop() }
        // Tear the track (and its IPC socket) down BEFORE waiting for the stop.
        // Closing the socket is itself part of what ends the broadcast, so
        // waiting first would just stall until the 5s timeout with the broadcast
        // still alive — and a quick switch back to .screen would then catch that
        // dying session in the system picker ("Stop Broadcast / 00:0x").
        if let publication {
            print("[screen] unpublishing \(publication.sid)")
            try? await room.localParticipant.unpublish(publication: publication)
        }
        publication = nil
        // Now wait for iOS to actually release the broadcast session, so any
        // subsequent re-arm finds a clean slate and the picker shows "Start".
        if wasBroadcasting { await Self.waitUntilBroadcasting(false, timeout: .seconds(5)) }
    }

    /// Poll until `BroadcastManager.isBroadcasting` reaches `target` or the
    /// timeout elapses. Used to serialize stop→start across source switches.
    private static func waitUntilBroadcasting(_ target: Bool, timeout: Duration) async {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while BroadcastManager.shared.isBroadcasting != target, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    /// Race the broadcast-started signal against a timeout. The first to finish
    /// wins; the other is cancelled.
    private func awaitBroadcastStart(timeout: Duration) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                for await isOn in BroadcastManager.shared.isBroadcastingPublisher.values where isOn {
                    return
                }
                throw ScreenSourceError.broadcastNotStarted   // publisher completed without ever going true
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw ScreenSourceError.pickerDismissed
            }
            try await group.next()   // throws if the winner threw (timeout / no-start)
            group.cancelAll()
        }
    }

    // `BroadcastBundleInfo.hasExtension` is internal to LiveKit, so probe the
    // same precondition directly: the shared App Group container resolves only
    // when the `group.<bundle-id>` entitlement is present on this app (which is
    // also what the broadcast IPC socket lives in).
    private static var appGroupConfigured: Bool {
        guard let bundleID = Bundle.main.bundleIdentifier else { return false }
        return FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: "group.\(bundleID)") != nil
    }
}

enum ScreenSourceError: LocalizedError {
    case extensionMissing
    case pickerDismissed
    case broadcastNotStarted

    var errorDescription: String? {
        switch self {
        case .extensionMissing:   return "Screen sharing isn't configured on this build."
        case .pickerDismissed:    return "Screen broadcast wasn't started."
        case .broadcastNotStarted: return "Screen broadcast ended before it started."
        }
    }
}
