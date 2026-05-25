import AVFoundation
import LiveKit

@MainActor
final class FrontCameraSource: VideoPublisher {
    private var publication: LocalTrackPublication?

    func publish(to room: Room) async throws -> VideoTrack? {
        // `setCamera(enabled: false)` only mutes for the .camera source slot
        // (see LiveKit LocalParticipant.set(source:enabled:)). That makes the
        // mute/unmute round-trip incompatible with live source swaps — a later
        // glasses → front swap unmutes a stale publication whose capture
        // pipeline isn't reliably restarted. So we publish a fresh camera
        // track explicitly and tear it down via unpublish(publication:).
        let track = LocalVideoTrack.createCameraTrack(
            options: CameraCaptureOptions(position: .front)
        )
        let pub = try await room.localParticipant.publish(
            videoTrack: track,
            options: VideoPublishOptions(simulcast: false)
        )
        publication = pub
        print("[frontCamera] published \(pub.sid)")
        return track
    }

    func unpublish(from room: Room) async {
        if let publication {
            print("[frontCamera] unpublishing \(publication.sid)")
            try? await room.localParticipant.unpublish(publication: publication)
        }
        publication = nil
    }
}
