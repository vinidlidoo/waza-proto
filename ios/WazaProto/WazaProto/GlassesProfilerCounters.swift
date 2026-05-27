import Foundation

// Stage-2 counters for the glasses pipeline. Touched on the DAT listener,
// VideoToolbox decode callback, and (plan 12) the smoothing-buffer pump
// thread; snapshotted once per second from VideoQualityProfiler's
// TrackDelegate callback. NSLock keeps the hot path lock-cheap and avoids
// actor hops inside per-frame closures.
final class GlassesProfilerCounters: @unchecked Sendable {
    static let shared = GlassesProfilerCounters()

    private let lock = NSLock()
    private var callbacks: UInt64 = 0
    private var decoderRebuilds: UInt64 = 0
    private var decodeErrors: UInt64 = 0
    private var decodedFrames: UInt64 = 0
    private var capturedFrames: UInt64 = 0
    private var bufferPulls: UInt64 = 0
    private var bufferUnderruns: UInt64 = 0
    private var bufferOverruns: UInt64 = 0
    private var lastCallbackUptime: Double?
    private var gapsMs: [Double] = []
    private var depthSamples: [Int] = []

    struct Snapshot {
        let callbacks: UInt64
        let decoderRebuilds: UInt64
        let decodeErrors: UInt64
        let decodedFrames: UInt64
        let capturedFrames: UInt64
        let bufferPulls: UInt64
        let bufferUnderruns: UInt64
        let bufferOverruns: UInt64
        let gapsMs: [Double]
        let depthSamples: [Int]
    }

    func recordCallback() {
        let uptime = ProcessInfo.processInfo.systemUptime
        lock.lock()
        callbacks &+= 1
        if let last = lastCallbackUptime {
            gapsMs.append((uptime - last) * 1000.0)
        }
        lastCallbackUptime = uptime
        lock.unlock()
    }

    func recordDecoderRebuild() { lock.lock(); decoderRebuilds &+= 1; lock.unlock() }
    func recordDecodeError()    { lock.lock(); decodeErrors    &+= 1; lock.unlock() }
    func recordDecodedFrame()   { lock.lock(); decodedFrames   &+= 1; lock.unlock() }
    func recordCapturedFrame()  { lock.lock(); capturedFrames  &+= 1; lock.unlock() }
    func recordBufferOverrun()  { lock.lock(); bufferOverruns  &+= 1; lock.unlock() }
    func recordBufferUnderrun() { lock.lock(); bufferUnderruns &+= 1; lock.unlock() }

    func recordBufferPull(depth: Int) {
        lock.lock()
        bufferPulls &+= 1
        depthSamples.append(depth)
        lock.unlock()
    }

    func snapshot() -> Snapshot {
        lock.lock()
        let snap = Snapshot(
            callbacks: callbacks,
            decoderRebuilds: decoderRebuilds,
            decodeErrors: decodeErrors,
            decodedFrames: decodedFrames,
            capturedFrames: capturedFrames,
            bufferPulls: bufferPulls,
            bufferUnderruns: bufferUnderruns,
            bufferOverruns: bufferOverruns,
            gapsMs: gapsMs,
            depthSamples: depthSamples
        )
        gapsMs.removeAll(keepingCapacity: true)
        depthSamples.removeAll(keepingCapacity: true)
        lock.unlock()
        return snap
    }

    func reset() {
        lock.lock()
        callbacks = 0
        decoderRebuilds = 0
        decodeErrors = 0
        decodedFrames = 0
        capturedFrames = 0
        bufferPulls = 0
        bufferUnderruns = 0
        bufferOverruns = 0
        lastCallbackUptime = nil
        gapsMs.removeAll(keepingCapacity: false)
        depthSamples.removeAll(keepingCapacity: false)
        lock.unlock()
    }
}
