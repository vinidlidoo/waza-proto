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
        case frontCamera = "Front camera"
        case glasses = "Glasses"
        var id: String { rawValue }
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

    let room = Room()
    private var publisher: VideoPublisher?

    override init() {
        super.init()
        room.add(delegate: self)
    }

    func connect(source: Source, glasses: GlassesGateway) {
        Task {
            status = .connecting
            let publisher = makePublisher(source: source, glasses: glasses)
            self.publisher = publisher
            do {
                try await room.connect(url: Secrets.wsURL, token: Secrets.token)
                watcherCount = currentWatcherCount()
                localVideoTrack = try await publisher.publish(to: room)
                status = .connected
            } catch {
                status = .failed("\(type(of: error)).\(error) — \(error.localizedDescription)")
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
                if let oldPublisher { await oldPublisher.unpublish(from: room) }
                localVideoTrack = nil
                publisher = newPublisher
                localVideoTrack = try await newPublisher.publish(to: room)
                status = .connected
            } catch {
                status = .failed("\(type(of: error)).\(error) — \(error.localizedDescription)")
                await newPublisher.unpublish(from: room)
                await room.disconnect()
                publisher = nil
            }
        }
    }

    func disconnect() {
        Task {
            if let publisher { await publisher.unpublish(from: room) }
            await room.disconnect()
            publisher = nil
            localVideoTrack = nil
            watcherCount = 0
            status = .disconnected
        }
    }

    private func makePublisher(source: Source, glasses: GlassesGateway) -> VideoPublisher {
        switch source {
        case .frontCamera:
            return FrontCameraSource()
        case .glasses:
            return GlassesSource(
                wearables: glasses.wearables,
                deviceSelector: glasses.deviceSelector,
                onTerminated: { [weak self] in self?.handleGlassesTerminated() }
            )
        }
    }

    // Count only participants that look like our viewers (identity minted by
    // api/token.js as `viewer-<8chars>`). Filters out stale ghosts and any
    // future agent/system participants in the room.
    private func currentWatcherCount() -> Int {
        room.remoteParticipants.values.filter {
            ($0.identity?.stringValue ?? "").hasPrefix("viewer-")
        }.count
    }

    private func handleGlassesTerminated() {
        // Called from GlassesSource's watchdog when its DAT DeviceSession ends
        // unexpectedly (e.g. hinge fold). Tear the LiveKit side down cleanly so
        // the viewer flips to "waiting for video" and the user can hit Connect
        // again once the glasses are usable.
        guard publisher is GlassesSource else { return }
        Task {
            if let publisher { await publisher.unpublish(from: room) }
            await room.disconnect()
            self.publisher = nil
            localVideoTrack = nil
            watcherCount = 0
            status = .failed("Glasses session ended — unfold and reconnect")
        }
    }
}

extension RoomConnection: RoomDelegate {
    nonisolated func room(_ room: Room, participantDidConnect participant: RemoteParticipant) {
        Task { @MainActor in self.watcherCount = self.currentWatcherCount() }
    }

    nonisolated func room(_ room: Room, participantDidDisconnect participant: RemoteParticipant) {
        Task { @MainActor in self.watcherCount = self.currentWatcherCount() }
    }
}
