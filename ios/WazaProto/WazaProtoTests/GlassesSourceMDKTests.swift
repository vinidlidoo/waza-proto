import MWDATCamera
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
    private var frameSession: DeviceSession?
    private var frameToken: (any AnyListenerToken)?

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
        frameToken = nil
        if let session = frameSession { try? session.stop() }
        frameSession = nil
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

    /// Skipped probe: does `stream.videoFramePublisher` fire on simulator
    /// when the mock device is donned (per issue #171 advice)? Empirically
    /// NO — even with don() in setUp, the listener callback never fires on
    /// iOS 26.5 sim. Kept as a skipped test so the body documents what we
    /// tried; flip `frameProbeEnabled` to true if Meta updates MDK and we
    /// want to re-probe.
    private static let frameProbeEnabled = false

    func testVideoFramePublisherFiresOnSimulator() async throws {
        try XCTSkipUnless(
            Self.frameProbeEnabled,
            "Upstream #197: videoFramePublisher does not fire on iOS 26.5 sim — confirmed across all 6 (codec × resolution) combos with the device donned. Set frameProbeEnabled=true to re-probe when MDK is updated."
        )
        let activeDeadline = Date().addingTimeInterval(5)
        while activeDeviceID == nil && Date() < activeDeadline {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertNotNil(activeDeviceID, "AutoDeviceSelector did not surface the mock")

        // Mirrors production GlassesSource.swift:41-67 — createSession,
        // start, poll for .started, addStream(.hvc1, .high, 30).
        let session = try Wearables.shared.createSession(deviceSelector: deviceSelector)
        frameSession = session
        try session.start()

        let startDeadline = Date().addingTimeInterval(5)
        while session.state != .started && Date() < startDeadline {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertEqual(session.state, .started, "session never reached .started")

        guard let stream = try session.addStream(config: StreamConfiguration(
            videoCodec: .hvc1,
            resolution: .high,
            frameRate: 30
        )) else {
            return XCTFail("addStream returned nil")
        }

        let frameReceived = expectation(description: "first videoFrame")
        frameReceived.assertForOverFulfill = false
        frameToken = stream.videoFramePublisher.listen { _ in
            frameReceived.fulfill()
        }

        await fulfillment(of: [frameReceived], timeout: 10)
    }

}
