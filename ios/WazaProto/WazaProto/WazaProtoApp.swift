import MWDATCore
import SwiftUI
#if DEBUG
import MWDATMockDevice
#endif

@main
struct WazaProtoApp: App {
    @StateObject private var glasses = GlassesGateway()

    init() {
        #if DEBUG
        // UI-testing entry point: spin up Meta's Mock Device Kit + HTTP test
        // server in-process so XCUITest can drive a virtual Ray-Ban Meta from
        // the test target. Gated behind a launch argument so production /
        // dev-on-device runs never load MDK. `MockDeviceKit.shared.enable`
        // configures the Wearables backend itself — calling
        // `Wearables.configure()` afterwards throws `WearablesError(rawValue: 1)`
        // ("already configured") and crashes the app at launch. So skip the
        // normal configure() path entirely under --ui-testing.
        if ProcessInfo.processInfo.arguments.contains("--ui-testing") {
            MockDeviceKit.shared.enable(config: MockDeviceKitConfig(
                initiallyRegistered: true,
                initialPermissionsGranted: true
            ))
            let portFilePath = ProcessInfo.processInfo.environment["MWDAT_TEST_SERVER_PORT_FILE"]
            Task { try? await MockDeviceKit.shared.startTestServer(portFilePath: portFilePath) }
            return
        }
        #endif

        do {
            try Wearables.configure()
        } catch {
            assertionFailure("Wearables.configure() failed: \(error)")
        }
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
