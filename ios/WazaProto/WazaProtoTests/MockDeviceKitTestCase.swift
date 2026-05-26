import MWDATCore
import MWDATMockDevice
import XCTest

/// Base class for tests that need a virtual Ray-Ban Meta paired with the real
/// DAT SDK via Meta's Mock Device Kit. Subclasses get a paired, powered-on,
/// donned `mockDevice` with the bundled `mock-camera.mp4` set as its camera
/// feed. Teardown unpairs every device and disables the kit so tests don't
/// leak state across files.
@MainActor
class MockDeviceKitTestCase: XCTestCase {
    var mockDevice: (any MockRaybanMeta)!
    var cameraKit: (any MockCameraKit)!

    override func setUp() async throws {
        try await super.setUp()

        // Match Meta's CameraAccessTests setup exactly (samples/CameraAccess/
        // CameraAccessTests/CameraAccessTests.swift:26-28): configure() FIRST,
        // then MDK.enable() with no MockDeviceKitConfig. Streaming/frame
        // delivery appears to require this ordering even though device
        // discovery works without it. `try?` because configure() throws if
        // already configured by an earlier test in the same process.
        try? Wearables.configure()

        let kit = MockDeviceKit.shared
        kit.enable()

        let device = kit.pairRaybanMeta()
        device.powerOn()
        // Meta's CameraAccess sample test uses unfold() (not don()) here —
        // streaming is gated on the unfolded state on simulator. See
        // CHANGELOG entry: "MockDeviceKit: streaming now correctly resumes
        // when the device transitions to donned-disabled and back via
        // fold/unfold cycle".
        device.unfold()

        let bundle = Bundle(for: type(of: self))
        let fixtureURL = try XCTUnwrap(
            bundle.url(forResource: "mock-camera", withExtension: "mp4"),
            "mock-camera.mp4 missing from test bundle — check the fixtures/ folder is added as a Resources build phase on WazaProtoTests"
        )
        device.services.camera.setCameraFeed(fileURL: fixtureURL)

        mockDevice = device
        cameraKit = device.services.camera

        // Meta's CameraAccessTests sample sleeps 1s here so the SDK settles
        // (devicesStream fires, AutoDeviceSelector picks the mock) before any
        // session work. Without it, subsequent createSession can race.
        try await Task.sleep(nanoseconds: 1_000_000_000)
    }

    override func tearDown() async throws {
        let kit = MockDeviceKit.shared
        for device in kit.pairedDevices {
            kit.unpairDevice(device)
        }
        kit.disable()
        mockDevice = nil
        cameraKit = nil
        try await super.tearDown()
    }
}
