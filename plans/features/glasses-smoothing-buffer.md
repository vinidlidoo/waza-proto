# Glasses smoothing buffer (DAT jitter buffer)

**What.** Insert a small ring buffer between `GlassesSource`'s DAT-callback decoded frames and `BufferCapturer.capture(...)`, drained on a fixed-cadence timer (e.g. 30 fps via `CADisplayLink`). Today the decoded `CVPixelBuffer` is handed to LiveKit synchronously from the DAT listener, so the WebRTC encoder sees the same bursty/stalled cadence the BT Classic link delivers.

```text
DAT listener (bursty, 0–49 fps observed)
  → VT decode (already in place)
  → smoothing buffer (NEW: ring, depth ~4 frames)
  → display-link timer @ 30 fps
  → capturer.capture(...) (smooth)
  → LiveKit encoder (no longer drops on bursts)
```

**Why.** Plan 11 stage-2 profiling proved DAT delivery is the root cause of glasses video stutter: median 23.8 fps with bursts up to 49 fps and stalls up to 695 ms. Two observable consequences flow from that single problem:

- the LiveKit encoder drops ~7% of frames when burst input briefly exceeds its sustained encode rate;
- the viewer sees freezes wherever the DAT stream stalls more than ~150 ms (61/178 windows in the 3-min `.high` baseline).

A smoothing buffer fixes both with one piece of state: bursts get queued instead of dropped at the encoder; stalls get masked by replaying the most recent frame from the buffer until DAT resumes.

**Read first:** [glasses-stream-jitter-analysis.md](glasses-stream-jitter-analysis.md) is the executive write-up of the findings that motivate this fix — the per-stage tables in §3 are what the acceptance criteria below compare against.

**Open dependency:** [meta-wearables-dat-ios discussion #199](https://github.com/facebook/meta-wearables-dat-ios/discussions/199) asks Meta whether the burstiness is BT-link inherent or smoothable inside DAT. If they confirm an SDK-side fix is planned, the value of shipping the workaround drops sharply — check the thread before committing. As of writing (2026-05-27), no response yet.

**Why not now / when.** Plan 11's scope was *instrumentation* — answer "where does glasses diverge from front camera". Stage 1 + Stage 2 answered it; the fix is a separate feature so plan 11 can close cleanly. Pick this up next after closing plan 11.

## Design notes

- **Storage**: `[CVPixelBuffer]` guarded by `NSLock`, max depth ~6 frames. Push from DAT/VT thread; pop from the display-link timer thread.
  - Buffer full (DAT burst): drop the oldest frame, append new. This is the standard choice — keeps tail latency bounded.
  - Buffer empty (DAT stall): re-publish the last delivered frame so the encoder never sees an input gap. Caps perceived freeze to a single-frame-held image instead of a black drop.
- **Pull cadence**: `CADisplayLink` at 30 fps. Cheap, naturally paced against downstream WebRTC. Run the timer on a dedicated thread / run loop — *not* `.main` — so a busy UI doesn't stall the pump.
- **Target depth**: start at **4 frames (~133 ms)**. End-to-end latency cost = depth × 1/30 s. The depth is the primary tuning knob — sweep `[2, 4, 6]` post-ship and pick the best stutter/latency tradeoff. At depth=2 (~66 ms) we get less smoothing but lower latency; at depth=6 (~200 ms) we absorb our worst observed 695 ms stalls only partially.
- **Timestamps**: `BufferCapturer.capture(_:timeStampNs:rotation:)` wants monotonic. Use the **pull-time** (`mach_absolute_time` or `ProcessInfo.systemUptime * 1e9`), NOT the original DAT frame's PTS — handing the encoder out-of-paced PTS defeats the smoothing.

## Risks and edge cases

- **Latency floor.** Adds depth × 33 ms to glass-to-glass. At depth=4 that's ~133 ms — acceptable for the v0.05 rung's sub-second target but worth re-measuring on the viewer side.
- **Stalls longer than buffer depth.** The 695 ms worst-case stall exceeds depth=4's 133 ms by ~5×. We'll exhaust the buffer and the "repeat last frame" strategy takes over — viewer sees a frozen image for the rest of the stall instead of judder. Pick: frozen frame > nothing.
- **Display-link queue.** `CADisplayLink` defaults to the main run loop; the pump must run elsewhere (dedicated thread, or `.commonModes` on a worker run loop).

## Instrumentation to add (extends plan 11's Stage 2)

Add to `GlassesProfilerCounters` and surface via `VideoQualityProfiler.mergeGlassesMetrics`:

- `buffer_depth_p50_ms`, `buffer_depth_p95_ms` — depth sampled at every pull
- `buffer_underruns_delta` — pulls that hit an empty buffer (frame-repeat events)
- `buffer_overruns_delta` — pushes that displaced the oldest frame (burst clipping)

These let the next paired run quantify whether the buffer is doing its job before we tune depth.

## Smallest possible first cut

1. Add a `FrameSmoothingBuffer` (NSLock-guarded class or actor) inside `GlassesSource.swift`, ~50 lines.
2. Change the VT decode callback's last line from `capturer.capture(imageBuffer, ...)` → `smoother.push(imageBuffer)`.
3. Add a `CADisplayLink` on a dedicated run loop that calls `capturer.capture(buffer, timeStampNs: pullTime, rotation: ._0)` at 30 fps.
4. Wire the three new counter fields.
5. Paired 3-min run, compare to today's `.high` + 30 baseline (`profiler/ios-2026-05-27T01-19-06Z.jsonl` / `profiler/2026-05-27T01-22-42Z-glasses-a-viewer.jsonl`).

Acceptance: encoder drop rate falls below 2% (from 7.1%), viewer freezes >150ms cut by at least half, no regression to glass-to-glass latency budget.

## Status

Proposed 2026-05-27, after plan 11 Stage 2 + (C) Meta docs verification + (A) `.medium` config-sweep (all in plan 11's decisions log).
