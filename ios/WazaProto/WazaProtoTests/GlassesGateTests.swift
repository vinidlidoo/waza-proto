import MWDATCore
import XCTest
@testable import WazaProto

/// Exhaustive truth table for the pre-connect gate predicate — the single most
/// regression-prone piece of UI logic in the app (the "Grant camera access"
/// row has wrongly reappeared multiple times). This is the *primary* guard: a
/// pure function is the only layer that can express the `nil`-permission race
/// (link-down-while-active), which MDK's config/`set` cannot reproduce. The
/// MDK wiring test (GlassesGatewayMDKTests) complements it for the states MDK
/// *can* express.
final class GlassesGateTests: XCTestCase {

    // MARK: - gateAction

    func testNotRegisteredAlwaysYieldsRegister() {
        // Regardless of device presence or permission, anything that isn't
        // `.registered` gates on registration first.
        for state in [RegistrationState.unavailable, .available, .registering] {
            XCTAssertEqual(
                GlassesGateway.gateAction(registrationState: state, hasActiveDevice: true, cameraPermission: .granted),
                .register, "\(state) should gate on register"
            )
            XCTAssertEqual(
                GlassesGateway.gateAction(registrationState: state, hasActiveDevice: false, cameraPermission: .denied),
                .register, "\(state) should gate on register"
            )
        }
    }

    func testRegisteredNoActiveDeviceYieldsNone() {
        // The "don glasses to connect" path — no gate row, just a status label.
        XCTAssertEqual(
            GlassesGateway.gateAction(registrationState: .registered, hasActiveDevice: false, cameraPermission: .denied),
            .none
        )
        XCTAssertEqual(
            GlassesGateway.gateAction(registrationState: .registered, hasActiveDevice: false, cameraPermission: nil),
            .none
        )
    }

    func testRegisteredActiveDeniedYieldsGrantCamera() {
        XCTAssertEqual(
            GlassesGateway.gateAction(registrationState: .registered, hasActiveDevice: true, cameraPermission: .denied),
            .grantCamera
        )
    }

    func testRegisteredActiveGrantedYieldsNone() {
        XCTAssertEqual(
            GlassesGateway.gateAction(registrationState: .registered, hasActiveDevice: true, cameraPermission: .granted),
            .none
        )
    }

    /// THE regression row. Registered + active + `nil` permission (link
    /// momentarily down mid-fold / cold start, `try?` swallowed the throw to
    /// nil) must NOT show "Grant camera access". The original plan-13 bug gated
    /// on `!= .granted`, which treated nil as denied and reappeared the button
    /// on every cold start. MDK cannot express this state — only the pure
    /// function can pin it.
    func testRegisteredActiveNilPermissionYieldsNone() {
        XCTAssertEqual(
            GlassesGateway.gateAction(registrationState: .registered, hasActiveDevice: true, cameraPermission: nil),
            .none
        )
    }

    // MARK: - isReady

    func testIsReadyOnlyWhenRegisteredWithActiveDevice() {
        XCTAssertTrue(GlassesGateway.isReady(registrationState: .registered, hasActiveDevice: true))
        XCTAssertFalse(GlassesGateway.isReady(registrationState: .registered, hasActiveDevice: false))
        XCTAssertFalse(GlassesGateway.isReady(registrationState: .available, hasActiveDevice: true))
        XCTAssertFalse(GlassesGateway.isReady(registrationState: .unavailable, hasActiveDevice: false))
    }
}
