import MWDATCore
import SwiftUI

@main
struct WazaProtoApp: App {
    @StateObject private var glasses = GlassesGateway()

    init() {
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
