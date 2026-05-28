# 16 — Encoded-frame smoother (publisher-side jitter buffer)

Add a PTS-paced smoothing layer between the iPhone's HEVC Annex-B extractor and its TCP listener so [plan 15](15-encoded-frame-ingest.md)'s pass-through path can absorb DAT's bursty delivery without freezing the viewer. The plan-12 smoother does this pre-encoder (pixel-buffer ring with repeat-last-on-underrun + encoder declining duplicate frames); plan 16 is the structural equivalent operating on pre-encoded HEVC access units.

## Goal

In encoded-ingest mode, the viewer's freeze rate and worst-freeze ms approach the plan-12 smoothed path's numbers (currently 12 events / 331 ms in the stressed regime vs 29 / 3,068 ms unsmoothed — see [encoded-ingest-ab.md §4](../features/encoded-ingest-ab.md#4-stressed-regime-ab-2026-05-28-morning-504896)). Latency (`jitter_buffer_per_frame_delay_ms`) doesn't regress meaningfully (≤ +50 ms vs unsmoothed). Image quality stays the no-transcode-loss baseline.

## Why this rung — what changed since plan 15 landed

Plan 15 closed Stage 2 with the working hypothesis that the freeze regression in encoded mode was "next-step work," polish-tier. The stressed-regime A/B on 2026-05-28 morning shifted that:

- **9× worse worst-freeze** (3,068 ms vs 331 ms) and **2.4× more freeze events** (29 vs 12) under a realistic BT regime. The plan-12 smoother's stall-masking job is doing its hardest work exactly when the BT link is worst — the regime users will actually be in.
- **Encoded delivers ~25% more DAT callbacks than re-encode** at the same hardware (30 vs 24 fps under stress). First evidence that the iPhone's decode + re-encode pipeline contends with the DAT listener thread; encoded's lightweight TCP send doesn't. This makes the freeze comparison unfair to re-encode — and means the smoother's win is *real* even with the input handicap.

Without an encoded-side smoother, the encoded path is not shippable as default. Plan 16 is the gate.

## Landscape (2026-05-28)

Research synthesis (logged in chat history, key links below):

- **Nobody has solved this exact problem.** Closest prior art: lk-cli's `h265://` socket reader uses a fixed-cadence pacer ([`server-sdk-go/readersampleprovider.go`](https://github.com/livekit/server-sdk-go/blob/v2.13.1/readersampleprovider.go) → `LocalTrack` at `FrameDuration=33ms`) — wrong primitive for source-PTS-aware smoothing because it blocks on `socket.Read()` and re-paces blindly.
- **GStreamer's `rtpjitterbuffer`** is the canonical receiver-side pattern (queue + deadline-scheduled drain + lost-packet event) — our smoother is its publisher-side mirror. Borrow the API shape, not the implementation.
- **WebRTC's publisher-side pacer** (libwebrtc `PacedSender`) targets a bitrate via leaky-bucket; we need a source-PTS schedule instead.
- **Academic work** (PDStream, Vidaptive, Camel — all 2025–2026) confirms the pattern "decouple encode from transmission via pacing layer" for sub-second interactive media. Vidaptive's "inject dummies on encoder underrun" is the closest analog — but they inject *dummies*, not duplicates. Maps directly to our underrun policy below.

The implementation home: **iPhone Swift**, between `HEVCAnnexBExtractor` and `EncodedFrameTCPServer.send`. Two reasons not to put it elsewhere:

1. **PTS is only known on the iPhone.** Once we serialise Annex-B bytes onto TCP, the source PTS is gone. Putting the smoother in lk-cli (Go) or an ffmpeg side-car forces a fallback to wall-clock-at-arrival timestamping, which is exactly the nodelink-js bug ([apocaliss92/nodelink-js d3ce527](https://github.com/apocaliss92/nodelink-js/commit/d3ce527cbcb052cf000f278fd849b5710619267a)): bursty arrival → uneven wallclock PTS → downstream rate-matching produces drops/duplicates.
2. **Drop policy is cheaper here.** We know which NAL is VPS/SPS/PPS/IDR vs P-frame without re-parsing the bytestream.

## Design

A ring buffer of HEVC access units (whole frames = groups of NALs ending with a non-VCL or framing boundary) drained by a `DispatchSourceTimer` that schedules releases against source PTS.

```
[ DAT videoFramePublisher ]
        │ CMSampleBuffer + PTS
        ▼
[ HEVCAnnexBExtractor ]    ← already exists
        │ Annex-B bytes + PTS + isIDR
        ▼
[ EncodedFrameSmoother ]   ← new in plan 16
        │ release on PTS schedule
        ▼
[ EncodedFrameTCPServer.send ]   ← already exists
        │ bytes
        ▼
[ lk-cli h265:// ]
```

### Buffer

- Holds up to N access units (start with N=4, expose via `Config.glassesSmootherMaxDepth`).
- Each entry: `{ bytes: Data, ptsNs: Int64, isIDR: Bool, isParameterSet: Bool }`.
- Pushed by the DAT listener thread after Annex-B extraction.
- Drained by a single timer thread (DispatchQueue `utility`).

### Schedule

- Lock-step on **source PTS deltas**, not a fixed `1/fps`. The head entry has `ptsNs_head`; release at wall-clock `t_head_wall = t_first_release + (ptsNs_head − ptsNs_first) / 1_000_000`. Track `t_first_release` once at startup.
- This lets the smoother track DAT's natural rate (which may not be exactly 30 fps — we measured 23.95–30 in real captures) without forcing a grid.

### Underrun policy: emit nothing

**This is the load-bearing divergence from plan 12.** The pixel-buffer smoother repeats the last frame on underrun and the LiveKit encoder declines to encode bit-identical repeats — net effect is "no wire change, smooth playout." That doesn't transfer to pass-through HEVC: re-emitting the same access unit with a new RTP timestamp is a decoder hazard. Some decoders treat duplicate frames at moved PTS as glitches. Vidaptive (NINeS '26) and the WebRTC reference both inject *dummy* packets on underrun, never duplicates.

**Policy: on underrun, emit nothing. Let the wall clock advance. Resume on the next real frame.** The viewer's WebRTC jitter buffer is already designed to absorb 1-frame gaps — that's what it's *for*. Trust it.

### Overrun policy: drop newest non-IDR-P

- Buffer at depth ≥ maxDepth: discard the newest pushed entry **only if** it is non-IDR P-frame.
- Never drop VPS / SPS / PPS / IDR. If a parameter-set or IDR push would overflow, drop the oldest non-IDR-P access unit ahead of it instead.
- This biases the buffer toward keyframe availability — losing parameter sets kills the whole GOP at the viewer.

### lk-cli `--fps` pinning

lk-cli's `ReaderSampleProvider` re-paces on top of us at `FrameDuration`. If our smoother emits at 30 fps and lk-cli is set to read at 30, the two pacers align. Mismatch → backpressure or starvation. Pin `--fps 30` in `scripts/run-glasses-relay.sh`.

## Stages

### Stage 0 — Verify DAT PTS ordering and monotonicity ✅ 2026-05-28

Before pinning the schedule to PTS, confirm DAT 0.7.0 actually delivers monotonic PTS in decode order on the Ray-Ban Meta Optics (Gen 2). HEVC permits B-frames where decode order ≠ presentation order; if DAT ever delivers B-frames, scheduling on PTS will fight itself.

- Log `CMSampleBuffer.presentationTimeStamp` for every DAT callback for one 3-min run, in encoded mode. Plot deltas.
- **Acceptance**: PTS strictly monotonic, no negative deltas. If B-frames appear: schedule on DTS or arrival-order-index instead and document the choice.

Quick task: a print-statement-and-log-tail pass. No code change beyond an `#if DEBUG` log line.

**Results** (capture: `profiler/plan16-stage0/2026-05-28T09-22Z.log`, 5m46s, 8449 callbacks):

- **DTS always invalid** (`dts_ns=-1` for every callback) → DAT does not emit decode timestamps; **no B-frames**. PTS is the only ordering signal we have, and that's fine — there's no decode/presentation divergence.
- **PTS sequence holes: 0**. Callback IDs 1..8449 are dense.
- **PTS monotonicity: 8448/8449 deltas positive** — exactly **one negative delta** at cb=6447→6448→6449. DAT delivered three consecutive frames in PTS order N, N+2, N+1 (one adjacent-pair swap in 8449 frames = 0.012%).
- **Cadence**: median delta = 41.67 ms; p95 = 41.67 ms; p99 = 41.67 ms; p99.9 = 50 ms. The underlying PTS grid is 30 fps (33.33 ms slots), but ~20% of slots are skipped — yielding 24.42 effective fps over the run. Only one stall >100 ms, at cb=52→53 (666 ms — session warmup).

**Decision: schedule on PTS, add a monotonicity gate at the writer.**

PTS-paced scheduling is sound: no B-frames means PTS == decode order == the schedule we want. The single observed swap is rare enough not to drive architecture, but it's not zero, so the Stage 1 head-frame pacer must **drop any incoming access unit with `pts ≤ last_shipped_pts`** rather than ship it out of order. With the Stage 2 ring buffer this becomes a non-issue (frames sort by PTS at insertion).

**Implications carried forward**:

- The Stage-2 ring buffer's `maxDepth=4 × 33ms = 133ms` latency upper-bound is based on the 30fps grid, not the observed 24fps effective rate — i.e., we're sized correctly for the steady-state PTS-delta the smoother actually paces against.
- The 20% skip rate means underrun policy (emit nothing) will fire often — the WebRTC jitter buffer must absorb routinely-occurring 1-frame gaps. This is exactly its job; nothing new for it.

### Stage 1 — Minimal head-frame pacer

Single-entry "buffer" — the smoother holds the head frame, releases it on schedule, accepts the next one only after release. Confirms the timing/scheduling code without ring-buffer complexity.

- New `EncodedFrameSmoother.swift`: holds at most one access unit; `push(_:)` blocks until released (or returns "buffer full, dropping"); timer fires every `ptsDelta` ms to call into TCP send.
- Wire into `GlassesSource.swift` encoded path: replace direct `tcpServer.send(bytes)` with `smoother.push(bytes, pts:)`.
- **Acceptance**: 3-min capture with Vincent's typical motion. Viewer is no choppier than current encoded path (worst freeze ≤ unsmoothed + noise). Confirms the schedule code doesn't make things worse before we add the actual smoothing depth.

### Stage 2 — Ring buffer + drop policy

- Promote single-entry buffer to a ring of `Config.glassesSmootherMaxDepth = 4`.
- Implement drop-newest-non-IDR-P overrun policy. Parameter-set / IDR always make it through.
- Emit-nothing underrun policy (no special handling — timer fires but find no frame, no-op).
- Add new `GlassesProfilerCounters` fields: `smootherPushes`, `smootherReleases`, `smootherOverrunsByType`, `smootherUnderruns`. Sync with [plan 11 profiler](../completed/11-video-quality-profiling.md) shape.
- **Acceptance**: matched 3-min A/B encoded-smoothed vs encoded-unsmoothed in stressed regime. Expected: freeze events drop from ~29 toward ~12 (re-encode-smoothed equivalent); worst-freeze drops from ~3 s toward ~0.5 s; jb_per_frame ≤ unsmoothed + 50 ms.

### Stage 3 — `--fps` pinning + relay update

- Update `scripts/run-glasses-relay.sh` to pass `--fps 30` (or whatever Stage 0 measures as DAT's nominal rate).
- Validate that lk-cli's `ReaderSampleProvider` aligns rather than competes.
- **Acceptance**: smoothed run shows stable inbound fps at the viewer (≥28); no socket backpressure events in lk-cli logs.

## A/B against current baseline

Comparison matrix after Stage 3:

| | Re-encode + plan-12 smoother (shipped) | Encoded + plan-16 smoother (this plan) | Target |
|---|---|---|---|
| Freeze events / 3 min | 12 (stressed) | ≤ 15 | ≤ baseline + 25% |
| Worst-freeze ms | 331 (stressed) | ≤ 500 | ≤ baseline + 50% |
| jb_per_frame_ms | 121.6 (stressed) | ≤ 175 | ≤ baseline + 50 ms |
| Image quality | transcode-loss | none | unchanged from unsmoothed encoded |
| iPhone CPU thermal | TBD | TBD | ≤ re-encode |

Image quality is the only column encoded already wins on; this plan exists to neutralise re-encode's advantage on the freeze columns.

## Out of scope

- **ffmpeg side-car** (`ffmpeg -re -f hevc -i tcp://... -c:v copy -f hevc tcp://...`) — rejected because it can't preserve source PTS at the TCP boundary; same root issue as putting the smoother in lk-cli.
- **lk-cli fork** with a custom `RingBufferSampleProvider` — rejected because (a) no source PTS, (b) fork cost.
- **Native LiveKit Swift SDK encoded-video-ingest** (rust-sdks#1048 + Swift port) — still 3–6+ months from being callable from Swift. When/if it lands, smoother logic moves to feed it directly; relay disappears. Plan 16's smoother code is portable to that future world.
- **Multi-track / simulcast** — single-stream HEVC only. Plan 15 already deferred simulcast.

## Risks

- **B-frame ordering** (handled by Stage 0 verification, fallback to DTS-scheduling).
- **Parameter-set drop** corrupting the GOP — defended by drop policy never touching VPS/SPS/PPS/IDR.
- **PTS drift from wall clock** over a long session — if DAT's clock drifts vs iPhone wall clock, schedule slowly slips. Mitigate by periodically re-anchoring `t_first_release` to a recent frame's PTS rather than the session's first. Defer until measured.
- **lk-cli `ReaderSampleProvider` blocks on `Read()`** during emit-nothing windows — if it does, our underrun-policy gap shows up as TCP backpressure rather than viewer jitter-buffer absorption. Stage 3 must verify this; if it bites, the fix may be a tiny write of a "skip" marker or NAL drop to keep lk-cli's reader moving.
- **Latency budget**: at maxDepth=4, the smoother adds up to 4 × 33 ms = 133 ms steady-state. Document in the final A/B report.

## Decisions logged during implementation

**Stage 0 — schedule on PTS, gate non-monotonic frames at writer (2026-05-28).** DAT 0.7.0 ships PTS only (no DTS / no B-frames). One adjacent-pair PTS swap in 8449 callbacks (0.012%) means the Stage 1 head-frame pacer must drop frames with `pts ≤ last_shipped_pts`. Stage 2's ring buffer subsumes this via PTS-ordered insertion. Full capture analysis above in Stage 0 §Results.

## Vincent's learnings

*(filled in as we go)*

## Tech debt opened

*(filled in as we go)*

## Status

Drafted 2026-05-28 morning. Stage 0 verified 2026-05-28 — PTS monotonic (modulo 0.012% swap rate), no B-frames, schedule-on-PTS is sound. Stage 1 next.

## References

- [plan 15 — encoded-frame ingest](15-encoded-frame-ingest.md)
- [encoded-ingest-ab.md §4 — stressed-regime A/B that surfaced the architectural finding](../features/encoded-ingest-ab.md#4-stressed-regime-ab-2026-05-28-morning-504896)
- [plan 12 — pixel-buffer smoother (the conceptual sibling)](../completed/12-glasses-smoothing-buffer.md)
- [plan 11 — profiler (extend with smoother counters in Stage 2)](../completed/11-video-quality-profiling.md)
- Research synthesis (chat transcript 2026-05-28): GStreamer rtpjitterbuffer, WebRTC PacedSender, server-sdk-go ReaderSampleProvider, PDStream/Vidaptive/Camel papers, nodelink-js d3ce527 wall-clock-PTS bug
