import Foundation
import LiveKit

final class VideoQualityProfiler: NSObject, TrackDelegate, @unchecked Sendable {
    static let dataTopic = "waza.profile"
    static let stage = 2

    private static let processStartEpochMs = Int64(
        (Date().timeIntervalSince1970 - ProcessInfo.processInfo.systemUptime) * 1000
    )

    private let lock = NSLock()
    private weak var observedTrack: Track?
    private var run: Run?
    private var lastWindowStartMs: Int64?
    private var lastBytesSent: UInt64?
    private var lastFramesEncoded: UInt?
    private var lastRemotePacketsLost: Int64?
    private var lastGlassesSnapshot: GlassesProfilerCounters.Snapshot?

    func attach(to track: VideoTrack?) {
        lock.lock()
        let previous = observedTrack
        observedTrack = track
        lock.unlock()

        previous?.remove(delegate: self)
        track?.add(delegate: self)
    }

    func start(runID: String, source: String, durationMs: Int) -> Data? {
        let run = Run(runID: runID, source: source, durationMs: durationMs)
        // Drain stale glasses counters / gaps accumulated before this run so
        // the first window's deltas measure only post-start activity.
        let glassesBaseline = source == "glasses" ? GlassesProfilerCounters.shared.snapshot() : nil
        lock.lock()
        self.run = run
        lastWindowStartMs = nil
        lastBytesSent = nil
        lastFramesEncoded = nil
        lastRemotePacketsLost = nil
        lastGlassesSnapshot = glassesBaseline
        lock.unlock()

        emit([
            "schema_version": 1,
            "event": "run_start",
            "run_id": runID,
            "side": "ios",
            "source": source,
            "stage": Self.stage,
            "process_start_epoch_ms": Self.processStartEpochMs,
            "duration_ms": durationMs,
            "smoothing_buffer_depth": Config.glassesSmoothingDepth,
        ])

        return jsonData([
            "type": "profile-run-start",
            "schema_version": 1,
            "run_id": runID,
            "source": source,
            "duration_ms": durationMs,
            "process_start_epoch_ms": Self.processStartEpochMs,
        ])
    }

    func stop(incomplete: Bool) -> Data? {
        lock.lock()
        let ended = run
        run = nil
        lastWindowStartMs = nil
        lastBytesSent = nil
        lastFramesEncoded = nil
        lastRemotePacketsLost = nil
        lastGlassesSnapshot = nil
        lock.unlock()

        guard let ended else { return nil }
        emit([
            "schema_version": 1,
            "event": "run_stop",
            "run_id": ended.runID,
            "side": "ios",
            "source": ended.source,
            "stage": Self.stage,
            "incomplete": incomplete,
        ])

        return jsonData([
            "type": "profile-run-stop",
            "schema_version": 1,
            "run_id": ended.runID,
            "source": ended.source,
            "incomplete": incomplete,
        ])
    }

    func track(
        _ track: Track,
        didUpdateStatistics statistics: TrackStatistics,
        simulcastStatistics: [VideoCodec: TrackStatistics]
    ) {
        lock.lock()
        guard let run else {
            lock.unlock()
            return
        }

        let nowMs = Self.epochMs()
        let windowDurationMs = lastWindowStartMs.map { max(nowMs - $0, 1) } ?? 1000
        lastWindowStartMs = nowMs

        let outbound = statistics.outboundRtpStream.first { $0.kind == "video" }
            ?? statistics.outboundRtpStream.first
        let remoteInbound = statistics.remoteInboundRtpStream.first { $0.kind == "video" }
            ?? statistics.remoteInboundRtpStream.first

        let bytesDelta = delta(current: outbound?.bytesSent, previous: &lastBytesSent)
        let framesEncodedDelta = delta(current: outbound?.framesEncoded, previous: &lastFramesEncoded)
        let remotePacketsLostDelta = delta(current: remoteInbound?.packetsLost, previous: &lastRemotePacketsLost)

        let bitrateBps = bytesDelta.map { Int64(Double($0) * 8_000.0 / Double(windowDurationMs)) }

        var metrics: [String: Any] = [
            "outbound_width": value(outbound?.frameWidth),
            "outbound_height": value(outbound?.frameHeight),
            "outbound_fps": value(outbound?.framesPerSecond),
            "frames_encoded_delta": value(framesEncodedDelta),
            "bitrate_bps": value(bitrateBps),
            "quality_limitation_reason": value(outbound?.qualityLimitationReason?.rawValue),
            "quality_limitation_resolution_changes": value(outbound?.qualityLimitationResolutionChanges),
            "quality_limitation_duration_none_s": value(outbound?.qualityLimitationDurations?.none),
            "quality_limitation_duration_cpu_s": value(outbound?.qualityLimitationDurations?.cpu),
            "quality_limitation_duration_bandwidth_s": value(outbound?.qualityLimitationDurations?.bandwidth),
            "quality_limitation_duration_other_s": value(outbound?.qualityLimitationDurations?.other),
            "remote_packets_lost_delta": value(remotePacketsLostDelta),
            "remote_jitter_ms": value(remoteInbound?.jitter.map { $0 * 1000.0 }),
            "remote_round_trip_time_ms": value(remoteInbound?.roundTripTime.map { $0 * 1000.0 }),
        ]

        if run.source == "glasses" {
            mergeGlassesMetrics(into: &metrics, windowDurationMs: windowDurationMs)
        }

        let event: [String: Any] = [
            "schema_version": 1,
            "event": "profile_window",
            "run_id": run.runID,
            "side": "ios",
            "source": run.source,
            "stage": Self.stage,
            "window_start_epoch_ms": nowMs,
            "window_duration_ms": windowDurationMs,
            "metrics": metrics,
        ]
        lock.unlock()

        emit(event)
    }

