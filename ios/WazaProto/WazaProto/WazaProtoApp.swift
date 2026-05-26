import MWDATCore
import SwiftUI
#if DEBUG
import MWDATMockDevice
#endif

@main
struct WazaProtoApp: App {
    @StateObject private var glasses = GlassesGateway()

    init() {
        // Order matters: per Meta's CameraAccess sample (CameraAccessApp.swift),
        // `Wearables.configure()` must run BEFORE `MockDeviceKit.shared.enable()`.
        // Calling configure() afterwards throws `WearablesError(rawValue: 1)`.
        // Configure unconditionally so the MDK enable below extends the
        // already-configured backend rather than racing it.
        do {
            try Wearables.configure()
        } catch {
            assertionFailure("Wearables.configure() failed: \(error)")
        }

        #if DEBUG
        // UI-testing entry point: spin up Meta's Mock Device Kit + HTTP test
        // server in-process so XCUITest can drive a virtual Ray-Ban Meta from
        // the test target. Gated behind a launch argument so production /
        // dev-on-device runs never load MDK.
        if ProcessInfo.processInfo.arguments.contains("--ui-testing") {
            MockDeviceKit.shared.enable(config: MockDeviceKitConfig(
                initiallyRegistered: true,
                initialPermissionsGranted: true
            ))
            let portFilePath = ProcessInfo.processInfo.environment["MWDAT_TEST_SERVER_PORT_FILE"]
            Task { try? await MockDeviceKit.shared.startTestServer(portFilePath: portFilePath) }
        }
        #endif
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(glasses)
                .onOpenURL { url in
                    Task { await glasses.handleUrl(url) }
                }
        }
    }
}
