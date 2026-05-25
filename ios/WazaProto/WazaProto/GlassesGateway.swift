import Combine
import MWDATCore
import SwiftUI

struct DeviceDescription: Identifiable {
    let id: String
    let summary: String
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
        registrationState == .registered && activeDeviceID != nil
    }
}
