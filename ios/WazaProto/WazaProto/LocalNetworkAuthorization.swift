import Foundation
import Network

// Triggers and verifies iOS's Local Network privacy permission before any
// real NWListener is created. Apple's documented mechanism: publish a fake
// Bonjour service AND browse for the same type; the browse only returns
// results once permission is granted. Without this preflight, an NWListener
// created before the user grants permission lives with a denied auth handle
// even if the user grants permission later — inbound connections sit in
// `.preparing` forever (Apple TN3179 + DTS thread 768666).
//
// `_wazaproto-preflight._tcp` is the throwaway service type used here; it
// must also appear in Info.plist's NSBonjourServices so the browse is
// allowed under the privacy regime.
@MainActor
final class LocalNetworkAuthorization {
    private static let serviceType = "_wazaproto-preflight._tcp"

    private var browser: NWBrowser?
    private var listener: NWListener?
    private var continuation: CheckedContinuation<Bool, Never>?

    func requestAuthorization(timeout: TimeInterval = 10) async -> Bool {
        await withCheckedContinuation { continuation in
            self.continuation = continuation

            do {
                let listener = try NWListener(using: .tcp)
                listener.service = NWListener.Service(name: UUID().uuidString, type: Self.serviceType)
                listener.newConnectionHandler = { $0.cancel() }
                listener.start(queue: .main)
                self.listener = listener
            } catch {
                print("[lnp] preflight listener failed: \(error)")
                finish(granted: false)
                return
            }

            let browseParams = NWParameters()
            browseParams.includePeerToPeer = true
            let browser = NWBrowser(for: .bonjour(type: Self.serviceType, domain: nil), using: browseParams)
            browser.stateUpdateHandler = { [weak self] state in
                if case .failed(let error) = state {
                    print("[lnp] browser failed: \(error)")
                    Task { @MainActor [weak self] in self?.finish(granted: false) }
                }
            }
            browser.browseResultsChangedHandler = { [weak self] results, _ in
                if !results.isEmpty {
                    print("[lnp] permission verified (\(results.count) result(s) visible)")
                    Task { @MainActor [weak self] in self?.finish(granted: true) }
                }
            }
            browser.start(queue: .main)
            self.browser = browser

            Task { [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                guard let self else { return }
                if self.continuation != nil {
                    print("[lnp] preflight timed out after \(timeout)s")
                    self.finish(granted: false)
                }
            }
        }
    }

    private func finish(granted: Bool) {
        browser?.cancel()
        browser = nil
        listener?.cancel()
        listener = nil
        if let continuation {
            self.continuation = nil
            continuation.resume(returning: granted)
        }
    }
}
