import Combine
import MWDATCore
import SwiftUI

struct DeviceDescription: Identifiable {
    let id: String
    let summary: String
}

/// What the Glasses tab needs from the user before we can connect. The single
/// source of truth for the pre-connect gate decision: `ContentView` renders it,
/// `showGlassesGate` checks emptiness, and `statusLabel` defers to it.
enum GlassesGateAction {
    case none
    case register
    case grantCamera
}

@MainActor
final class GlassesGateway: ObservableObject {
    @Published private(set) var registrationState: RegistrationState = .unavailable
    @Published private(set) var cameraPermission: PermissionStatus?
    @Published private(set) var devices: [DeviceDescription] = []
    @Published private(set) var activeDeviceID: String?

    let wearables: WearablesInterface = Wearables.shared
    // Persistent selector — the SDK only tracks per-device eligibility while
    // *something* is consuming this selector's activeDeviceStream(). A throwaway
    // selector passed inline to createSession produces noEligibleDevice even
    // when link=connected/compat=compatible. See facebook/meta-wearables-dat-ios#148.
    let deviceSelector: AutoDeviceSelector
    private var observationTask: Task<Void, Never>?
    private var devicesTask: Task<Void, Never>?
    private var selectorTask: Task<Void, Never>?

    init() {
        self.deviceSelector = AutoDeviceSelector(wearables: Wearables.shared)
    }

    func startObserving() {
        guard observationTask == nil else { return }
        observationTask = Task {
            for await state in wearables.registrationStateStream() {
                print("[glasses] registrationState → \(state)")
                registrationState = state
                if state == .registered {
                    await refreshCameraPermission()
                }
            }
        }
        devicesTask = Task {
            for await deviceList in wearables.devicesStream() {
                print("[glasses] devicesStream → \(deviceList.count) device(s)")
                devices = deviceList.map { id in
                    guard let d = wearables.deviceForIdentifier(id) else {
                        return DeviceDescription(id: id, summary: "\(id) (no Device)")
                    }
                    return DeviceDescription(
                        id: id,
                        summary: "\(d.nameOrId()) | type=\(d.deviceType().rawValue) | link=\(d.linkState) | compat=\(d.compatibility())"
                    )
                }
            }
        }
        selectorTask = Task {
            for await activeID in deviceSelector.activeDeviceStream() {
                print("[glasses] activeDevice → \(activeID ?? "nil")")
                activeDeviceID = activeID
            }
        }
    }

    func openGlassesAppManagement() {
        Task { try? await wearables.openDATGlassesAppUpdate() }
    }

    func refreshDevices() {
        let ids = wearables.devices
        devices = ids.map { id in
            guard let d = wearables.deviceForIdentifier(id) else {
                return DeviceDescription(id: id, summary: "\(id) (no Device)")
            }
            return DeviceDescription(
                id: id,
                summary: "\(d.nameOrId()) | type=\(d.deviceType().rawValue) | link=\(d.linkState) | compat=\(d.compatibility())"
            )
        }
    }

    func register() async {
        try? await wearables.startRegistration()
    }

    func unregister() async {
        try? await wearables.startUnregistration()
    }

    func requestCameraAccess() async {
        let granted = try? await wearables.requestPermission(.camera)
        print("[glasses] requestPermission(.camera) → \(String(describing: granted))")
        cameraPermission = granted
    }

    func refreshCameraPermission() async {
        let status = try? await wearables.checkPermissionStatus(.camera)
        print("[glasses] checkPermissionStatus(.camera) → \(String(describing: status))")
        // Don't demote .granted → nil. nil typically means "SDK can't check
        // right now" (e.g. glasses momentarily off-link during a hinge fold),
        // not a real revocation; demoting causes the gate to flicker back into
        // view mid-session. A real revocation surfaces as .denied.
        if status != nil || cameraPermission != .granted {
            cameraPermission = status
        }
    }

    func handleUrl(_ url: URL) async {
        print("[glasses] handleUrl(\(url.scheme ?? "?"))")
        _ = try? await wearables.handleUrl(url)
        // Meta AI returns here after both registration and permission flows;
        // refresh the cached camera permission so the gate UI reflects reality.
        if registrationState == .registered {
            await refreshCameraPermission()
        }
    }

    // `activeDeviceID != nil` is the SDK's true "we can start a session" signal
    // (it implies registered + a discovered eligible device). Camera permission
    // is tracked separately for UI purposes but isn't gated here — checkPermissionStatus
    // can lag behind a granted "Always allow", and a missing perm surfaces clearly
    // on session.start anyway.
    var isReady: Bool {
        Self.isReady(registrationState: registrationState, hasActiveDevice: activeDeviceID != nil)
    }

    // MARK: - Pure gate predicate (plan 18)

    /// Pure decision for the pre-connect gate, extracted so it's exhaustively
    /// testable on plain values (the `@Published` props are `private(set)`, so
    /// the live instance isn't drivable from a test). `nonisolated` so the gate
    /// truth table can run off the main actor.
    ///
    /// `.grantCamera` requires an active device AND a *definitive* `.denied`.
    /// DAT answers `checkPermissionStatus` live over the glasses link (it throws
    /// `.noDeviceWithConnection`/`.connectionError` while the link is down,
    /// surfacing here as `nil`) and does not cache the grant across launches —
    /// the grant lives in Meta AI, not our app. So `nil` means "unknown right
    /// now", never "denied": gating on `!= .granted` made the button reappear
    /// on every cold start even after a prior grant (the link isn't up yet when
    /// the view first queries). Plan 13 dropped this gate entirely on the
    /// assumption the SDK would self-prompt via `session.start` — empirically
    /// false on fresh installs (DAT 0.7.0).
    nonisolated static func gateAction(
        registrationState: RegistrationState,
        hasActiveDevice: Bool,
        cameraPermission: PermissionStatus?
    ) -> GlassesGateAction {
        if registrationState != .registered { return .register }
        if hasActiveDevice, cameraPermission == .denied { return .grantCamera }
        return .none
    }

    nonisolated static func isReady(
        registrationState: RegistrationState,
        hasActiveDevice: Bool
    ) -> Bool {
        registrationState == .registered && hasActiveDevice
    }
}
