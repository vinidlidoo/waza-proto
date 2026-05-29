import CryptoKit
import Foundation

/// Mints HS256-signed viewer-invite JWTs, validated server-side by the Vercel
/// `/api/viewer-token` endpoint. Key material is shared with the Vercel env
/// var `INVITE_SIGNING_SECRET` and treated as a UTF-8 string on both sides so
/// the HMAC inputs match without a base64-decode step.
enum InviteToken {
    static func mint(ttl: TimeInterval = 3 * 60 * 60) -> String {
        buildEnvelope(secret: Secrets.inviteSigningSecret, ttl: ttl)
    }

    /// Pure builder. Exposed as `static` with injectable `secret`/`ttl`/`now`
    /// so tests can verify the envelope shape and signature deterministically
    /// without generated `Secrets`. Mirrors `PublisherTokenClient.buildEnvelope`.
    static func buildEnvelope(
        secret: String,
        ttl: TimeInterval = 3 * 60 * 60,
        now: Date = Date()
    ) -> String {
        let iat = Int(now.timeIntervalSince1970)
        let exp = iat + Int(ttl)
        let header = #"{"alg":"HS256","typ":"JWT"}"#
        let payload = #"{"iat":\#(iat),"exp":\#(exp)}"#

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
