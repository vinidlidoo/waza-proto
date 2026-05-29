import MWDATCore
import MWDATMockDevice
import XCTest
@testable import WazaProto

/// Stage-4 wiring test (plan 18). Proves the stage-3 pure predicate is actually
/// connected to reality: that `GlassesGateway.refreshCameraPermission()`
/// translates the SDK's permission answer into the published `cameraPermission`
/// the gate reads. This is the layer where the "Grant camera access" bug
/// actually lived.
///
/// Stays inside MDK's working surface: #197 only breaks frame delivery +
/// fold-propagation, not device/registration/permission state. Permission is
/// settable at runtime via `MockDeviceKit.shared.permissions.set` (in-process
/// only — the test server has no permission method), and a *connected* mock
/// returns the status rather than throwing (probe-confirmed 2026-05-28). We
/// wait for the selector to surface the mock as active before querying, so the
/// link is up and `checkPermissionStatus` returns a definitive answer instead
/// of throwing → nil.
@MainActor
final class GlassesGatewayMDKTests: MockDeviceKitTestCase {

    private var gateway: GlassesGateway!

    override func setUp() async throws {
        try await super.setUp()
        gateway = GlassesGateway()
        gateway.startObserving()
        try await waitForActiveDevice()
    }

    override func tearDown() async throws {
        gateway = nil
        try await super.tearDown()
    }

    /// Denied mock → `cameraPermission == .denied` → gate yields `.grantCamera`.
    func testDeniedPermissionWiresToGrantCameraGate() async throws {
        MockDeviceKit.shared.permissions.set(.camera, .denied)
        await gateway.refreshCameraPermission()

        XCTAssertEqual(gateway.cameraPermission, .denied,
                       "refreshCameraPermission must translate a denied mock into .denied (not nil)")
        XCTAssertEqual(
            GlassesGateway.gateAction(
                registrationState: .registered,
                hasActiveDevice: true,
                cameraPermission: gateway.cameraPermission
            ),
            .grantCamera
        )
    }

    /// Granted mock → `cameraPermission == .granted` → no gate.
    func testGrantedPermissionWiresToNoGate() async throws {
        MockDeviceKit.shared.permissions.set(.camera, .granted)
        await gateway.refreshCameraPermission()

        XCTAssertEqual(gateway.cameraPermission, .granted)
        XCTAssertEqual(
            GlassesGateway.gateAction(
                registrationState: .registered,
                hasActiveDevice: true,
                cameraPermission: gateway.cameraPermission
            ),
            .none
        )
    }

    // MARK: - Helpers

    /// The gateway's own `AutoDeviceSelector` must surface the paired mock as
    /// active before permission queries are reliable (off-link → throw → nil).
    private func waitForActiveDevice() async throws {
        let deadline = Date().addingTimeInterval(5)
        while gateway.activeDeviceID == nil && Date() < deadline {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertNotNil(gateway.activeDeviceID, "gateway did not surface the mock device as active")
    }
}
