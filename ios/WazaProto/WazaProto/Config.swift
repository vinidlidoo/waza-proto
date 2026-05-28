import Foundation

enum Config {
    static let viewerHost = "https://waza-proto.vercel.app"
    static let publisherHost = "https://waza-proto.vercel.app"

    static func viewerURL(invite: String) -> URL {
        URL(string: "\(viewerHost)/?invite=\(invite)")!
    }

    static func publisherTokenURL(auth: String) -> URL {
        URL(string: "\(publisherHost)/api/publisher-token?auth=\(auth)")!
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
    static let glassesEncodedIngest = true
    static let glassesEncodedIngestPort: UInt16 = 16400

    // plan 16: when true, the encoded-ingest path runs HEVC frames through
    // EncodedFrameSmoother before TCP send (PTS-paced ring buffer). When
    // false, the smoother is bypassed and bytes go straight from the
    // extractor to the TCP listener — same code path as the morning's
    // stage-2 baseline. Used for A/B testing whether the smoother is
    // helping or hurting.
    static let glassesEncodedSmootherEnabled = false
}
