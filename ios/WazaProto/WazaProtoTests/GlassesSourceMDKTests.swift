import MWDATCore
import MWDATMockDevice
import XCTest
@testable import WazaProto

/// Stage-3 MDK tests. Empirical findings on iOS 26.5 simulator (logged in
/// plan 08): MDK pair + unfold registers a mock device the real
/// `Wearables.shared` can see and `AutoDeviceSelector` will activate, but
/// the simulator does NOT deliver frames into `Stream.videoFramePublisher`
/// (with `.hvc1` or `.raw`), and `mockDevice.fold()` does not propagate to
/// session termination. So tests here cover what's verifiable on simulator
/// — MDK setup is seen end-to-end by the real SDK — and stop there. Frame
/// pipeline and hinge-fold teardown stay covered by on-device runs; stage 4
/// will revisit via MDK's out-of-process test server.
@MainActor
final class GlassesSourceMDKTests: MockDeviceKitTestCase {

    private var deviceSelector: AutoDeviceSelector!
    private var selectorTask: Task<Void, Never>?
    private var activeDeviceID: String?

    override func setUp() async throws {
        try await super.setUp()
        deviceSelector = AutoDeviceSelector(wearables: Wearables.shared)
        // AutoDeviceSelector only tracks devices while activeDeviceStream()
        // is being consumed. Mirrors GlassesGateway at runtime.
        selectorTask = Task { [weak self] in
            guard let stream = self?.deviceSelector.activeDeviceStream() else { return }
            for await id in stream {
                self?.activeDeviceID = id
            }
        }
    }

    override func tearDown() async throws {
        selectorTask?.cancel()
        selectorTask = nil
        deviceSelector = nil
        activeDeviceID = nil
        try await super.tearDown()
    }

    /// After MDK pair + unfold + 1s settle (in the base class), the real
    /// `Wearables.shared` discovers the mock and `AutoDeviceSelector`
    /// surfaces it as active. Catches regressions in the MDK plumbing — pbx
    /// product dependency, fixture URL, pair/unfold sequence.
    func testWearablesDiscoversMockDevice() async throws {
        let deadline = Date().addingTimeInterval(5)
        while activeDeviceID == nil && Date() < deadline {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertNotNil(activeDeviceID, "AutoDeviceSelector did not surface the mock device")
        XCTAssertFalse(Wearables.shared.devices.isEmpty, "Wearables.shared.devices was empty after MDK pair")
    }
}
