import MWDATMockDeviceTestClient
import XCTest

/// Stage-4 XCUITests. Smoke-only: drives the `--ui-testing` app entry point
/// through Meta's out-of-process Mock Device test server and asserts the
/// SwiftUI Connect button enables once the mock pair propagates through
/// `Wearables.shared` → `GlassesGateway.isReady`.
///
/// The original stage-4 ambition (full Connect → "Publishing" UI flow, plus
/// hinge-fold + source-toggle assertions) was empirically re-scoped after the
/// spike: stage-3 found `stream.videoFramePublisher` never fires on iOS 26.5
/// simulator with the in-process MDK API, and the test-server path hits the
/// same wall because it runs the same `MockDeviceKit.shared` internals — just
/// with a different lifecycle wrapper. Findings logged in plan 08.
final class ConnectFlowUITests: XCTestCase {

    private var portFilePath: String!
    private var app: XCUIApplication!
    private var mockClient: MockDeviceTestClient!

    override func setUpWithError() throws {
        continueAfterFailure = false

        // Tmp file the host app writes the server port into and the client
        // reads back. Unique per test so parallel runs don't collide.
        let tmpDir = NSTemporaryDirectory()
        portFilePath = (tmpDir as NSString).appendingPathComponent(
            "mdat-test-server-\(UUID().uuidString).port"
        )
        try? FileManager.default.removeItem(atPath: portFilePath)

        app = XCUIApplication()
        app.launchArguments += ["--ui-testing"]
        app.launchEnvironment["MWDAT_TEST_SERVER_PORT_FILE"] = portFilePath
        app.launch()

        mockClient = MockDeviceTestClient(portFilePath: portFilePath)
        XCTAssertTrue(
            mockClient.waitForServer(timeout: 10),
            "MDK test server did not come up within 10s — check the --ui-testing init path in WazaProtoApp.swift"
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: portFilePath)
        app = nil
        mockClient = nil
    }

    /// Pair a mock device via the HTTP test server; assert the SwiftUI Connect
    /// button becomes enabled once `GlassesGateway.isReady` flips. Catches
    /// regressions in: the `--ui-testing` app-init gate, the
    /// MWDATMockDevice→main-app linkage, the `MockDeviceTestClient` port-file
    /// handshake, and the picker-driven `canConnect` gating in ContentView.
    func testPairingMockDeviceEnablesConnect() throws {
        guard let deviceId = mockClient.pairDevice() else {
            return XCTFail("pairDevice() returned nil — server not ready or out of mock slots")
        }
        // Set a camera feed so we don't drift from the original stage-4 setup;
        // not strictly needed for this assertion but exercises the
        // host-app-bundle resource path through the test server.
        _ = mockClient.setCameraFeed(deviceId: deviceId, resourceName: "mock-camera", ext: "mp4")

        // Glasses picker option exists in the segmented control. With
        // `initiallyRegistered: true, initialPermissionsGranted: true` (set in
        // WazaProtoApp's --ui-testing branch) + a paired mock,
        // `glasses.isReady` should flip true and Connect should enable.
        app.buttons["Glasses"].tap()

        let connect = app.buttons["Connect"]
        let connectEnabled = NSPredicate(format: "isEnabled == true")
        let expectation = XCTNSPredicateExpectation(predicate: connectEnabled, object: connect)
        XCTAssertEqual(
            XCTWaiter().wait(for: [expectation], timeout: 10),
            .completed,
            "Connect never enabled — GlassesGateway didn't see activeDevice from the mock pair (check MWDATMockDevice linkage to main app + the --ui-testing branch in WazaProtoApp.swift)"
        )
    }
}
