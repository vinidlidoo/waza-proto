import LiveKit
import MWDATCore
import SwiftUI
import UIKit

struct ContentView: View {
    @StateObject private var connection = RoomConnection()
    @EnvironmentObject private var glasses: GlassesGateway
    @State private var source: RoomConnection.Source = .frontCamera
    @State private var copyToast: String?
    @AppStorage("showDebug") private var showDebug: Bool = false

    var body: some View {
        VStack(spacing: 16) {
            LocalPreview(track: connection.localVideoTrack, mirror: source == .frontCamera)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(alignment: .topTrailing) {
                    if case .connected = connection.status, connection.watcherCount > 0 {
                        Text("\(connection.watcherCount) watching")
                            .font(.caption.bold())
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.red.opacity(0.85), in: Capsule())
                            .foregroundStyle(.white)
                            .padding(8)
                    }
                }

            Picker("Source", selection: $source) {
                ForEach(RoomConnection.Source.allCases) { src in
                    Text(src.rawValue).tag(src)
                }
            }
            .pickerStyle(.segmented)
            .disabled(pickerDisabled)
            .onChange(of: source) { oldSource, newSource in
                guard case .connected = connection.status else { return }
                // Don't tear down a working stream to chase an unready source —
                // switchSource would unpublish the current track, fail to publish
                // the new one, and disconnect the room entirely.
                guard canConnect(for: newSource) else {
                    source = oldSource
                    return
                }
                connection.switchSource(to: newSource, glasses: glasses)
            }

            if source == .glasses, showGlassesGate {
                glassesGate
            }
            if showDebug {
                profilerDebug
                devicesDebug
            }

            HStack(spacing: 12) {
                Text(copyToast ?? statusLabel)
                    .font(.callout.monospaced())
                    .foregroundStyle(copyToast == nil ? Color.secondary : Color.green)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button(action: copyViewerLink) {
                    Image(systemName: "link")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                Button {
                    showDebug.toggle()
                } label: {
                    Image(systemName: showDebug ? "ladybug.fill" : "ladybug")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
            }

            actionButton
        }
        .padding()
        .onAppear {
            glasses.startObserving()
            Task { await glasses.refreshCameraPermission() }
        }
    }

    private func copyViewerLink() {
        let url = Config.viewerURL(invite: InviteToken.mint())
        UIPasteboard.general.string = url.absoluteString
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        let token = "Link copied (valid 3h)"
        copyToast = token
        Task {
            try? await Task.sleep(for: .seconds(2))
            if copyToast == token { copyToast = nil }
        }
    }

    /// What action the Glasses tab needs from the user before we can connect.
    /// Single source of truth for the pre-connect gate: `glassesGate` renders
    /// it, `showGlassesGate` checks emptiness, and `statusLabel` defers to
    /// it. The `activeDeviceID != nil` guard on `.grantCamera` is the key —
    /// it ensures we only paint the grant button when glasses are actually
    /// online, so a nil reading of `cameraPermission` reflects "never asked"
    /// rather than "BT link is momentarily down" (which would push the user
    /// toward the wrong fix). Plan 13 dropped this gate on the assumption
    /// that the Meta SDK would surface its own prompt via `session.start` —
    /// empirically false on fresh installs (DAT 0.7.0).
    private enum GlassesGateAction {
        case none
        case register
        case grantCamera
    }

    private var glassesGateAction: GlassesGateAction {
        if glasses.registrationState != .registered { return .register }
        if glasses.activeDeviceID != nil, glasses.cameraPermission != .granted { return .grantCamera }
        return .none
    }

    private var showGlassesGate: Bool { glassesGateAction != .none }

    private var statusLabel: String {
        // While a gate row is up, it carries the messaging — don't double up.
        guard !showGlassesGate else { return connection.status.label }
        if source == .glasses,
           case .disconnected = connection.status,
           glasses.activeDeviceID == nil {
            return "Don glasses to connect"
        }
        return connection.status.label
    }

    private var pickerDisabled: Bool {
        switch connection.status {
        case .connecting, .switching: return true
        default: return false
        }
    }

    private var canConnect: Bool { canConnect(for: source) }

    private func canConnect(for source: RoomConnection.Source) -> Bool {
        switch source {
        case .frontCamera: return true
        case .glasses:     return glasses.isReady
        }
    }

    @ViewBuilder
    private var glassesGate: some View {
        switch glassesGateAction {
        case .none:
            EmptyView()
        case .register:
            gateRow(
                title: "Register with Meta AI",
                action: { Task { await glasses.register() } }
            )
        case .grantCamera:
            gateRow(
                title: "Grant camera access",
                action: { Task { await glasses.requestCameraAccess() } }
            )
        }
    }

    @ViewBuilder
    private var profilerDebug: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Profiler")
                    .font(.caption.bold())
                Spacer()
                if connection.profileRunID == nil {
                    Button("Start 3m") {
                        connection.startProfiling(source: source)
                    }
                    .font(.caption)
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .disabled(!canStartProfiling)
                } else {
                    Button("Stop") {
                        Task { await connection.stopProfiling(incomplete: true) }
                    }
                    .font(.caption)
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                }
            }
            Text(connection.profileRunID.map { "run: \($0)" } ?? "run: inactive")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var canStartProfiling: Bool {
        guard case .connected = connection.status else { return false }
        return connection.profileRunID == nil
    }

    @ViewBuilder
    private var devicesDebug: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("DAT devices: \(glasses.devices.count)")
                    .font(.caption.bold())
                Spacer()
                Button("Refresh", action: glasses.refreshDevices)
                    .font(.caption)
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                Button("DAT app", action: glasses.openGlassesAppManagement)
                    .font(.caption)
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                Button("Unregister") { Task { await glasses.unregister() } }
                    .font(.caption)
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
            }
            Text("activeDevice: \(glasses.activeDeviceID ?? "nil")")
                .font(.caption.monospaced())
                .foregroundStyle(glasses.activeDeviceID == nil ? .red : .green)
            Text("cameraPermission: \(String(describing: glasses.cameraPermission))")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            if glasses.devices.isEmpty {
                Text("(none visible to DAT)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            } else {
                ForEach(glasses.devices) { d in
                    Text(d.summary)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func gateRow(title: String, action: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: "circle")
                .foregroundStyle(.secondary)
            Button(title, action: action)
                .buttonStyle(.bordered)
            Spacer()
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        // Fixed height across all three states (Connect, ProgressView,
        // Disconnect) so the preview area above doesn't change size as we
        // transition through .connecting / .switching.
        Group {
            switch connection.status {
            case .disconnected, .failed:
                Button("Connect") { connection.connect(source: source, glasses: glasses) }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canConnect)
            case .connecting, .switching:
                ProgressView()
            case .connected:
                Button("Disconnect", role: .destructive, action: connection.disconnect)
                    .buttonStyle(.bordered)
            }
        }
        .frame(height: 50)
    }
}

/// SwiftUI wrapper around LiveKit's UIKit-based `VideoView`.
private struct LocalPreview: UIViewRepresentable {
    let track: VideoTrack?
    let mirror: Bool

    func makeUIView(context: Context) -> VideoView {
        let view = VideoView()
        view.layoutMode = .fill
        return view
    }

    func updateUIView(_ view: VideoView, context: Context) {
        view.track = track
        view.mirrorMode = mirror ? .auto : .off
    }
}

#Preview {
    ContentView()
        .environmentObject(GlassesGateway())
}
