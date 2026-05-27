# Ray-Ban Meta glasses smoothing buffer: design, sweep, and outcome

**Date:** 2026-05-27
**Author:** Vincent Ethier
**Context:** Companion to [glasses-stream-jitter-analysis.md](glasses-stream-jitter-analysis.md). That report identified bursty BT Classic delivery as the root cause of glasses-stream stutter; this one walks through the fix I built, how I tested it, and which depth I shipped.

---

## TL;DR

I added a small ring buffer between the in-app HEVC decoder and `BufferCapturer.capture(...)`, drained on a steady 30 fps `CADisplayLink` pump running on a dedicated thread. The buffer absorbs bursts and replays the last delivered frame during stalls so the LiveKit encoder sees evenly-spaced input.

I compared the buffer (`Config.glassesSmoothingDepth = 2`) against the no-buffer baseline (`= 0`) under matched DAT regime — BT Classic cadence varies on minute-scale timescales, so controlling for that was the experimental design problem. **The buffer wins** on every measured axis:

- Viewer freezes >150 ms: 45 → **10** (78% reduction)
- Worst viewer freeze: 1,437 ms → **323 ms** (78% reduction)
- Encoder-side unique-frame drops: 7.4% → **0.0%**
- Remote (wire-side) jitter: 29 ms → **6 ms** (80% reduction)
- Latency added: **\~67 ms at startup** (priming transient that drains within \~165 ms); steady-state per-frame cost through the buffer is \~33 ms, which drops to **\~5 ms net** once the viewer's jitter buffer adapts (see §5.3)

I also ran `depth = 4` as a sanity check (no reason to expect improvement: in this push-rate-limited regime the buffer drains to the same near-empty steady state regardless of priming depth, since DAT pushes at \~24 fps while the pump pulls at 30 fps). It didn't surface any second-order effects — same `p50 = 1`, `p95 = 3` frame occupancy, comparable viewer outcomes, just a longer and heavier startup transient. Depth>4 was not tested.

`Config.glassesSmoothingDepth = 2` ships as the default. `Config.glassesSmoothingDepth = 0` (full bypass; pre-buffer code path) remains as a one-line escape hatch for when WDAT upstream cadence improves and the workaround becomes unnecessary.

---

## 1. Context

The previous report ended where the realistic options begin. The diagnosis there: bursty delivery at `Stream.videoFramePublisher.listen { ... }` (p50 inter-frame gap 33 ms, p95 86 ms, max 633 ms over 3 minutes) cascades into LiveKit encoder drops, RTP jitter on the wire, and visible freezes at the browser viewer. The fix lives upstream of LiveKit at a layer I can't reach (the BT Classic link and DAT's internal scheduling), so the app-side move is to **decouple** the encoder's input cadence from DAT's delivery cadence with a small buffer.

This report covers:

