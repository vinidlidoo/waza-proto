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
    static let glassesSmoothingDepth = 4
    static let glassesSmoothingMaxDepth = 6
}