    private static func epochMs() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }

    private func emit(_ object: [String: Any]) {
        guard let data = jsonData(object), let line = String(data: data, encoding: .utf8) else {
            return
        }
        print(line)
    }

    private func jsonData(_ object: [String: Any]) -> Data? {
        guard JSONSerialization.isValidJSONObject(object) else { return nil }
        return try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func value(_ value: Any?) -> Any {
        value ?? NSNull()
    }

    private func delta<T: FixedWidthInteger>(current: T?, previous: inout T?) -> T? {
        defer { previous = current }
        guard let current, let previous else { return nil }
        return current >= previous ? current - previous : nil
    }

    // Caller holds `lock`. Snapshots the shared glasses counters, computes
    // per-window deltas against the previous snapshot, and merges in DAT/
    // decoder fields. First window after start() has nil deltas (baseline).
    private func mergeGlassesMetrics(into metrics: inout [String: Any], windowDurationMs: Int64) {
        let snap = GlassesProfilerCounters.shared.snapshot()
        if let prev = lastGlassesSnapshot {
            let callbacksDelta = snap.callbacks &- prev.callbacks
            let datFps = Double(callbacksDelta) * 1000.0 / Double(windowDurationMs)
            metrics["dat_callback_fps"] = datFps
            metrics["dat_callbacks_delta"] = Int64(callbacksDelta)
            metrics["decoder_rebuilds_delta"] = Int64(snap.decoderRebuilds &- prev.decoderRebuilds)
            metrics["decode_errors_delta"] = Int64(snap.decodeErrors &- prev.decodeErrors)
            metrics["decoded_frames_delta"] = Int64(snap.decodedFrames &- prev.decodedFrames)
            metrics["capturer_frames_delta"] = Int64(snap.capturedFrames &- prev.capturedFrames)
            metrics["buffer_pulls_delta"] = Int64(snap.bufferPulls &- prev.bufferPulls)
            metrics["buffer_underruns_delta"] = Int64(snap.bufferUnderruns &- prev.bufferUnderruns)
            metrics["buffer_overruns_delta"] = Int64(snap.bufferOverruns &- prev.bufferOverruns)
        } else {
            metrics["dat_callback_fps"] = NSNull()
            metrics["dat_callbacks_delta"] = NSNull()
            metrics["decoder_rebuilds_delta"] = NSNull()
            metrics["decode_errors_delta"] = NSNull()
            metrics["decoded_frames_delta"] = NSNull()
            metrics["capturer_frames_delta"] = NSNull()
            metrics["buffer_pulls_delta"] = NSNull()
            metrics["buffer_underruns_delta"] = NSNull()
            metrics["buffer_overruns_delta"] = NSNull()
        }
        if snap.gapsMs.isEmpty {
            metrics["dat_interframe_gap_p50_ms"] = NSNull()
            metrics["dat_interframe_gap_p95_ms"] = NSNull()
            metrics["dat_interframe_gap_max_ms"] = NSNull()
        } else {
            let sorted = snap.gapsMs.sorted()
            metrics["dat_interframe_gap_p50_ms"] = Self.percentile(sorted, 0.5)
            metrics["dat_interframe_gap_p95_ms"] = Self.percentile(sorted, 0.95)
            metrics["dat_interframe_gap_max_ms"] = sorted.last!
        }
        if snap.depthSamples.isEmpty {
            metrics["buffer_depth_p50_frames"] = NSNull()
            metrics["buffer_depth_p95_frames"] = NSNull()
            metrics["buffer_depth_max_frames"] = NSNull()
        } else {
            let sorted = snap.depthSamples.sorted()
            metrics["buffer_depth_p50_frames"] = Self.intPercentile(sorted, 0.5)
            metrics["buffer_depth_p95_frames"] = Self.intPercentile(sorted, 0.95)
            metrics["buffer_depth_max_frames"] = sorted.last!
        }
        lastGlassesSnapshot = snap
    }

    private static func percentile(_ sorted: [Double], _ p: Double) -> Double {
        let idx = min(sorted.count - 1, max(0, Int((Double(sorted.count) * p).rounded(.up)) - 1))
        return sorted[idx]
    }

    private static func intPercentile(_ sorted: [Int], _ p: Double) -> Int {
        let idx = min(sorted.count - 1, max(0, Int((Double(sorted.count) * p).rounded(.up)) - 1))
        return sorted[idx]
    }

    private struct Run {
        let runID: String
        let source: String
        let durationMs: Int
    }
}
