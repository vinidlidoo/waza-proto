# Glasses smoothing buffer (DAT jitter buffer)

**What.** Insert a small ring buffer between `GlassesSource`'s in-app HEVC decode output and `BufferCapturer.capture(...)`, drained by a `CADisplayLink` pump at a steady 30 fps. Today the decoded `CVPixelBuffer` is handed to LiveKit synchronously from the VideoToolbox callback, so the WebRTC encoder sees the same bursty/stalled cadence that the BT Classic link delivers.

```text
DAT listener (bursty, p95 86 ms / max 633 ms)
  → VT decode (already in place)
  → smoothing buffer (NEW: ring, depth ~4 frames)
  → CADisplayLink pump @ 30 fps (NEW: dedicated thread)
  → capturer.capture(... timeStampNs: pullTime ...) (smooth)
  → LiveKit encoder (no longer drops on bursts; no longer starves on stalls)
```

**Why.** [Plan 11](../completed/11-video-quality-profiling.md) Stage 2 profiling proved DAT delivery is the root cause of glasses video stutter: median 23.8 fps with bursts up to 49 fps and stalls up to 633 ms at `videoFramePublisher`. Two observable consequences flow from that single supply-side problem:

- the LiveKit encoder drops **7.1%** of captured frames when burst input briefly exceeds its sustained encode rate (308 of 4310 captured → 4002 encoded on the `.high` + 30 baseline);
- the viewer sees **54 freezes** > 150 ms with a 993 ms worst gap wherever the DAT stream stalls more than the WebRTC jitter buffer can absorb.

A smoothing buffer fixes both with one piece of state: bursts get queued and paced out instead of dropped at the encoder; stalls get masked by replaying the most recent frame from the buffer until DAT resumes.

**Read first:** [glasses-stream-jitter-analysis.md](../features/glasses-stream-jitter-analysis.md) is the executive write-up of the findings that motivate this fix — the per-stage tables in §3 are what the acceptance criteria below compare against.

