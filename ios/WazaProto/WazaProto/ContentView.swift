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
                .overlay(alignment: .bottomTrailing) {
                    if case .connected = connection.status {
                        coachButton
                    }
                }
                .overlay(alignment: .bottom) {
                    if let coachError = connection.coachError {
                        Text(coachError)
                            .font(.caption.bold())
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(.orange.opacity(0.9), in: Capsule())
                            .foregroundStyle(.white)
                            .padding(.bottom, 12)
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
                connectButton
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

    /// Pre-connect gate decision. Delegates to `GlassesGateway.gateAction` — the
    /// pure single source of truth (incl. the `nil`-permission cold-start rule,
    /// documented there). `glassesGate` renders it, `showGlassesGate` checks
    /// emptiness, and `statusLabel` defers to it.
    private var glassesGateAction: GlassesGateAction {
        GlassesGateway.gateAction(
            registrationState: glasses.registrationState,
            hasActiveDevice: glasses.activeDeviceID != nil,
            cameraPermission: glasses.cameraPermission
        )
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
        case .frontCamera, .rearCamera: return true
        case .glasses:                  return glasses.isReady
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

    // Summon / dismiss the AI coach, overlaid in the live preview's lower-right
    // corner. Only meaningful once the room exists, so ContentView shows it
    // only while `.connected`. Icon-only; the color mirrors the
    // Connect/Disconnect convention — blue prominent when off (summon), gray
    // with a red sparkle when on (dismiss). State tracks the coach's actual
    // presence (RoomConnection.coachPresent); coachBusy holds the spinner from
    // tap until the room reflects the change.
    @ViewBuilder
    private var coachButton: some View {
        Group {
            if connection.coachBusy {
                // Same solid footprint as the off-state so it stays visible
                // over the video — a bare ProgressView was nearly invisible.
                Button {} label: {
                    ProgressView()
                        .tint(.white)
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)
            } else if connection.coachPresent {
                Button { connection.dismissCoach() } label: {
                    Image(systemName: "sparkles")
                        .foregroundStyle(.red)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color(.systemGray3))
            } else {
                Button { connection.summonCoach() } label: {
                    Image(systemName: "sparkles")
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)
            }
        }
        .padding(14)
    }

    // Connect / disconnect, as a borderless icon in the status row alongside
    // the link and debug toggles. Mirrors the bug button's fill convention:
    // `video.fill` while connected, outline `video` while disconnected. A
    // spinner stands in during the .connecting / .switching transitions.
    @ViewBuilder
    private var connectButton: some View {
        switch connection.status {
        case .disconnected, .failed:
            Button { connection.connect(source: source, glasses: glasses) } label: {
                Image(systemName: "video")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .disabled(!canConnect)
        case .connecting, .switching:
            ProgressView()
                .controlSize(.small)
        case .connected:
            Button(action: connection.disconnect) {
                Image(systemName: "video.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
        }
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
