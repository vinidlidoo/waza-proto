import Foundation

/// Summons or dismisses the AI coach via the Vercel `/api/coach-dispatch`
/// endpoint. Reuses the same short-lived `ios-publisher` envelope as
/// `PublisherTokenClient` — server-side verification gates the LiveKit
/// agent-dispatch / participant-removal calls so the LiveKit API secret never
/// ships in the app. summon → the worker (agent_name=waza-coach, not
/// auto-dispatched) is dispatched into the room; dismiss → the agent
/// participant is removed, ending its billed Gemini session.
struct CoachDispatchClient {
    enum Action: String { case summon, dismiss }

    enum DispatchError: Error {
        case http(Int, String)
    }

    func dispatch(_ action: Action) async throws {
        let auth = PublisherTokenClient.buildEnvelope(secret: Secrets.publisherSigningSecret)
        var req = URLRequest(url: Config.coachDispatchURL())
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(
            withJSONObject: ["auth": auth, "action": action.rawValue]
        )
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw DispatchError.http(status, String(data: data, encoding: .utf8) ?? "")
        }
    }
}
