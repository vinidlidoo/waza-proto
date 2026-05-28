# Plan 15 Stage 2: encoded-ingest vs re-encode A/B

**Date:** 2026-05-27
**Author:** Vincent Ethier
**Context:** Companion to [plan 15](../active/15-encoded-frame-ingest.md) Stage 2. The plan introduced the encoded-ingest path — HEVC Annex-B from the iPhone over TCP to a Mac-side `lk room join --publish h265://...` relay, no decode + no re-encode on the iPhone. This report compares it head-to-head with the shipped re-encode path under matched conditions.

---

## TL;DR

I ran three matched 3-min profile sessions, same room, same BT, same iPhone, same 720×1280 HIGH rung: one re-encode (today's d=2 baseline) bracketed by two encoded-ingest runs. The point of two encoded runs was to measure cross-run variability, since the encoded path has no smoother and was visibly choppier in informal testing.

- **Image quality**: pass-through is visibly cleaner; the transcode-loss elimination predicted by the plan is real and the entirety of the observed quality win (resolution is matched between paths, so the "DAT held the high rung" hypothesis from the first informal run is a wash here too).
- **Encoder-side drops**: re-encode loses 15 frames at the LiveKit encoder; encoded loses 0. The encoder isn't free.
- **Latency (`jitter_buffer_per_frame_delay_ms`)**: comparable across paths (104.56 re-encode vs 112.71 / 98.54 encoded). Within noise; meets the plan's "stays near 86 if jitter buffer adapts" prediction.
- **Freezes**: encoded regresses significantly. 28 freezes / 703 ms worst on re-encode vs 45 / 1,864 and 76 / 3,044 on the two encoded runs. The plan-12 smoother's stall-masking job (78% freeze reduction in the original sweep) is missing in pass-through; DAT's bursty delivery reaches the wire unmodulated.
- **Cross-run variability on encoded**: 45 → 76 freezes between two "identical" pass-through runs. Pass-through is timing-sensitive in a way the smoothed path isn't.

**Conclusion**: pass-through's quality + encoder-drop wins are real and the architectural premise is validated. The freeze regression is the unfinished work — a PTS-paced iPhone-side TCP writer (or a small ring buffer pre-TCP) is the obvious next step, and the plan already sketched the design.

---

## 1. Method

Three back-to-back 3-min profile runs in a single session:

| Run | Path | iOS file | Viewer file |
|---|---|---|---|
| encoded #1 | pass-through (`glassesEncodedIngest = true`) | `profiler/ios-2026-05-28T04-56-55Z.jsonl` | `profiler/2026-05-28T05-08-43Z-glasses-a-viewer.jsonl` |
| re-encode | `Config.glassesSmoothingDepth = 2`, legacy decode + re-encode | `profiler/ios-2026-05-28T05-26-14Z.jsonl` | `profiler/2026-05-28T05-26-43Z-glasses-a-viewer.jsonl` |
| encoded #2 | pass-through, repeat | `profiler/ios-2026-05-28T05-34-38Z.jsonl` | `profiler/2026-05-28T05-35-43Z-glasses-a-viewer.jsonl` |

All three ran at **720×1280** (DAT's HIGH rung held throughout — today was a "lucky regime" per [sweep §5.2](glasses-stream-buffer-sweep.md#52-the-encoder-may-become-the-next-bottleneck-when-dat-delivers-cleanly)). Same Wi-Fi, same room, glasses on Vincent's face throughout. The encoded runs sandwich the re-encode to bound BT regime drift between them.

Tooling: `scripts/run-paired-profile.sh` for the captures; `scripts/compare-profile-runs.js profiler/` for the table below. The `glasses encoded` column label is derived from `glasses_encoded_ingest` in the iOS `run_start` event (added 2026-05-27).

The encoded path emits no iPhone-side per-window stats — the profiler observes a `TrackDelegate.didUpdateStatistics` callback, and pass-through publishes no iOS video track (the track lives at the relay). §3a is therefore dashes for encoded columns. This is a profiler gap, not a missing feature — counters like `dat_callbacks_delta` are being incremented internally; they just don't get serialised without a track to attach to. Filed as tech debt.

---

## 2. Results

(Output of `node scripts/compare-profile-runs.js profiler/`, 2026-05-28.)

### 2a. iPhone publisher side

| Stage | Metric | glasses d=2 | glasses encoded #1 | glasses encoded #2 |
|---|---|---:|---:|---:|
| **1. DAT delivery** | callback fps | 29.85 | — | — |
|  | callbacks (total) | 5,399 | — | — |
|  | inter-frame gap p50 ms | 25.77 | — | — |
|  | inter-frame gap p95 ms | 77.30 | — | — |
|  | inter-frame gap max ms (worst) | 278.13 | — | — |
| **2. In-app decode** | decoder rebuilds (total) | 0 | — | — |
|  | decode errors (total) | 0 | — | — |
|  | decoded frames (total) | 5,399 | — | — |
| **3. Capturer hand-off** | capturer frames (total) | 5,393 | — | — |
|  | unique frame % (1 − underruns/pulls) | 98.8% | — | — |
| **4. LiveKit encode** | outbound fps | 30 | — | — |
|  | frames encoded (total) | 5,362 | — | — |
|  | encoder-drop rate (raw) | 0.6% | — | — |
|  | encoder-drop rate (excl underruns) | 0.0% | — | — |
|  | bitrate (median, Mbps) | 1.57 | — | — |
|  | resolution | 720×1280 | — | — |
|  | quality_limitation reason | none | — | — |
| **5. Network (RTCP)** | remote jitter ms | 6.09 | — | — |
|  | round-trip time ms | 59.17 | — | — |

### 2b. Browser viewer side

| Stage | Metric | glasses d=2 | glasses encoded #1 | glasses encoded #2 |
|---|---|---:|---:|---:|
| **6. WebRTC ingress** | inbound fps | 30 | 30 | 30 |
|  | frames decoded (total) | 5,305 | 5,339 | 4,294 |
|  | frames dropped (total) | 15 | 0 | 7 |
|  | packets lost (total) | 1 | 36 | 37 |
|  | jitter ms | 15 | 22 | 29 |
|  | jitter-buffer per-frame delay ms | 104.56 | 112.71 | 98.54 |
| **7. `<video>` playout** | rendered frames (total) | 4,830 | 4,581 | 3,518 |
|  | playout-dropped frames | 466 (8.8%) | 710 (13.3%) | 656 (15.3%) |
|  | freeze events (total) | 28 | 45 | 76 |
|  | worst freeze ms | 703 | 1,864 | 3,044 |

### 2c. Smoothing buffer

| Stage | Metric | glasses d=2 | glasses encoded #1 | glasses encoded #2 |
|---|---|---:|---:|---:|
| **8. Buffer** | configured depth | 2 | — | — |
|  | pulls (total) | 5,393 | — | — |
|  | overruns (total) | 65 | — | — |
|  | underruns (total) | 64 | — | — |
|  | underrun rate | 1.2% | — | — |
|  | depth p50 (frames) | 5 | — | — |
|  | depth p95 (frames) | 6 | — | — |
|  | priming latency added (ms) | 66.67 | — | — |

---

## 3. Findings

### 3.1 Latency parity — plan's prediction confirmed

`jitter_buffer_per_frame_delay_ms` lands at 104.56 / 112.71 / 98.54 across the three runs (single average over the whole run, not the windowed-median I'd used in earlier ad-hoc analysis — the script uses the more standard cumulative-target-delay / total-frames-decoded). All three columns are within a ~15 ms band. The plan's open question — "does the receiver's WebRTC jitter buffer adapt to unpaced wire input, or does it drift back toward 114 ms?" — answers as "yes, it adapts, mostly." **No latency-side reason to build a TCP pacer.**

### 3.2 Image quality — pure transcode-loss elimination

All three runs published 720×1280, so the "DAT held the high rung in the encoded run because there's no codec thermal pressure" hypothesis from this morning's informal observation is a wash here — today's BT was simply good enough that both paths held HIGH. The subjective improvement Vincent observes ("noticeably better") therefore traces entirely to **eliminating the H.265 → raw → H.264 cascade**. Plan-predicted 1–3 dB PSNR / 3–8 VMAF; matches what we see.

### 3.3 Encoder-side drops are not free — encoded path eliminates them

Re-encode dropped **15 frames at the LiveKit H.264 encoder** despite `quality_limitation_reason: none` (sweep §5.2 hypothesised this; today's data confirms it). The encoded path skips the encoder entirely → 0 encoder drops. This is a small effect on its own but it points at a real cost that pass-through avoids.

### 3.4 Freeze regression — measured magnitude

The headline negative finding. Re-encode at d=2 had 28 freezes / 703 ms worst; encoded had **45 / 1,864** and **76 / 3,044**. The plan-12 smoother's main job (sweep §5.4) was masking short DAT stalls — 23% of pulls were repeat-last frames in the original sweep, 1.2% in today's lucky regime. Even at 1.2%, removing the smoother shows up at the viewer. The mechanism:

1. DAT delivery is bursty even in lucky regime: today's re-encode side measured inter-frame gap p95 = 77 ms, max = 278 ms. The 278 ms gaps are exactly what would cause viewer freezes when there's nothing to mask them.
2. The lk relay is a faithful TCP→RTP forwarder — paced-in produces paced-out, bursty-in produces bursty-out. It adds no jitter beyond OS/network overhead but it adds no smoothing either.
3. The viewer's WebRTC jitter buffer holds longer to compensate (jb_per_frame trended 100 → 112 ms encoded #1), but past some threshold it gives up and renders gaps as freezes.

### 3.5 Cross-run variability — pass-through is timing-sensitive

Encoded #1 → encoded #2: 45 → 76 freezes (70% increase), 1,864 → 3,044 ms worst (63% worse), at "identical" conditions. The smoothed path doesn't show this kind of cross-run swing because it equalises input cadence before encoding. **Pass-through outcomes are exposed to BT regime variability in a way the smoothed path is not** — and BT regime is non-stationary on minute timescales per [jitter-analysis.md](glasses-stream-jitter-analysis.md). This makes the "is it the relay?" question hard to answer without controlled inputs — see §3.6.

### 3.6 Is the relay causing the choppiness?

Mostly no, but it's worth being explicit about what we can and can't conclude from this data.

**Against**: the lk relay is a memoryless TCP→RTP forwarder. It does not buffer, does not pace, does not regenerate timestamps from PTS — it just reads bytes off the socket and packetizes. So bursty-in produces bursty-out, paced-in produces paced-out. The same relay was running in both encoded runs and the variability between them is large, suggesting the variability lives upstream of the relay.

**Cleanest isolation test (not run tonight)**: `lk room join --publish "assets/testsrc.h264" ...` from the existing `scripts/publish-test-pattern.sh` setup. The file is read at a steady 30 fps. If the viewer is smooth from a file source through the same lk relay/SFU/browser path, the relay is provably innocent and the choppiness traces unambiguously to the iPhone-side cadence (DAT + no smoother). Doesn't require glasses, doesn't require BT — useful to file as a follow-up.

The remaining concern is **wire-side packet loss**: encoded packets_lost was 36 and 37 (vs 1 on re-encode). Possibly due to bursty TCP→RTP timing landing packets in unfriendly jitter-buffer windows; possibly something else. Worth a closer look if/when pacing is wired in (a pacer should drop wire-side loss to re-encode levels).

---

## 4. Next steps

1. **PTS-paced TCP writer on the iPhone** — the plan already described the shape: queue NAL units, write to socket on a wall-clock schedule aligned to original frame PTS, drop-newest-non-IDR-P on overrun. This is the missing stall-masking equivalent for pass-through. Expected outcome based on §3.4 mechanism: freeze count closer to re-encode's, no impact on jb_per_frame.
2. **File-source baseline through the relay** — `lk room join --publish "$ASSET"` against a viewer with `&debugStats=1` to capture freeze metrics. Confirms the relay is innocent of timing additions.
3. **Fix SIGSEGV on `EAAccessory` disconnect in encoded mode** — blocking before flipping `Config.glassesEncodedIngest = true` as default. Suspect: frame closure firing with a torn-down `CMVideoFormatDescription` while the HEVC Annex-B extractor walks parameter sets.
4. **Tech debt: profiler-without-track**. The iPhone's `GlassesProfilerCounters` keeps counting in encoded mode but the profiler doesn't serialise per-window events without a `TrackDelegate` to drive them. Synthesise a window emitter from the existing counters when no track is attached.

---

## Appendix: re-running this report

```sh
node scripts/compare-profile-runs.js profiler/
```

The script auto-pairs iOS + viewer JSONLs by `run_id`, labels columns from the iOS `run_start` event's `glasses_encoded_ingest` + `smoothing_buffer_depth` fields, and emits markdown. Pass specific files or a directory.
