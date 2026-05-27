import XCTest
@testable import WazaProto

final class RoomConnectionStatusTests: XCTestCase {

    func testEqualityForCasesWithoutAssociatedValues() {
        XCTAssertEqual(RoomConnection.Status.disconnected, .disconnected)
        XCTAssertEqual(RoomConnection.Status.connecting, .connecting)
        XCTAssertEqual(RoomConnection.Status.connected, .connected)
        XCTAssertEqual(RoomConnection.Status.switching, .switching)
        XCTAssertNotEqual(RoomConnection.Status.disconnected, .connecting)
        XCTAssertNotEqual(RoomConnection.Status.connected, .switching)
    }

    func testEqualityRespectsFailedAssociatedValue() {
        XCTAssertEqual(RoomConnection.Status.failed("oops"), .failed("oops"))
        XCTAssertNotEqual(RoomConnection.Status.failed("a"), .failed("b"))
        XCTAssertNotEqual(RoomConnection.Status.failed(""), .disconnected)
    }

    func testLabelsMatchUIContract() {
        XCTAssertEqual(RoomConnection.Status.disconnected.label, "Disconnected")
        XCTAssertEqual(RoomConnection.Status.connecting.label, "Connecting…")
        XCTAssertEqual(RoomConnection.Status.connected.label, "Publishing as ios-publisher")
        XCTAssertEqual(RoomConnection.Status.switching.label, "Switching source…")
        XCTAssertEqual(RoomConnection.Status.failed("nope").label, "Error: nope")
    }
}

/// Tests the pure-helper extracted from `currentWatcherCount`. Real
/// `RemoteParticipant` instances need a live LiveKit `Room`; the helper takes
/// identity strings so we can drive it directly.
final class RoomConnectionWatcherFilterTests: XCTestCase {

    func testEmptyInputReturnsZero() {
        XCTAssertEqual(RoomConnection.watcherCount(identities: []), 0)
    }

    func testCountsOnlyViewerPrefixedIdentities() {
        let identities = [
            "viewer-abc12345",
            "viewer-def67890",
            "ios-publisher",
            "agent-1",
            "viewer-deadbeef",
        ]
        XCTAssertEqual(RoomConnection.watcherCount(identities: identities), 3)
    }

    func testPrefixMatchOnly() {
        // The mint format is `viewer-<8hex>`. A bare "viewer" is not a viewer
        // identity and must not be counted; "viewer-" alone DOES start with the
        // prefix and is counted (we don't validate the suffix here — that's a
        // production-side concern).
        let identities = ["viewer", "viewers", "Viewer-abc12345", "viewer-"]
        XCTAssertEqual(RoomConnection.watcherCount(identities: identities), 1)
    }

    func testEmptyStringsAreNotCounted() {
        XCTAssertEqual(RoomConnection.watcherCount(identities: ["", "", "viewer-1234abcd"]), 1)
    }
}

final class RoomConnectionProfilerTests: XCTestCase {

    func testProfileRunIDUsesUTCSourceAndRunLetter() {
        let date = Date(timeIntervalSince1970: 1_780_000_000)
        XCTAssertEqual(
            RoomConnection.profileRunID(source: "frontCamera", runIndex: 0, date: date),
            "2026-05-28T20-26-40Z-frontCamera-a"
        )
        XCTAssertEqual(
            RoomConnection.profileRunID(source: "glasses", runIndex: 2, date: date),
            "2026-05-28T20-26-40Z-glasses-c"
        )
    }

    func testProfileRunIDClampsLetter() {
        let date = Date(timeIntervalSince1970: 1_780_000_000)
        XCTAssertTrue(RoomConnection.profileRunID(source: "glasses", runIndex: -1, date: date).hasSuffix("-a"))
        XCTAssertTrue(RoomConnection.profileRunID(source: "glasses", runIndex: 99, date: date).hasSuffix("-z"))
    }
}
