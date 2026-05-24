import AVFoundation
import Combine
import LiveKit
import SwiftUI

/// Owns the LiveKit Room and exposes its state to SwiftUI.
///
/// The Swift SDK's Room class is itself an ObservableObject, but we wrap it
/// here so the view binds to one tidy object with a small surface (Connect /
/// Disconnect + status + the live preview track), and so all the async work
/// stays in one file.
@MainActor
final class RoomConnection: ObservableObject {
    // MARK: - Published state
    enum Status: Equatable {
        case disconnected
        case connecting
        case connected
        case failed(String)

        var label: String {
            switch self {
            case .disconnected:     return "Disconnected"
            case .connecting:       return "Connecting…"
            case .connected:        return "Publishing as ios-publisher"
            case .failed(let msg):  return "Error: \(msg)"
            }
        }
    }

    @Published private(set) var status: Status = .disconnected
    @Published private(set) var localVideoTrack: VideoTrack?

    let room = Room()

    // MARK: - Actions

    func connect() {
        Task {
            status = .connecting
            do {
                try await room.connect(url: Secrets.wsURL, token: Secrets.token)
                try await room.localParticipant.setCamera(
                    enabled: true,
                    captureOptions: CameraCaptureOptions(position: .front)
                )
                localVideoTrack = room.localParticipant.firstCameraVideoTrack
                status = .connected
            } catch {
                status = .failed(error.localizedDescription)
                await room.disconnect()
            }
        }
    }

    func disconnect() {
        Task {
            await room.disconnect()
            localVideoTrack = nil
            status = .disconnected
        }
    }
}
