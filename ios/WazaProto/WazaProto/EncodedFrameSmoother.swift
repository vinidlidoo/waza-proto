import Foundation

// Plan 16 stage 2: small ring buffer between the HEVC Annex-B extractor and
// the TCP listener. Acts as a fixed-depth delay line that drains at the
// source PTS rate.
//
// Stage 1 (single-slot) and stage 2's first attempt (drop-newest + IDR
// protection) were both discarded 2026-05-28:
//   - single-slot lost IDRs whenever a P-frame replaced the held head;
//   - drop-newest decayed the release rate: when frames are dropped on the
//     way in, the kept entries' consecutive PTS gaps grow wider, the next
//     deadline is computed further in the future, and the buffer drains
//     at a fraction of source rate (observed 2.8 fps from a 30 fps source).
//
// Drop-OLDEST avoids both: the buffer remains "current," front-to-back PTS
// gaps stay close to source frame intervals, and the schedule paces at
// source rate. IDR detection is unnecessary because HEVCAnnexBExtractor
// prepends VPS/SPS/PPS in front of every frame (its keyframe detector
// defaults true on DAT-sourced samples that lack CMSampleAttachments) —
// every released frame functions as a decoder resync point.
//
// Monotonicity gate: drop any push with `pts <= last_shipped_pts`. Stage 0
// measured 0.012% of DAT callbacks delivering an adjacent-pair swap.
//
// Underrun policy (timer fires, buffer empty): emit nothing. Let the wall
// clock advance. The next push will rearm the timer.
final class EncodedFrameSmoother: @unchecked Sendable {
    struct Entry {
        let data: Data
        let ptsNs: Int64
        let isIDR: Bool
    }

    private let queue: DispatchQueue
    private let maxDepth: Int
    private let emit: (Data) -> Void
    private var buffer: [Entry] = []
    private var lastShippedPtsNs: Int64?
    private var lastReleaseWall: TimeInterval?
    private var timer: DispatchSourceTimer?
    private var pushCount: Int64 = 0
    private var releaseCount: Int64 = 0
    private var droppedNonMonotonic: Int64 = 0
    private var droppedOverrun: Int64 = 0
    private var underruns: Int64 = 0

    init(label: String = "waza.encoded-smoother", maxDepth: Int = 4, emit: @escaping (Data) -> Void) {
        self.queue = DispatchQueue(label: label, qos: .userInteractive)
        self.maxDepth = maxDepth
        self.emit = emit
    }

    func push(_ data: Data, ptsNs: Int64, isIDR: Bool) {
        queue.async { [weak self] in
            self?.pushOnQueue(data, ptsNs: ptsNs, isIDR: isIDR)
        }
    }

    func stop() {
        queue.sync {
            timer?.cancel()
            timer = nil
            buffer.removeAll()
            lastShippedPtsNs = nil
            lastReleaseWall = nil
        }
    }

    private func pushOnQueue(_ data: Data, ptsNs: Int64, isIDR: Bool) {
        pushCount += 1
        if let last = lastShippedPtsNs, ptsNs <= last {
            droppedNonMonotonic += 1
            return
        }
        if buffer.count >= maxDepth {
            // Drop the oldest non-IDR to make room; if all entries are IDRs
            // (degenerate — should not happen with ~1Hz IDR cadence), drop
            // the oldest entry. Never silently drop an incoming IDR — losing
            // a keyframe freezes the decoder until the next one arrives.
            if let idx = buffer.firstIndex(where: { !$0.isIDR }) {
                buffer.remove(at: idx)
            } else {
                buffer.removeFirst()
            }
            droppedOverrun += 1
        }
        buffer.append(Entry(data: data, ptsNs: ptsNs, isIDR: isIDR))
        if pushCount == 1 || pushCount % 60 == 0 {
            print("[smoother] push #\(pushCount) (\(data.count) B, IDR=\(isIDR)) depth=\(buffer.count) released=\(releaseCount) dropNM=\(droppedNonMonotonic) dropOv=\(droppedOverrun) under=\(underruns)")
        }
        if timer == nil {
            scheduleRelease()
        }
    }

    private func scheduleRelease() {
        timer?.cancel()
        timer = nil
        guard let first = buffer.first else { return }

        let deadline: DispatchTime
        if let lastWall = lastReleaseWall, let lastPts = lastShippedPtsNs {
            let deltaNs = first.ptsNs - lastPts
            let targetWall = lastWall + Double(deltaNs) / 1_000_000_000
            let waitSec = max(0, targetWall - ProcessInfo.processInfo.systemUptime)
            deadline = .now() + .milliseconds(Int(waitSec * 1000))
        } else {
            deadline = .now()
        }

        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: deadline)
        t.setEventHandler { [weak self] in
            self?.fireRelease()
        }
        timer = t
        t.resume()
    }

    private func fireRelease() {
        guard !buffer.isEmpty else {
            underruns += 1
            timer?.cancel()
            timer = nil
            return
        }
        let entry = buffer.removeFirst()
        lastShippedPtsNs = entry.ptsNs
        lastReleaseWall = ProcessInfo.processInfo.systemUptime
        timer?.cancel()
        timer = nil
        releaseCount += 1
        if releaseCount == 1 || releaseCount % 60 == 0 {
            print("[smoother] release #\(releaseCount) (\(entry.data.count) B)")
        }
        emit(entry.data)
        if !buffer.isEmpty {
            scheduleRelease()
        }
    }
}
