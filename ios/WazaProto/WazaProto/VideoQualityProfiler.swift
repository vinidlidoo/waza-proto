import Foundation
import LiveKit

final class VideoQualityProfiler: NSObject, TrackDelegate, @unchecked Sendable {
    static let dataTopic = "waza.profile"
    static let stage = 1

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
        lock.lock()
        self.run = run
        lastWindowStartMs = nil
        lastBytesSent = nil
        lastFramesEncoded = nil
        lastRemotePacketsLost = nil
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

        let metrics: [String: Any] = [
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

    private struct Run {
        let runID: String
        let source: String
        let durationMs: Int
    }
}
