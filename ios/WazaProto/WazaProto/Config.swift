import Foundation

enum Config {
    // Viewer page + serverless host. Defaults to prod; a DEBUG build honors the
    // WAZA_VIEWER_HOST env var so a worktree can point the copy-link page AND
    // the app's own /api/* fetches at a local `vercel dev` (see the
    // create-worktree skill). One override covers both: `vercel dev` serves the
    // page and /api/* from a single origin. Empty/unset → prod, untouched.
    static let viewerHost = host
    static let publisherHost = host

    private static let host: String = {
        #if DEBUG
        if let override = ProcessInfo.processInfo.environment["WAZA_VIEWER_HOST"],
           !override.isEmpty {
            return override
        }
        #endif
        return "https://waza-proto.vercel.app"
    }()

    static func viewerURL(invite: String) -> URL {
        URL(string: "\(viewerHost)/?invite=\(invite)")!
    }

    static func publisherTokenURL(auth: String, room: String) -> URL {
        URL(string: "\(publisherHost)/api/publisher-token?auth=\(auth)&room=\(room)")!
    }

    static func closeRoomURL(auth: String, room: String) -> URL {
        URL(string: "\(publisherHost)/api/close-room?auth=\(auth)&room=\(room)")!
    }

    static func coachDispatchURL() -> URL {
        URL(string: "\(publisherHost)/api/coach-dispatch")!
    }

    // plan 12: smoothing buffer between in-app HEVC decoder and BufferCapturer.
    // Depth = primeDepth = frames the pump waits for before starting to pull,
    // and the approximate steady-state buffer occupancy. Each slot adds ~33 ms
    // of glass-to-glass latency (pull period at 30 fps). 0 = bypass entirely
    // (legacy pre-plan-12 path; VT decode callback calls capturer.capture
    // directly). Revert toward 0 as WDAT delivery cadence improves upstream.
    static let glassesSmoothingDepth = 2
    static let glassesSmoothingMaxDepth = 6

    // plan 15: when true, GlassesSource skips the local HEVC decode + LiveKit
    // re-encode path and instead serves raw Annex-B HEVC from the DAT stream
    // over a TCP listener on glassesEncodedIngestPort. The lk relay (or ffplay
    // for stage 1 verification) consumes from there. Default false ships the
    // opt-in path until measured against the current pipeline (stage 2).
    static let glassesEncodedIngest = false
    static let glassesEncodedIngestPort: UInt16 = 16400
}
