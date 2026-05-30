import CryptoKit
import XCTest
@testable import WazaProto

/// Pure-Swift tests for the viewer-invite HS256 envelope. Mirrors
/// `PublisherTokenClientTests` — the publisher path is tested on both ends, so
/// the invite path should be too. The server side is covered by the viewer's
/// `viewer-token.test.js`; this proves the iOS app *produces* a valid invite,
/// closing the asymmetry that let a mint regression silently break the
/// "Copy viewer link" button.
final class InviteTokenTests: XCTestCase {

    private let secret = "test-invite-secret-do-not-use-in-prod"
    private let room = "waza-proto-abc123def456"

    func testEnvelopeHasThreeNonEmptySegments() {
        let envelope = InviteToken.buildEnvelope(secret: secret, room: room)
        let segments = envelope.split(separator: ".", omittingEmptySubsequences: false)
        XCTAssertEqual(segments.count, 3)
        for segment in segments {
            XCTAssertFalse(segment.isEmpty)
        }
    }

    func testHeaderClaimsHS256() throws {
        let envelope = InviteToken.buildEnvelope(secret: secret, room: room)
        let segments = envelope.split(separator: ".")
        let headerData = try XCTUnwrap(base64URLDecode(String(segments[0])))
        let header = try JSONSerialization.jsonObject(with: headerData) as? [String: Any]
        XCTAssertEqual(header?["alg"] as? String, "HS256")
        XCTAssertEqual(header?["typ"] as? String, "JWT")
    }

    func testPayloadWindowMatchesTTL() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let envelope = InviteToken.buildEnvelope(secret: secret, room: room, ttl: 3 * 60 * 60, now: now)
        let segments = envelope.split(separator: ".")
        let payloadData = try XCTUnwrap(base64URLDecode(String(segments[1])))
        let payload = try JSONSerialization.jsonObject(with: payloadData) as? [String: Any]
        let iat = try XCTUnwrap(payload?["iat"] as? Int)
        let exp = try XCTUnwrap(payload?["exp"] as? Int)
        XCTAssertEqual(iat, 1_700_000_000)
        XCTAssertEqual(exp - iat, 3 * 60 * 60, "window must equal the requested ttl")
    }

    func testPayloadCarriesRoomClaim() throws {
        let envelope = InviteToken.buildEnvelope(secret: secret, room: room)
        let segments = envelope.split(separator: ".")
        let payloadData = try XCTUnwrap(base64URLDecode(String(segments[1])))
        let payload = try JSONSerialization.jsonObject(with: payloadData) as? [String: Any]
        XCTAssertEqual(payload?["room"] as? String, room,
                       "viewer-token trusts this signed room claim for the room name")
    }

    func testSignatureVerifiesWithSharedSecret() throws {
        let envelope = InviteToken.buildEnvelope(secret: secret, room: room)
        let segments = envelope.split(separator: ".")
        let signingInput = "\(segments[0]).\(segments[1])"
        let providedSig = try XCTUnwrap(base64URLDecode(String(segments[2])))
        let key = SymmetricKey(data: Data(secret.utf8))
        let expectedSig = HMAC<SHA256>.authenticationCode(
            for: Data(signingInput.utf8),
            using: key
        )
        XCTAssertEqual(providedSig, Data(expectedSig))
    }

    func testSignatureRejectsWrongSecret() throws {
        let envelope = InviteToken.buildEnvelope(secret: secret, room: room)
        let segments = envelope.split(separator: ".")
        let signingInput = "\(segments[0]).\(segments[1])"
        let providedSig = try XCTUnwrap(base64URLDecode(String(segments[2])))
        let wrongKey = SymmetricKey(data: Data("a-different-secret".utf8))
        let wrongSig = HMAC<SHA256>.authenticationCode(
            for: Data(signingInput.utf8),
            using: wrongKey
        )
        XCTAssertNotEqual(providedSig, Data(wrongSig))
    }

    // MARK: - Helpers

    private func base64URLDecode(_ s: String) -> Data? {
        var padded = s.replacingOccurrences(of: "-", with: "+")
                      .replacingOccurrences(of: "_", with: "/")
        let remainder = padded.count % 4
        if remainder > 0 { padded.append(String(repeating: "=", count: 4 - remainder)) }
        return Data(base64Encoded: padded)
    }
}
