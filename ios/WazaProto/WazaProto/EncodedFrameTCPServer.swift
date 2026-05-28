import Foundation
import Network

// Single-client TCP server that streams raw Annex-B HEVC bytes to whoever
// connects on the configured port. Stage 1 consumer is `ffplay -i tcp://...`
// or `nc | ffplay -`; stage 2 consumer is `lk room join --publish h265://`.
// Latest-wins on a second connect — the prior socket is cancelled so a
// reconnecting `lk` doesn't have to wait for a stale client to time out.
final class EncodedFrameTCPServer: @unchecked Sendable {
    private let port: UInt16
    private let queue = DispatchQueue(label: "waza.encoded-tcp.server")
    private var listener: NWListener?
    private var connection: NWConnection?

    init(port: UInt16) {
        self.port = port
    }

    func start() throws {
        guard listener == nil else { return }
        let params = NWParameters.tcp
        // SO_REUSEADDR: stop() is async; back-to-back publish→unpublish→publish
        // cycles race the kernel's TIME_WAIT and trigger "Address already in use"
        // without this. Costs nothing — only one listener instance exists at a time.
        params.allowLocalEndpointReuse = true
        let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        // Plain raw TCP listener — no Bonjour service attachment. Local Network
        // permission is granted via the separate NWBrowser preflight in
        // LocalNetworkAuthorization before this is ever called.
        listener.newConnectionHandler = { [weak self] newConnection in
            self?.adopt(newConnection)
        }
        listener.stateUpdateHandler = { state in
            print("[tcp] listener state → \(state)")
        }
        listener.start(queue: queue)
        self.listener = listener
        print("[tcp] listening on port \(port)")
    }

    func stop() {
        queue.async { [weak self] in
            self?.listener?.cancel()
            self?.listener = nil
            self?.connection?.cancel()
            self?.connection = nil
        }
    }

    // Drops only the active client connection, leaving the listener bound.
    // Use this between publish cycles; full stop() is for app shutdown.
    func dropClient() {
        queue.async { [weak self] in
            self?.connection?.cancel()
            self?.connection = nil
        }
    }

    // Called from the DAT frame callback (background queue). Hops onto the
    // server queue so all state access stays serialized. No state guard:
    // NWConnection.send queues writes if the connection isn't yet .ready
    // and flushes them on transition. Dropping un-readyable sends would
    // discard the parameter-set-bearing first IDR.
    private var sendCount = 0
    func send(_ data: Data) {
        queue.async { [weak self] in
            guard let self, let connection = self.connection else { return }
            self.sendCount += 1
            if self.sendCount == 1 || self.sendCount % 60 == 0 {
                print("[tcp] send #\(self.sendCount) (\(data.count) B), conn state=\(connection.state)")
            }
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    print("[tcp] send error: \(error)")
                }
            })
        }
    }

    private func adopt(_ newConnection: NWConnection) {
        if let existing = connection {
            print("[tcp] new client connected; dropping prior")
            existing.cancel()
        }
        connection = newConnection
        newConnection.stateUpdateHandler = { [weak self] state in
            print("[tcp] connection state → \(state)")
            switch state {
            case .failed, .cancelled:
                self?.queue.async { [weak self] in
                    if self?.connection === newConnection {
                        self?.connection = nil
                    }
                }
            default:
                break
            }
        }
        // Surfaces Local Network privacy denial on the inbound path; without
        // this, an LNP-blocked connection just sits in `.preparing` silently
        // (Apple TN3179: inbound denial does NOT raise a .failed state, only
        // the path's unsatisfiedReason carries the signal).
        newConnection.pathUpdateHandler = { path in
            print("[tcp] inbound path: status=\(path.status), unsat=\(String(describing: path.unsatisfiedReason))")
        }
        newConnection.start(queue: queue)
    }
}
