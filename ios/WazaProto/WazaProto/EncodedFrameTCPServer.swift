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
        params.allowFastOpen = true
        let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
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

    // Called from the DAT frame callback (background queue). Hops onto the
    // server queue so all state access stays serialized.
    func send(_ data: Data) {
        queue.async { [weak self] in
            guard let self, let connection = self.connection, connection.state == .ready else { return }
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
        newConnection.start(queue: queue)
    }
}
