import LiveKit
import MWDATCore
import SwiftUI
import UIKit

struct ContentView: View {
    @StateObject private var connection = RoomConnection()
    @EnvironmentObject private var glasses: GlassesGateway
    @State private var source: RoomConnection.Source = .frontCamera
    @State private var switcherExpanded = false
    @State private var copyToast: String?
    @AppStorage("showDebug") private var showDebug: Bool = false

    private var isConnected: Bool {
        if case .connected = connection.status { return true }
        return false
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                LocalPreview(track: connection.localVideoTrack, mirror: source == .frontCamera)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    // Full-bleed: video runs to the hardware edges (top always; bottom
                    // only when debug isn't splitting the screen). The device's own
                    // screen corners frame it — no drawn border.
                    .ignoresSafeArea(edges: showDebug ? .top : .all)
                if connection.localVideoTrack == nil {
                    wazaLogo   // launch + post-Stop: brand the black screen
                }
                scrims
                    .ignoresSafeArea(edges: showDebug ? .top : .all)
                    .allowsHitTesting(false)
                controlsLayer   // respects the safe area, so nothing hides under the island
            }
            if showDebug {
                debugPanel
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .onAppear {
            glasses.startObserving()
            Task { await glasses.refreshCameraPermission() }
        }
    }

    // MARK: - Layers

    // Brand mark on the black screen when no preview is live. The app icon art
    // is dark-on-black, so it blends; sized to ~half the screen width.
    private var wazaLogo: some View {
        Image("WazaLogo")
            .resizable()
            .scaledToFit()
            .containerRelativeFrame(.horizontal) { width, _ in width * 0.5 }
            .allowsHitTesting(false)
    }

    // Top + bottom legibility scrims — invisible over dark feeds, keep the
    // controls readable over bright ones. Decorative, never intercepts taps.
    private var scrims: some View {
        VStack(spacing: 0) {
            LinearGradient(colors: [.black.opacity(0.45), .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: 140)
            Spacer(minLength: 0)
            LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .top, endPoint: .bottom)
                .frame(height: 160)
        }
    }