- **§2 Design.** Where the buffer sits and what "depth" means. Swift snippets in [Appendix B](#appendix-b--implementation-snippets).
- **§3 Methodology.** How I controlled for BT Classic's regime variability — which contaminated my first sweep attempt and required re-runs.
- **§4 Results.** Buffer (`d=2`) vs no buffer (`d=0`) under matched DAT regime, with `d=4` as sanity check.
- **§5 Findings.** Why d=4 was a sanity check, where the next bottleneck appears, why steady-state latency is a wash, and a breakdown of the three jobs the buffer does.

---

## 2. Design

### 2.1 Where the buffer sits

```text
DAT listener (bursty, p95 gap 86 ms, max 633 ms)
  │
  ▼
VTDecompressionSession (HEVC → CVPixelBuffer)
  │
  ▼
FrameSmoothingBuffer.push          ← NEW (called from VT decode callback)
  │
  │      ┌──── CADisplayLink @ 30 fps on dedicated Thread ────┐
  │      ▼                                                    │
  └──→ FrameSmoothingBuffer.pull                               │  ← NEW
         │                                                    │
         ▼                                                    │
       BufferCapturer.capture(_:timeStampNs:rotation:) ───────┘
         │
         ▼
       LiveKit encoder (now sees a steady 30 fps input)
```

The buffer is a depth-bounded ring of `CVPixelBuffer` references with two thread-safe operations: **push** from the VideoToolbox decode callback (DAT thread), **pull** from the pump thread. Three behaviors at the boundaries do the actual work:

- **Overrun**: push hits a full buffer (`buffer.count == maxDepth`) → drop oldest, append new. Bounds tail latency when DAT bursts.
- **Underrun**: pull hits an empty buffer → return the last delivered frame. Masks DAT stalls shorter than the buffer can hold.
- **Priming**: the pump idles until the buffer has accumulated `primeDepth` frames, then starts pulling. Keeps the encoder from seeing input gaps at startup.

### 2.2 What "depth" actually means

`Config.glassesSmoothingDepth` is the **priming threshold** (frames queued before the pump begins pulling) and, when push rate ≥ pull rate, the approximate steady-state occupancy. Each slot in the buffer represents `1/30` second of buffered video time, so:

- `depth × 33 ms` = priming latency added to the glass-to-glass path at startup (startup-only; net steady-state cost is \~5 ms — see §5.3).
- `maxDepth = 6` (fixed) = absolute ceiling on tail latency during DAT bursts.

In the DAT regime I measured (push ≈ 24 fps mean, pull = 30 fps steady), the buffer drains at \~6 frames/sec after priming and bottoms out at `p50 = 1` frame regardless of `primeDepth`. Priming itself is necessary — without it the pump immediately pulls on an empty buffer and underruns from frame one — but choosing *how* deep to prime is really choosing how long and how heavy the startup transient is, not steady-state behavior. **`primeDepth = 2`** is the smallest priming that reliably covers the first DAT-side stall after stream start, at the cost of only \~67 ms priming + \~165 ms drain to equilibrium.

If DAT upstream cadence improved to a clean 30 fps (push = pull), the buffer would instead hover near `primeDepth` indefinitely and the depth parameter would meaningfully change stall-absorption capacity. We're not in that regime today.

*Implementation snippets in [Appendix B](#appendix-b--implementation-snippets).*

---

## 3. Methodology

The first sweep I ran was contaminated by BT Classic regime variability. Documenting what went wrong here because the experimental controls turned out to matter as much as the buffer's design.

### 3.1 The regime problem

BT Classic shares the 2.4 GHz band with Wi-Fi, neighboring devices, and any other Bluetooth traffic. DAT's cadence at `videoFramePublisher.listen { ... }` varies on minute-scale timescales without any visible change in the testing setup. In the same 30-minute window today I recorded `dat_callback_fps` means ranging from **23.82 to 29.91 fps** under identical app/SDK config. DAT also has an *undocumented* adaptive promotion behavior — Meta's docs describe demotion (`.high` → `.medium`, etc.) but in one of my runs the SDK silently *promoted* mid-run from 504×896 to the full 720×1280 rung, \~25% more bandwidth and a measurably different downstream picture.

Single-run-per-config can't distinguish "buffer caused X" from "BT regime drifted between runs." I needed matched-regime data.

### 3.2 Matched-regime comparison

I re-ran each config until I got three runs whose DAT cadence numbers were statistically indistinguishable:

| run | DAT mean fps | DAT gap p50 ms | DAT gap p95 ms | DAT gap max ms | resolution |
|---|---:|---:|---:|---:|---|
| d=0 baseline | 23.86 | 23.91 | 107.89 | 500.59 | 504×896 |
| d=2 | 23.86 | 34.64 | 84.51 | 470.50 | 504×896 |
| d=4 | 23.83 | 34.84 | 81.28 | 533.97 | 504×896 |

Close enough that I trust the downstream deltas to belong to the buffer.

### 3.3 Schema additions

The profiler emits one JSON object per second per side; I call each such object a **window**. A 3-minute run produces \~180 windows per side, each summarising one second of stats. I extended the existing per-window glasses schema with six new nullable fields:

- `buffer_pulls_delta` — total `pull()` calls in window.
- `buffer_overruns_delta` — pushes that displaced the oldest queued frame.
- `buffer_underruns_delta` — pulls that hit an empty queue (repeat-last events).
- `buffer_depth_{p50,p95,max}_frames` — depth sampled at every pull.

Plus `smoothing_buffer_depth` in the iOS `run_start` event so the new analyzer (`scripts/compare-profile-runs.js`) labels columns automatically.

---

## 4. Results

All values are per-window medians unless suffixed `(total)` (run sum) or `(worst)` (run maximum).

### 4a. iPhone publisher side

| Stage | Metric | glasses d=0 | glasses d=2 | glasses d=4 |
|---|---|---:|---:|---:|
| **1. DAT delivery** | callback fps | 23.86 | 23.86 | 23.83 |
| | callbacks (total) | 4,492 | 4,315 | 4,368 |
| | inter-frame gap p50 ms | 23.91 | 34.64 | 34.84 |
| | inter-frame gap p95 ms | 107.89 | 84.51 | 81.28 |
| | inter-frame gap max ms (worst) | 500.59 | 470.50 | 533.97 |
| **2. In-app decode** | decoder rebuilds (total) | 0 | 0 | 0 |
| | decode errors (total) | 0 | 27[^2] | 0 |
| | decoded frames (total) | 4,492 | 4,287 | 4,368 |
| **3. Capturer hand-off** | capturer frames (total) | 4,492 | 5,398 | 5,383 |
| | unique frame % (1 − underruns/pulls) | — | **77.0%** | **78.1%** |
| **4. LiveKit encode** | outbound fps | 23 | 25 | 25 |
| | frames encoded (total) | 4,161 | 4,355 | 4,295 |
| | encoder-drop rate[^1] | **7.4%** | **0.0%** | **0.0%** |
| | bitrate (median, Mbps) | 0.76 | 0.79 | 0.78 |
| | resolution | 504×896 | 504×896 | 504×896 |
| | quality_limitation reason | none | none | none |
| **5. Network (RTCP)** | remote jitter ms | **29.42** | **5.89** | **5.62** |
| | round-trip time ms | 57.13 | 57.36 | 57.97 |

[^1]: At d>0, excludes underrun-triggered repeats — frames the encoder rightly declines as bit-identical (zero motion compresses to \~zero bytes, which the encoder still flags as a drop). For d=0 there are no underruns, so this equals the raw `(capturer − encoded) / capturer` figure.

[^2]: Transient HEVC decode errors clustered in one window of the d=2 run; cause not investigated. 27 of 4,315 callbacks (\~0.6%) — well within noise, unrelated to the buffer, and explains the small `callbacks − decoded` shortfall in row 3.

### 4b. Browser viewer side

| Stage | Metric | glasses d=0 | glasses d=2 | glasses d=4 |
|---|---|---:|---:|---:|
| **6. WebRTC ingress** | inbound fps | 24 | 25 | 25 |
| | frames decoded (total) | 4,126 | 4,326 | 4,269 |
| | jitter ms | **30** | **8** | **7** |
| | jitter-buffer per-frame delay ms | **114.33** | **86.00** | **61.37** |
| **7. `<video>` playout** | rendered frames (total) | 3,550 | 4,212 | 4,022 |
| | playout-dropped frames | **373 (9.0%)** | **26 (0.6%)** | **30 (0.7%)** |
| | freeze events (total) | **45** | **10** | 22 |
| | worst freeze ms | **1,437** | **323** | 444 |

### 4c. Smoothing buffer

| Stage | Metric | glasses d=0 | glasses d=2 | glasses d=4 |
|---|---|---:|---:|---:|
| **8. Buffer** | configured depth | 0 | 2 | 4 |
| | pulls (total) | — | 5,398 | 5,383 |
| | overruns (total) | — | 134 | 164 |
| | underruns (total) | — | 1,241 | 1,177 |
| | underrun rate | — | **23.0%** | **21.9%** |
| | depth p50 (frames) | — | **1** | **1** |
| | depth p95 (frames) | — | **3** | **3** |
| | priming latency added (ms) | — | 66.67 | 133.33 |

---

## 5. Findings

### 5.1 d=4 confirms no surprise above d=2

Given §2.2, I didn't expect d=4 to improve anything once the d=2 numbers were in: push-rate-limited regime, same steady-state occupancy, longer startup transient. I ran it anyway as a sanity check for unforeseen second-order effects (encoder behaving differently with a deeper queue, jitter buffer reacting differently, etc.). It didn't surface any.

The §4c "Buffer" rows confirm the steady state is identical: depth `p50 = 1`, `p95 = 3` frames at **both** d=2 and d=4. The viewer numbers track: d=4 doesn't have fewer freezes than d=2 (it has *more*: 22 vs 10) and worst-case freeze is slightly worse (444 ms vs 323 ms) — both noisy at single-run-per-config, but neither shows the kind of gap that would justify d=4's heavier startup transient (\~133 ms priming + \~490 ms drain, vs \~67 ms + \~165 ms at d=2). `primeDepth = 2` stands.

### 5.2 The encoder may become the next bottleneck when DAT delivers cleanly

During one of the contaminated sweep attempts, DAT briefly promoted to its true `.high` rung (720×1280) and held a \~30 fps callback cadence for 115 seconds. Raw encoder drops over that window stayed at \~20% despite `quality_limitation_reason: none`. I don't have clean-enough data from that episode to separate underrun-repeats from genuine unique-frame drops, so the \~20% is suggestive rather than rigorous.

The hypothesis it points at: without explicit `VideoEncoding(maxFps:, maxBitrate:)` in `VideoPublishOptions`, WebRTC infers a target rate from observed behavior and holds it there even when more input is available. In the current DAT regime (push < pull) this never fires because the encoder is supply-constrained anyway. In a "lucky" regime (push = pull at clean 30 fps) it might become the dominant remaining loss source.

Out of scope for this work. Worth picking up if and when WDAT improves and the encoder bottleneck becomes the visible problem.

### 5.3 Steady-state latency cost is a wash

The viewer's WebRTC jitter buffer adapts to upstream jitter: with paced input, per-frame jitter-buffer delay drops 114 ms → 86 ms — about **28 ms saved on every frame** in steady state. The buffer's own steady-state cost is \~33 ms per frame (at `p50 = 1` occupancy × the 33 ms pump slot). Net **steady-state latency tax is \~5 ms per frame** — statistically a wash. The \~67 ms priming budget is a one-time startup transient (drains within \~165 ms), not a per-frame tax.

Wire-side (RTCP) jitter dropped 80% over the same window (29.4 ms → 5.9 ms), bringing glasses jitter to within \~10% of the front-camera baseline (5.48 ms from the previous report). Same upstream cause as the freeze reduction and the viewer-side savings above — paced input, measured at a different point — not a separate win.

### 5.4 The buffer's three jobs, by the numbers

The buffer was designed to do three things. The data shows all three are in play, but not in equal measure:

| Job | Mechanism | Events @ d=2 (3-min run) |
|---|---|---:|
| Mask short stalls | repeat-last on pull-from-empty | 1,241 of 5,398 pulls (**23%**) |
| Absorb bursts | drop-oldest on push-to-full | 134 of 4,315 pushes (**3.1%**) |
| Pace the encoder | steady 30 fps pull timestamps | 5,398 of 5,398 pulls (**100%**) |

Stall masking is doing most of the visible work (78% viewer-freeze reduction; nearly 1 in 4 pulls are repeats). Burst absorption fires on \~3% of pushes; the encoder would otherwise drop those at the pacing stage. Pacing is the every-pull benefit — what shows up at the wire (`remote_jitter` 29.4 → 5.9 ms) and at the viewer's jitter buffer (114 → 86 ms) per §5.3.

---

## 6. Next Steps

The smoothing buffer addresses the symptom; the root cause is still upstream in DAT, where I can't reach. Three follow-ups suggest themselves:

1. **Track [Meta DAT discussion #199](https://github.com/facebook/meta-wearables-dat-ios/discussions/199).** Meta replied on 2026-05-27 (Alex Sink) confirming the cadence reflects Bluetooth Classic transport behavior — not an SDK aggregation stage I could ask them to remove — and that the ring buffer is the right app-side approach. They've shared the findings with their streaming team internally. If an SDK-side smoothing surface eventually ships, `Config.glassesSmoothingDepth = 0` reverts the app to the original code path with a one-character change.

2. **Explicit encoder framerate target.** If DAT upstream cadence improves to the "lucky regime" I observed once (§5.2), the encoder's adaptive pacing may become the new bottleneck — raw drops sat at \~20% in that window, suggestive of an encoder-side cap, though I couldn't separate underrun-repeats from unique-frame drops. Adding `VideoEncoding(maxFps: 30, maxBitrate: …)` to `VideoPublishOptions` is worth trying then.

3. **Smarter repeat-last during long stalls.** The current policy is "return the same `CVPixelBuffer` for every empty pull." For stalls longer than \~200 ms the viewer sees a frozen image — same end-result as d=0, where the viewer's playout layer held the last decoded frame on its own. Either way the wearer's POV is stuck on stale content until DAT resumes. Possible improvement: detect prolonged underruns and proactively request a keyframe from glasses (via DAT's restart-stream API) so recovery is faster on the other side of the stall.

---

## Appendix A — Buffer counter reference

| Field | Source | Definition |
|---|---|---|
| `buffer_pulls_delta` | `SmoothingBufferPump.tick` | Calls to `FrameSmoothingBuffer.pull()` in the window. At depth>0 this tracks the pump's CADisplayLink cadence (\~30/window in steady state). |
| `buffer_overruns_delta` | `FrameSmoothingBuffer.push` | Pushes that displaced the oldest queued frame (DAT bursts arriving faster than the pump can drain). |
| `buffer_underruns_delta` | `FrameSmoothingBuffer.pull` | Pulls that hit an empty queue and returned the last delivered frame. |
| `buffer_depth_p50_frames` | `FrameSmoothingBuffer.pull` | Median observed queue depth at pull time. Reported in frames; ms = `frames × (1000/30)`. |
| `buffer_depth_p95_frames` | same | 95th-percentile queue depth — captures peak burst absorption. |
| `buffer_depth_max_frames` | same | Run-window max queue depth. |
| `smoothing_buffer_depth` (`run_start`) | `VideoQualityProfiler.start` | Snapshot of `Config.glassesSmoothingDepth` at run start. 0 = buffer bypassed; the rest of the buffer-* fields are then `null` for the whole run. |

---

## Appendix B — Implementation snippets

Full source in `ios/WazaProto/WazaProto/GlassesSource.swift`.

### Ring buffer (`FrameSmoothingBuffer`)

Wraps a `[CVPixelBuffer]` with two methods — `push` from the VT decode thread, `pull` from the pump thread, an `NSLock` between them:

```swift
func push(_ frame: CVPixelBuffer) {
    lock.lock(); defer { lock.unlock() }
    if buffer.count >= maxDepth {
        buffer.removeFirst()                              // overrun: drop oldest
    }
    buffer.append(frame)
    if !primed && buffer.count >= primeDepth { primed = true }
    ...
}

func pull() -> CVPixelBuffer? {
    lock.lock(); defer { lock.unlock() }
    guard primed else { return nil }                      // idle during priming
    guard !buffer.isEmpty else { return lastFrame }       // underrun: repeat-last
    let next = buffer.removeFirst()
    lastFrame = next
    return next
}
```

`lastFrame` is retained so the underrun path always has something to return. `CVPixelBuffer` is a CF reference type, so array mutation is the only retain accounting needed.

### Pump (`SmoothingBufferPump`)

Spins up a dedicated `Thread` and runs a 30 fps `CADisplayLink` on its run loop:

```swift
func start() {
    Thread {
        let link = CADisplayLink(target: self, selector: #selector(self.tick))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 30, preferred: 30)
        link.add(to: .current, forMode: .common)
        ...
        CFRunLoopRun()                                    // until CFRunLoopStop() from main
        link.invalidate()
    }.start()
}

@objc private func tick() {
    guard let frame = buffer.pull() else { return }
    let timeStampNs = Int64(ProcessInfo.processInfo.systemUptime * 1_000_000_000)
    capturer.capture(frame, timeStampNs: timeStampNs, rotation: ._0)
}
```

Two choices not visible from the code:

- **Dedicated thread, not main and not DAT/VT.** Main would stall the pump under SwiftUI layout load; DAT/VT is the producer. The dedicated thread's run loop is also independent of the app's `UIScene` lifecycle, which matters for keeping the pump alive while the app is backgrounded.
- **Pull-time `ProcessInfo.systemUptime` as the timestamp**, not the original DAT-side PTS. WebRTC's encoder makes rate decisions from inter-frame PTS deltas, so handing it the source PTS would surface the burstiness the buffer is meant to mask. The pump-time clock is monotonic and evenly spaced — what the encoder needs to see.

### Wiring in `GlassesSource`

The VT decode callback used to call `capturer.capture(...)` directly. Now it pushes to the smoother when one exists, and falls back to the direct-capture path otherwise:

```swift
if let smoother {
    smoother.push(imageBuffer)
} else {
    // Bypass when Config.glassesSmoothingDepth == 0 — pre-buffer code path.
    let timeStampNs = Int64(presentationTimeStamp.seconds * 1_000_000_000)
    capturer.capture(imageBuffer, timeStampNs: timeStampNs, rotation: ._0)
}
```

The `else` branch is the escape hatch: if WDAT improves to delivering cleanly at 30 fps, `Config.glassesSmoothingDepth = 0` toggles back to the original code path without removing any of the buffer machinery.

---

## Appendix C — Caveats specific to the buffer

**Things that make benchmarking the buffer harder than it sounds.**

- **BT cadence is non-stationary.** Single-run-per-config can't distinguish "buffer caused X" from "BT regime drifted between runs." Re-running until paired runs have matched DAT means (within \~1% on `dat_callback_fps`) is the only way I found to get a clean signal.
- **DAT promotes silently between rungs.** The previous report's decision log read Meta's docs as describing only demotion. Empirically the SDK also promotes when link conditions allow, mid-run, with no API surface to observe directly — only via a `decoder_rebuilds_delta` event when the codec parameter set changes. Affects column comparability — a run that auto-promotes mid-way is bimodal and shouldn't be aggregated.
- **`freeze_max_gap_ms` is cumulative-max-since-start within a run.** A single bad gap at t=30 s shows up identically in every subsequent window's reading. Per-run max is the right reduction; per-window value is misleading.
- **Encoder drop rate post-buffer needs the "excluding underruns" denominator.** Raw `(capturer − encoded) / capturer` counts underrun-triggered repeats as drops. Real burst-induced drops are `(drops − underruns) / (pulls − underruns)`. §4a's `encoder-drop rate` column and footnote `[^1]` report the corrected metric; the analyzer (`scripts/compare-profile-runs.js`) emits both. The corrected metric drops to 0% at d=2.
- **Browser tab inactivity invalidates rendering metrics.** One of my d=4 runs had 0 `rendered_frames_delta` across all windows — the viewer tab had backgrounded itself, so `requestVideoFrameCallback` stopped firing. WebRTC ingress stats remained valid; freeze counts and playout-drop rates did not. Worth keeping the viewer tab in foreground throughout a profile run.

---
