import CryptoKit
import XCTest
@testable import WazaProto

/// Pure-Swift tests for the HS256 envelope builder. The HTTP round-trip is
/// covered by an on-device smoke test, not unit tests.
final class PublisherTokenClientTests: XCTestCase {

    private let secret = "test-publisher-secret-do-not-use-in-prod"

    func testEnvelopeHasThreeDotSeparatedSegments() {
        let envelope = PublisherTokenClient.buildEnvelope(secret: secret)
        let segments = envelope.split(separator: ".", omittingEmptySubsequences: false)
        XCTAssertEqual(segments.count, 3)
        for segment in segments {
            XCTAssertFalse(segment.isEmpty)
        }
    }

    func testHeaderClaimsHS256() throws {
        let envelope = PublisherTokenClient.buildEnvelope(secret: secret)
        let segments = envelope.split(separator: ".")
        let headerData = try XCTUnwrap(base64URLDecode(String(segments[0])))
        let header = try JSONSerialization.jsonObject(with: headerData) as? [String: Any]
        XCTAssertEqual(header?["alg"] as? String, "HS256")
        XCTAssertEqual(header?["typ"] as? String, "JWT")
    }

    func testPayloadHasIosPublisherSubAndValidWindow() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let envelope = PublisherTokenClient.buildEnvelope(secret: secret, ttl: 120, now: now)
        let segments = envelope.split(separator: ".")
        let payloadData = try XCTUnwrap(base64URLDecode(String(segments[1])))
        let payload = try JSONSerialization.jsonObject(with: payloadData) as? [String: Any]
        XCTAssertEqual(payload?["sub"] as? String, "ios-publisher")
        XCTAssertEqual(payload?["iat"] as? Int, 1_700_000_000)
        XCTAssertEqual(payload?["exp"] as? Int, 1_700_000_120)
    }

    func testSignatureVerifiesWithSharedSecret() throws {
        let envelope = PublisherTokenClient.buildEnvelope(secret: secret)
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
        let envelope = PublisherTokenClient.buildEnvelope(secret: secret)
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