    // All floating controls, in the safe-area corners. The clear base catches
    // taps on empty video to collapse the source switcher.
    private var controlsLayer: some View {
        Color.clear
            .contentShape(Rectangle())
            .onTapGesture {
                if switcherExpanded {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.72)) { switcherExpanded = false }
                }
            }
            .overlay(alignment: .topLeading) { debugHotCorner }
            .overlay(alignment: .topTrailing) { if isConnected { audienceCluster } }
            .overlay(alignment: .top) { messagePill }
            .overlay(alignment: .bottomLeading) { sourceSwitcher }
            .overlay(alignment: .bottom) { connectControl }
            .overlay(alignment: .bottomTrailing) { if isConnected { coachButton } }
            .overlay { glassesGateCard }
    }

    // MARK: - Source switcher (bottom-left, blooms upward)

    private var switcherOrdered: [RoomConnection.Source] {
        // Active anchored at the bottom; the others bloom above it.
        RoomConnection.Source.allCases.filter { $0 != source } + [source]
    }

    private var sourceSwitcher: some View {
        VStack(spacing: 10) {
            if switcherExpanded {
                ForEach(switcherOrdered) { switcherPill($0) }
            } else {
                switcherPill(source)
            }
        }
        .padding(14)
    }

    private func switcherPill(_ src: RoomConnection.Source) -> some View {
        let isActive = src == source
        let isDimmed = !canConnect(for: src)   // glasses off-link / not ready
        return Button {
            if !switcherExpanded {
                withAnimation(.spring(response: 0.32, dampingFraction: 0.72)) { switcherExpanded = true }
            } else if isActive {
                withAnimation(.spring(response: 0.32, dampingFraction: 0.72)) { switcherExpanded = false }
            } else {
                selectSource(src)
            }
        } label: {
            Image(systemName: src.glyph)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(.ultraThinMaterial, in: Circle())
                .opacity(isDimmed ? 0.4 : 1)
        }
        .buttonStyle(.plain)
        .disabled(pickerDisabled)   // locked during .connecting / .switching
    }

    // Same contract as the old Picker.onChange: never tear down a working
    // stream to chase an unready source (revert by no-op); when disconnected,
    // selecting glasses just sets the source so its gate card can appear.
    private func selectSource(_ newSource: RoomConnection.Source) {
        withAnimation(.spring(response: 0.32, dampingFraction: 0.72)) { switcherExpanded = false }
        guard newSource != source else { return }
        if isConnected {
            guard canConnect(for: newSource) else { return }
            connection.switchSource(to: newSource, glasses: glasses)
        }
        source = newSource
    }

    // MARK: - Connect (bottom-center, play/stop)

    @ViewBuilder
    private var connectControl: some View {
        Group {
            switch connection.status {
            case .disconnected, .failed:
                Button { connection.connect(source: source, glasses: glasses) } label: {
                    Image(systemName: "play.fill")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(.white)          // white reads over the dark/disconnected feed
                        .frame(width: 44, height: 44)
                        .background(.regularMaterial, in: Circle())
                        .opacity(canConnect ? 1 : 0.4)
                }
                .buttonStyle(.plain)
                .disabled(!canConnect)
            case .connecting, .switching:
                ProgressView()
                    .controlSize(.small)
                    .tint(.white)
                    .frame(width: 44, height: 44)
                    .background(.regularMaterial, in: Circle())
            case .connected:
                Button(action: connection.disconnect) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(Color.red, in: Circle())   // red = live
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.bottom, 14)
    }

    // MARK: - Coach (bottom-right, live only)

    // Reuses the coach state machine (coachBusy / coachPresent) and the
    // summon/dismiss calls; only restyled to a 44pt circle. Blue = summon,
    // gray + red sparkle = dismiss (present), spinner = busy.
    @ViewBuilder
    private var coachButton: some View {
        Group {
            if connection.coachBusy {
                ProgressView()
                    .tint(.white)
                    .frame(width: 44, height: 44)
                    .background(Color.blue, in: Circle())
            } else if connection.coachPresent {
                Button { connection.dismissCoach() } label: {
                    coachLabel("sparkles", fg: .red, bg: Color(.systemGray3))
                }
                .buttonStyle(.plain)
            } else {
                Button { connection.summonCoach() } label: {
                    coachLabel("sparkles", fg: .white, bg: .blue)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
    }

    private func coachLabel(_ name: String, fg: Color, bg: some ShapeStyle) -> some View {
        Image(systemName: name)
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(fg)
            .frame(width: 44, height: 44)
            .background(bg, in: Circle())
    }

    // MARK: - Audience (top-right, live only)

    private var audienceCluster: some View {
        HStack(spacing: 8) {
            if connection.watcherCount > 0 {
                Text("\(connection.watcherCount) watching")
                    .font(.caption.bold())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.red.opacity(0.85), in: Capsule())
                    .foregroundStyle(.white)
            }
            Button(action: copyViewerLink) {
                Image(systemName: "link")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(12)
    }

    // MARK: - Debug toggle (hidden)

    // No visible affordance — long-press the top-left corner to reveal/hide the
    // debug panel. When it's open the panel itself is the "it's on" signal, so
    // the same gesture dismisses it.
    private var debugHotCorner: some View {
        Color.clear
            .frame(width: 90, height: 90)
            .contentShape(Rectangle())
            .onLongPressGesture(minimumDuration: 0.6) {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) { showDebug.toggle() }
            }
    }

    // MARK: - Ephemeral message pill (top-center)

    // Replaces the persistent status bar: a transient pill that appears only
    // when there's something to say — green for the copy toast, red for a
    // failure or the "don glasses" guidance. Inset so it clears the corner
    // controls. The gate card carries register/permission messaging instead.
    @ViewBuilder
    private var messagePill: some View {
        if let copyToast {
            pill(copyToast, color: .green.opacity(0.9))
        } else if case .failed = connection.status {
            pill(connection.status.label, color: .red)
        } else if source == .glasses,
                  case .disconnected = connection.status,
                  glasses.activeDeviceID == nil,
                  !showGlassesGate {
            pill("Don glasses to connect", color: .red)
        }
    }

    private func pill(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption.bold())
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(color, in: Capsule())
            .shadow(radius: 4)
            .padding(.horizontal, 56)   // never overlap the top corner controls
            .padding(.top, 8)
    }

    private func copyViewerLink() {
        let url = Config.viewerURL(invite: InviteToken.mint())
        UIPasteboard.general.string = url.absoluteString
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        let token = "Link copied (valid 3h)"
        withAnimation { copyToast = token }
        Task {
            try? await Task.sleep(for: .seconds(2))
            if copyToast == token { withAnimation { copyToast = nil } }
        }
    }

    // MARK: - Glasses gate (re-housed as a centered overlay card)

    /// Pre-connect gate decision. Delegates to `GlassesGateway.gateAction` — the
    /// pure single source of truth (incl. the `nil`-permission cold-start rule,
    /// documented there). `glassesGateCard` renders it, `showGlassesGate` checks
    /// emptiness, and `statusLabel` defers to it.
    private var glassesGateAction: GlassesGateAction {
        GlassesGateway.gateAction(
            registrationState: glasses.registrationState,
            hasActiveDevice: glasses.activeDeviceID != nil,
            cameraPermission: glasses.cameraPermission
        )
    }

    private var showGlassesGate: Bool { glassesGateAction != .none }

    @ViewBuilder
    private var glassesGateCard: some View {
        if source == .glasses, showGlassesGate {
            VStack(spacing: 12) {
                switch glassesGateAction {
                case .none:
                    EmptyView()
                case .register:
                    Text("Register with Meta AI").font(.callout.bold())
                    Button("Register") { Task { await glasses.register() } }
                        .buttonStyle(.borderedProminent)
                case .grantCamera:
                    Text("Grant camera access").font(.callout.bold())
                    Button("Grant access") { Task { await glasses.requestCameraAccess() } }
                        .buttonStyle(.borderedProminent)
                }
            }
            .foregroundStyle(.white)
            .padding(20)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
            .padding(40)
        }
    }

    private var statusLabel: String {
        // While a gate card is up, it carries the messaging — don't double up.
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

    // MARK: - Debug panel (below the shrunk video, debug only)

    private var debugPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text(statusLabel)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                profilerDebug
                devicesDebug
            }
            .padding(12)
        }
        .frame(maxHeight: 280)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(white: 0.1))
        .overlay(alignment: .top) { Rectangle().fill(.white.opacity(0.15)).frame(height: 0.5) }
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
}

private extension RoomConnection.Source {
    var glyph: String {
        switch self {
        case .frontCamera: return "person.fill"   // you / selfie
        case .rearCamera:  return "camera.fill"    // the world
        case .glasses:     return "eyeglasses"
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
