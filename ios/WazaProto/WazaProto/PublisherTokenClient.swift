import CryptoKit
import Foundation

/// Mints publisher JWTs from the Vercel `/api/publisher-token` endpoint.
/// Authenticates each request with a short-lived HS256 envelope signed by
/// the shared `PUBLISHER_SIGNING_SECRET`. Server-side verification gates the
/// LiveKit `AccessToken` mint so the long-lived LiveKit API secret never
/// ships in the app bundle.
struct PublisherTokenClient {
    struct Minted {
        let token: String
        let url: String
    }

    enum MintError: Error {
        case http(Int, String)
        case decode(String)
    }

    func mint() async throws -> Minted {
        let auth = Self.buildEnvelope(secret: Secrets.publisherSigningSecret)
        var req = URLRequest(url: Config.publisherTokenURL(auth: auth))
        req.httpMethod = "POST"
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw MintError.http(status, String(data: data, encoding: .utf8) ?? "")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: String],
              let token = json["token"], let url = json["url"]
        else {
            throw MintError.decode(String(data: data, encoding: .utf8) ?? "")
        }
        return Minted(token: token, url: url)
    }

    /// Pure builder. Exposed as `static` so tests can verify the envelope
    /// shape and signature without a live URLSession.
    static func buildEnvelope(
        secret: String,
        ttl: TimeInterval = 120,
        now: Date = Date()
    ) -> String {
        let iat = Int(now.timeIntervalSince1970)
        let exp = iat + Int(ttl)
        let header = #"{"alg":"HS256","typ":"JWT"}"#
        let payload = #"{"sub":"ios-publisher","iat":\#(iat),"exp":\#(exp)}"#
        let h64 = base64URL(Data(header.utf8))
        let p64 = base64URL(Data(payload.utf8))
        let signingInput = "\(h64).\(p64)"
        let key = SymmetricKey(data: Data(secret.utf8))
        let signature = HMAC<SHA256>.authenticationCode(
            for: Data(signingInput.utf8),
            using: key
        )
        let s64 = base64URL(Data(signature))
        return "\(signingInput).\(s64)"
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
