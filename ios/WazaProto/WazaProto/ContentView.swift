import LiveKit
import SwiftUI

struct ContentView: View {
    @StateObject private var connection = RoomConnection()

    var body: some View {
        VStack(spacing: 16) {
            LocalPreview(track: connection.localVideoTrack)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)
                .clipShape(RoundedRectangle(cornerRadius: 12))

            Text(connection.status.label)
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)

            actionButton
        }
        .padding()
    }

    @ViewBuilder
    private var actionButton: some View {
        switch connection.status {
        case .disconnected, .failed:
            Button("Connect", action: connection.connect)
                .buttonStyle(.borderedProminent)
        case .connecting:
            ProgressView()
        case .connected:
            Button("Disconnect", role: .destructive, action: connection.disconnect)
                .buttonStyle(.bordered)
        }
    }
}

/// SwiftUI wrapper around LiveKit's UIKit-based `VideoView` so we can render
/// the local camera publication as a live preview.
private struct LocalPreview: UIViewRepresentable {
    let track: VideoTrack?

    func makeUIView(context: Context) -> VideoView {
        let view = VideoView()
        view.layoutMode = .fit
        view.mirrorMode = .auto  // front-camera previews look natural mirrored
        return view
    }

    func updateUIView(_ view: VideoView, context: Context) {
        view.track = track
    }
}

#Preview {
    ContentView()
}