**Open dependency.** [meta-wearables-dat-ios discussion #199](https://github.com/facebook/meta-wearables-dat-ios/discussions/199) asks Meta whether the burstiness is BT-link inherent or smoothable inside DAT. If they confirm an SDK-side fix is planned, the value of shipping the workaround drops sharply — check the thread before committing to Stage 2. As of 2026-05-27 the thread has 0 replies.

## Scope

- One ring buffer + one display-link pump in `GlassesSource.swift`, on a dedicated worker run loop.
- Counters for buffer depth + underruns/overruns wired through the existing `GlassesProfilerCounters` singleton and surfaced on glasses `profile_window` lines.
- Two paired 3-min profiling runs (`.high` + 30, glasses + front-camera baseline) per ship checkpoint, compared against the latest pre-buffer baseline.
- Depth sweep `{2, 4, 6}` only after Stage 1 acceptance is met.

## Non-goals

- No change to `StreamConfiguration` (`.hvc1`, `.high`, 30 fps stays — proved best in plan 11's (A) config sweep).
- No change to LiveKit publish path: `BufferCapturer` interface is unchanged; only the timing and pixel-buffer source of `capture(...)` calls move.
- No front-camera pump — front camera is the baseline and stays untouched.
- No alternate fix paths (relay, encoded-frame ingest, codec swap). Those live in [`features/`](../features/) and would replace, not complement, the smoothing buffer.

## Implementation ladder

### Stage 1 - Ship the buffer at depth=4, measure

Smallest cut that lets one paired profile decide whether the design works:

1. `FrameSmoothingBuffer` (NSLock-guarded class) inside `GlassesSource.swift`, ~50 LOC.
2. VT decode output callback's last line changes from `capturer.capture(imageBuffer, ...)` → `smoother.push(imageBuffer)`.
3. `CADisplayLink` on a dedicated `Thread` whose run loop is added in `.commonModes`, calling `capturer.capture(buffer, timeStampNs: pullTime, rotation: ._0)` at 30 fps. `preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 30, preferred: 30)`.
4. Three new counter fields on `GlassesProfilerCounters` (see schema below).
5. One paired 3-min `.high` + 30 run vs the latest pre-buffer baseline (`profiler/ios-2026-05-27T01-19-06Z.jsonl` / `profiler/2026-05-27T01-22-42Z-glasses-a-viewer.jsonl`).

Stage 1 answers: did the buffer (a) cut encoder drops below 2%, (b) halve viewer freezes, (c) leave glass-to-glass latency within budget? If yes, proceed to Stage 2 (depth sweep). If no, debug before tuning — likely culprits: pump thread starvation, PTS handling, or under-sized buffer for the observed stall distribution.

### Stage 2 - Depth sweep, pick winner

Only after Stage 1 acceptance passes:

1. Paired 3-min runs at depth `{2, 4, 6}` (~66 ms / ~133 ms / ~200 ms latency floors), same room/Wi-Fi.
2. Compare encoder drop rate, viewer freezes, buffer underrun count, buffer overrun count, and remote RTT across the three depths.
3. Pick the depth that minimizes underruns + freezes without exceeding the v0.05 rung's sub-second glass-to-glass budget.
4. Lock the chosen depth in code; close the plan.

## Design notes

- **Storage**: `[CVPixelBuffer]` guarded by `NSLock`, max depth ~6 frames. Push from VT decode callback; pop from the display-link pump thread.
  - Buffer full (DAT burst): drop the oldest frame, append new. Standard ring-buffer policy; keeps tail latency bounded.
  - Buffer empty (DAT stall): re-publish the last delivered frame. Caps perceived freeze to a single-frame-held image instead of a black drop.
- **Pull cadence**: `CADisplayLink` at 30 fps (see *Pump rate* below for why 30 and not 24). Cheap, naturally paced against downstream WebRTC. Run on a **dedicated `Thread`** with its own `RunLoop` in `.commonModes` — not `.main` (a busy UI would stall the pump) and not the DAT/VT thread (push side).
- **Timestamps**: `BufferCapturer.capture(_:timeStampNs:rotation:)` wants monotonic. Use the **pull-time** (`ProcessInfo.systemUptime * 1e9`), NOT the original DAT frame's PTS. Handing the encoder out-of-paced PTS would defeat the smoothing — the encoder uses PTS deltas for rate decisions.
- **Pixel-buffer ownership**: `CVPixelBuffer` is a `CFTypeRef`; storing in a Swift array retains it. The displaced-on-overrun buffer drops to zero refs on array slot replacement and gets reclaimed by the pixel-buffer pool naturally.
- **Reset semantics**: On `unpublish(...)`, stop the display-link before tearing down the buffer (otherwise pump may fire one last `capture` against an invalid track). Drain the buffer.

**Pump rate (why 30 fps, not 24).** The plan 11 callback-fps mean of 23.83 is misleading: it's dragged down by stalls. The p50 inter-frame gap is 33.63 ms — DAT runs at **30 fps between stalls**, not 24. Over a 3-min run, ~36 s of cumulative stall time pulls the mean to 24. Plan 11's (C) decision log read the docs' "30 → 24 adaptive rung" as a steady-state shift; the data shows DAT is still on the 30 rung with gaps, not on the 24 rung clean.

With the pump at 30 fps and depth=4, the behavior splits cleanly:

- Between stalls (~80% of the run): push 30 / pull 30, buffer floats near depth=4.
- Short stalls (≤ 133 ms, ~p95 territory): buffer drains, pump keeps firing from queued frames, viewer sees no glitch. This is the buffer earning its keep.
- Long stalls (633 ms outliers): buffer exhausts after 133 ms, repeat-last kicks in for the remaining ~500 ms. Viewer sees a 500 ms freeze instead of 633 ms — partial mask.
- Catch-up bursts (49 fps spikes after a stall): buffer fills past depth=4 toward max=6, oldest frames drop on overrun. This is what eliminates the 7.1% encoder drops.

Over the full run, ~20% of pulls land as repeat-last — but they cluster inside stall windows (which are exactly the freezes we want to mask), not spread evenly. Repeat frames cost the encoder almost nothing: zero-motion P-frames compress to near-zero bytes.

The alternative (pump at 24 fps to match the mean) does the trade differently: encoder sees a clean 24 fps with no repeats, but viewer also sees 24 fps, and the per-slot latency rises to 41.7 ms (depth=4 = ~167 ms instead of 133 ms). Stall-absorption at the same depth rises proportionally, so it's the same trade at a lower output framerate. Pump=30 wins on viewer experience; the repeat-frame cost is real-but-tiny.

## JSONL schema additions

Extends plan 11's Stage 2 glasses-window metrics. `schema_version` stays at 1 (additive, nullable fields). `stage` stays at 2 — smoothing buffer is a runtime feature, not a new instrumentation stage.

New fields on glasses `profile_window` events only:

```json
{
  "buffer_depth_p50_frames": 3.0,
  "buffer_depth_p95_frames": 5.0,
  "buffer_depth_max_frames": 6,
  "buffer_underruns_delta": 2,
  "buffer_overruns_delta": 1,
  "buffer_pulls_delta": 30
}
```

- `buffer_depth_*_frames` — depth (item count) sampled at every pull. Reported in frames rather than ms because the pump cadence is fixed; ms is `frames / 30 * 1000` and the analyzer can derive it.
- `buffer_underruns_delta` — pulls that hit an empty buffer (frame-repeat events).
- `buffer_overruns_delta` — pushes that displaced the oldest frame (burst clipping).
- `buffer_pulls_delta` — total pulls in window. Used as denominator for underrun rate.

First window after `start()` reports the depth percentile fields as `NSNull` if no pulls happened in the window (baseline snapshot), same convention as plan 11's other Stage 2 deltas.

## File layout

```code
ios/WazaProto/WazaProto/
  GlassesSource.swift              + FrameSmoothingBuffer class (~50 LOC)
                                   + dedicated pump Thread with CADisplayLink
                                   * VT decode callback's capture() call → smoother.push()
                                   * unpublish() tears down pump before buffer
  GlassesProfilerCounters.swift    + buffer_* counters (underruns, overruns, pulls, depth samples)

scripts/analyze-video-quality.js   + optional: buffer_underruns / buffer_overruns / depth_p95
                                     surfaced in the comparison table (only useful for the
                                     Stage 2 sweep)
```

## Done criteria

1. `FrameSmoothingBuffer` shipped at depth=4; VT decode output flows through it; pump runs on a dedicated thread.
2. Stage 1 paired run produces a glasses JSONL with `buffer_pulls_delta > 0` on every steady-state window and meaningful `buffer_depth_p95_frames` / `buffer_underruns_delta` / `buffer_overruns_delta` deltas.
3. Stage 1 acceptance, on a 3-min `.high` + 30 paired run vs `profiler/ios-2026-05-27T01-19-06Z.jsonl`:
   - **Encoder drop rate < 2%** (baseline 7.1%). Computed as `1 - sum(frames_encoded_delta) / sum(capturer_frames_delta)`.
   - **Viewer freeze events > 150 ms cut by ≥ 50%** (baseline 54 → ≤ 27).
   - **Worst viewer freeze ≤ baseline** (baseline 993 ms).
   - No glass-to-glass latency regression. No direct probe exists; proxy is remote-inbound RTT (`remote_round_trip_time_ms`) median within ±20% of baseline.
4. Stage 2 depth sweep completed (`{2, 4, 6}`), winning depth committed.
5. Pump never blocks the DAT/VT thread (push side is lock-cheap NSLock; no main-thread hops on the hot path).
6. The chosen depth and per-stage findings recorded in `Decisions logged during implementation` below.

## Risks and edge cases

- **Stalls longer than buffer depth.** The 633 ms worst-case DAT stall (depth=4 ≈ 133 ms) will exhaust the buffer; the "repeat last frame" policy takes over and the viewer sees a frozen image for the remainder of the stall instead of judder. Trade: frozen frame > black drop > judder. Confirmed acceptable for the v0.05 rung.
- **CADisplayLink on a dedicated thread.** `CADisplayLink(target:selector:)` registers against the calling run loop. The pump thread must explicitly `RunLoop.current.run()` after adding the link; missing that is a silent no-op (the link object exists but never fires). Cover with an XCTest assertion that `buffer_pulls_delta` is non-zero after one second of frames.
- **Latency floor.** Adds depth × 33 ms (~133 ms at depth=4) to glass-to-glass. Sub-second target keeps this comfortable; depth=6 (~200 ms) is the practical ceiling before the v0.05 rung's latency premise weakens.
- **Resolution swap mid-stream.** DAT's adaptive ladder can change frame dimensions; the decoder rebuilds (already handled in `GlassesSource`). The buffer doesn't care about dimensions — `CVPixelBuffer` opaque pointers, all the same to `BufferCapturer.capture()`. No special handling needed.
- **Backgrounding interaction.** `CADisplayLink` pauses when the app's `UIScene` enters background unless the link is added to a non-foreground run loop. The dedicated thread's run loop is independent of scene lifecycle, but worth verifying in a smoke run on the backgrounded path (plan 07's territory).
- **Profiler counter reset.** `GlassesProfilerCounters.reset()` is called from `publish(...)` before the listener attaches; the new buffer counters need to be included in that reset block (mirror existing fields).

## Run protocol

For Stage 1 + Stage 2, follow plan 11's paired-run convention:

```sh
./scripts/run-paired-profile.sh
```

3-min front-camera run, then 3-min glasses run, same room / Wi-Fi / laptop position. Baseline files for comparison:

- iOS: `profiler/ios-2026-05-27T01-19-06Z.jsonl`
- Front-camera viewer: `profiler/2026-05-27T01-19-27Z-frontCamera-a-viewer.jsonl`
- Glasses viewer: `profiler/2026-05-27T01-22-42Z-glasses-a-viewer.jsonl`

Run the analyzer post-capture and compare encoder drop rate (derived from `frames_encoded_delta` / `capturer_frames_delta`) plus the existing freeze / RTT columns.

## Decisions logged during implementation

_(populate during implementation — buffer-thread choice, depth winner, any deviation from spec)_

## Handoff notes

_(populate after Stage 1 ships — file paths of paired runs, observed deltas vs baseline, debug findings)_

## Status

Promoted from `plans/features/glasses-smoothing-buffer.md` on 2026-05-27 after plan 11 closed. Stage 1 not yet started.
