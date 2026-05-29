import CoreVideo
import XCTest
@testable import WazaProto

/// Pins plan 12's smoothing contract — the thing the 78% viewer-freeze
/// reduction rides on. The buffer never inspects pixel contents, so throwaway
/// `CVPixelBuffer`s suffice and we track identity by object reference (`===`).
/// Single-threaded; the lock is exercised but contention isn't the contract.
final class FrameSmoothingBufferTests: XCTestCase {

    private func makeFrame() -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, 16, 16, kCVPixelFormatType_32BGRA, nil, &pb
        )
        precondition(status == kCVReturnSuccess, "CVPixelBufferCreate failed")
        return pb!
    }

    /// Not-primed: `pull()` returns nil until `primeDepth` pushes have landed,
    /// and a not-primed pull does NOT consume the buffered frames.
    func testPullReturnsNilUntilPrimed() {
        let buffer = FrameSmoothingBuffer(maxDepth: 3, primeDepth: 2)
        let f1 = makeFrame()
        buffer.push(f1)                      // count 1 < primeDepth 2
        XCTAssertNil(buffer.pull(), "pull before priming must return nil")

        let f2 = makeFrame()
        buffer.push(f2)                      // count 2 == primeDepth → primed
        XCTAssertTrue(buffer.pull() === f1, "first primed pull must yield the oldest frame, intact")
    }

    /// Primed: frames come back FIFO.
    func testPrimedPullIsFIFO() {
        let buffer = FrameSmoothingBuffer(maxDepth: 6, primeDepth: 2)
        let f1 = makeFrame(), f2 = makeFrame(), f3 = makeFrame()
        buffer.push(f1); buffer.push(f2); buffer.push(f3)
        XCTAssertTrue(buffer.pull() === f1)
        XCTAssertTrue(buffer.pull() === f2)
        XCTAssertTrue(buffer.pull() === f3)
    }

    /// Underrun (empty after primed): repeat the LAST frame, never nil — this is
    /// what masks short DAT stalls instead of dropping to a black/frozen pump.
    func testUnderrunRepeatsLastFrame() {
        let buffer = FrameSmoothingBuffer(maxDepth: 3, primeDepth: 2)
        let f1 = makeFrame(), f2 = makeFrame()
        buffer.push(f1); buffer.push(f2)
        XCTAssertTrue(buffer.pull() === f1)
        XCTAssertTrue(buffer.pull() === f2)   // buffer now empty, last = f2
        XCTAssertTrue(buffer.pull() === f2, "underrun must repeat the last frame")
        XCTAssertTrue(buffer.pull() === f2, "repeat-last holds across multiple underruns")
    }

    /// Overrun (push past `maxDepth`): drop the OLDEST, keep the newest — bounds
    /// tail latency.
    func testOverrunDropsOldestKeepsNewest() {
        let buffer = FrameSmoothingBuffer(maxDepth: 3, primeDepth: 2)
        let f1 = makeFrame(), f2 = makeFrame(), f3 = makeFrame(), f4 = makeFrame()
        buffer.push(f1); buffer.push(f2); buffer.push(f3)  // at capacity
        buffer.push(f4)                                    // overrun → drop f1
        XCTAssertTrue(buffer.pull() === f2, "oldest (f1) must have been dropped on overrun")
        XCTAssertTrue(buffer.pull() === f3)
        XCTAssertTrue(buffer.pull() === f4, "newest frame must be retained")
    }

    /// `drain()` re-arms priming: after draining, `pull()` returns nil again
    /// until `primeDepth` fresh pushes have landed.
    func testDrainReArmsPriming() {
        let buffer = FrameSmoothingBuffer(maxDepth: 3, primeDepth: 2)
        buffer.push(makeFrame()); buffer.push(makeFrame())  // primed
        buffer.drain()

        let g1 = makeFrame()
        buffer.push(g1)                                     // count 1 < primeDepth
        XCTAssertNil(buffer.pull(), "drain must reset priming")

        let g2 = makeFrame()
        buffer.push(g2)                                     // re-primed
        XCTAssertTrue(buffer.pull() === g1)
    }
}
