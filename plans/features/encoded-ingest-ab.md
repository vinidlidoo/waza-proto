# Plan 15 Stage 2: encoded-ingest vs re-encode A/B

**Date:** 2026-05-27 (lucky-regime), 2026-05-28 (stressed-regime morning A/B added)
**Author:** Vincent Ethier
**Context:** Companion to [plan 15](../active/15-encoded-frame-ingest.md) Stage 2. The plan introduced the encoded-ingest path — HEVC Annex-B from the iPhone over TCP to a Mac-side `lk room join --publish h265://...` relay, no decode + no re-encode on the iPhone. This report compares it head-to-head with the shipped re-encode path under two BT regimes: the 720×1280 "lucky regime" of 2026-05-27 evening (§1–3 below), and the 504×896 "stressed regime" of 2026-05-28 morning (§4).

---

## TL;DR

I ran three matched 3-min profile sessions, same room, same BT, same iPhone, same 720×1280 HIGH rung: one re-encode (today's d=2 baseline) bracketed by two encoded-ingest runs. The point of two encoded runs was to measure cross-run variability, since the encoded path has no smoother and was visibly choppier in informal testing.

- **Image quality**: pass-through is visibly cleaner; the transcode-loss elimination predicted by the plan is real and the entirety of the observed quality win (resolution is matched between paths, so the "DAT held the high rung" hypothesis from the first informal run is a wash here too).
- **Encoder-side drops**: re-encode loses 15 frames at the LiveKit encoder; encoded loses 0. The encoder isn't free.
- **Latency (`jitter_buffer_per_frame_delay_ms`)**: comparable across paths (104.56 re-encode vs 112.71 / 98.54 encoded). Within noise; meets the plan's "stays near 86 if jitter buffer adapts" prediction.
- **Freezes**: encoded regresses significantly. 28 freezes / 703 ms worst on re-encode vs 45 / 1,864 and 76 / 3,044 on the two encoded runs. The plan-12 smoother's stall-masking job (78% freeze reduction in the original sweep) is missing in pass-through; DAT's bursty delivery reaches the wire unmodulated.
- **Cross-run variability on encoded**: 45 → 76 freezes between two "identical" pass-through runs. Pass-through is timing-sensitive in a way the smoothed path isn't.

**Conclusion**: pass-through's quality + encoder-drop wins are real and the architectural premise is validated. The freeze regression is the unfinished work — a PTS-paced iPhone-side TCP writer (or a small ring buffer pre-TCP) is the obvious next step, and the plan already sketched the design.

**Update 2026-05-28 morning:** A stressed-regime A/B at 504×896 (BT dropped from HIGH) sharpens the conclusion — see [§4](#4-stressed-regime-ab-2026-05-28-morning-504896). Re-encode kept worst-freeze to 331 ms vs encoded's 3,068 ms (9× better) despite the smoother running at depth p50 = 1 and 18.4% underrun rate. Two new non-obvious findings: (a) the encoded path delivers ~25% more DAT callbacks (30 vs 24 fps) — first evidence that iPhone CPU contention from the decode/encode pipeline throttles DAT delivery; (b) the smoother is **architecturally load-bearing** under stress — the encoded path without it is unusable in real-world BT regimes. The PTS-paced TCP writer is now the gate, not polish.

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

The encoded path emits no iPhone-side per-window stats — the profiler observes a `TrackDelegate.didUpdateStatistics` callback, and pass-through publishes no iOS video track (the track lives at the relay). §3a is therefore dashes for encoded columns. This is a profiler gap, not a missing feature — counters like `dat_callbacks_delta` are being incremented internally; they just don't get serialised without a track to attach to. Filed as tech debt. **Update 2026-05-28: fixed.** Future encoded runs will populate §3a DAT delivery + capturer-handoff rows via a synthesised 1-second window timer; this report's encoded columns stay dashed because the underlying captures predate the fix.

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

## 4. Stressed-regime A/B (2026-05-28 morning, 504×896)

The 2026-05-27 evening A/B was run in a benign BT regime — DAT held 720×1280 HIGH the whole time. Vincent re-ran on the morning of 2026-05-28 with the BT regime visibly worse: DAT dropped to MEDIUM (504×896) and stayed there. One encoded run + one re-encode run, both at 504×896, matched in time (5 minutes between captures).

| Run | Path | iOS file | Viewer file |
|---|---|---|---|
| encoded | pass-through (`glassesEncodedIngest = true`) | `profiler/ios-2026-05-28T15-21-30Z.jsonl` | `profiler/2026-05-28T15-22-47Z-glasses-a-viewer.jsonl` |
| re-encode | `Config.glassesSmoothingDepth = 2`, decode + re-encode | `profiler/ios-2026-05-28T15-39-51Z.jsonl` | `profiler/2026-05-28T15-41-08Z-glasses-a-viewer.jsonl` |

A first re-encode capture (`profiler/excluded/`) was discarded because the viewer browser tab was backgrounded during the run — `<video>` painting paused, so rendered-frame and freeze counters reported zero across all windows even though the WebRTC decoder ran fine. The encoded run was unaffected (tab visible during that capture). Moved to `profiler/excluded/` to keep `compare-profile-runs.js` from picking it up on directory scans.

This is also the first A/B with the synthesised-window profiler emitter (added 2026-05-28). §4a shows §3a's DAT delivery and capturer-handoff rows populated for encoded runs — that data was a `—` column in §3 above.

### 4a. iPhone publisher side

| Stage | Metric | glasses d=2 | glasses encoded |
|---|---|---:|---:|
| **1. DAT delivery** | callback fps | 23.95 | 30 |
|  | callbacks (total) | 4,630 | 5,316 |
|  | inter-frame gap p50 ms | 29.67 | 20.07 |
|  | inter-frame gap p95 ms | 86.21 | 89.84 |
|  | inter-frame gap max ms (worst) | 634.83 | 846.15 |
| **2. In-app decode** | decoder rebuilds (total) | 0 | 0 |
|  | decode errors (total) | 0 | 0 |
|  | decoded frames (total) | 4,630 | 0 |
| **3. Capturer hand-off** | capturer frames (total) | 5,384 | 5,316 |
|  | unique frame % (1 − underruns/pulls) | 81.6% | — |
| **4. LiveKit encode** | outbound fps | 25 | — |
|  | frames encoded (total) | 4,461 | — |
|  | encoder-drop rate (raw) | 17.1% | — _(see note)_ |
|  | encoder-drop rate (excl underruns) | 0.0% | — _(see note)_ |
|  | bitrate (median, Mbps) | 0.75 | — |
|  | resolution | 504×896 | (504×896, observed) |
|  | quality_limitation reason | none | — |
| **5. Network (RTCP)** | remote jitter ms | 10.08 | — |
|  | round-trip time ms | 57.13 | — |

Cosmetic bug in `compare-profile-runs.js`: shows "encoder-drop rate (raw) = 100.0%" for encoded runs because `framesEncoded` is null and the script computes `1 - null/capturerFrames = 1`. Should render as `—`. Filed against the script.

### 4b. Browser viewer side

| Stage | Metric | glasses d=2 | glasses encoded |
|---|---|---:|---:|
| **6. WebRTC ingress** | inbound fps | 25 | 28 |
|  | frames decoded (total) | 4,427 | 4,348 |
|  | frames dropped (total) | 0 | 166 |
|  | packets lost (total) | 15 | 16 |
|  | jitter ms | 10 | 26 |
|  | jitter-buffer per-frame delay ms | 121.59 | 127.58 |
| **7. `<video>` playout** | rendered frames (total) | 4,210 | 4,023 |
|  | playout-dropped frames | 90 (2.0%) | 263 (6.0%) |
|  | freeze events (total) | **12** | **29** |
|  | worst freeze ms | **331** | **3,068** |

### 4c. Smoothing buffer (re-encode only)

| Stage | Metric | glasses d=2 |
|---|---|---:|
| **8. Buffer** | configured depth | 2 |
|  | pulls (total) | 5,384 |
|  | overruns (total) | 235 |
|  | underruns (total) | **991** |
|  | underrun rate | **18.4%** _(was 1.2% in §2c)_ |
|  | depth p50 (frames) | **1** _(was 5 in §2c)_ |
|  | depth p95 (frames) | 3 _(was 6 in §2c)_ |
|  | priming latency added (ms) | 66.67 |

### 4d. Findings

#### 4d.1 The encoded path delivers more DAT frames

**Encoded callback fps = 30, re-encode = 24.** Same iPhone, same glasses, same BT, 5 minutes apart. The only thing that changed is what the iPhone does *after* DAT delivers each frame: encoded does HVCC→AnnexB + TCP send (lightweight), re-encode does VTDecompressionSession + LiveKit H.264 encode (CPU-heavy).

This is the first evidence we have that **the iPhone's decode+re-encode pipeline contends with DAT callback delivery**. VideoToolbox + LiveKit's encoder pin a thread that competes with the BT/DAT listener; the encoded path's tiny TCP-send path doesn't. Implications:

- The encoded path may run cooler / use less battery — worth instrumenting thermal state in a future run.
- The freeze comparison is unfair to re-encode by ~6 fps of input — re-encode has fewer frames to work with, so its smoother sees more underruns than it would if DAT delivered the same 30 fps to both paths. **Re-encode's freeze win this morning is the smoother holding the line despite less input.**
- If we ever build a PTS-paced TCP writer (the planned encoded-path fix), we should also revisit whether the re-encode path can be CPU-budgeted to keep DAT delivery healthy — this is independent technical debt against the smoothed path.

#### 4d.2 The plan-12 smoother *is* the freeze-masking story under stress

Re-encode this morning: smoother depth p50 = **1 frame** (vs 5 in last night's lucky regime), underrun rate **18.4%** (vs 1.2%). The buffer is essentially starving. Yet it still kept worst-freeze to **331 ms** vs encoded's **3,068 ms** (9× better) and freeze count to **12 vs 29** (2.4× better).

The mechanism: when the buffer underruns, `BufferCapturer.capture` is called with the last delivered pixel buffer. The LiveKit H.264 encoder declines to encode bit-identical repeats — `framesEncoded` falls below `capturerFrames`, but those non-encodes are correctly classified as "smoother absorbing stalls", not "encoder dropping frames." This shows as the **17.1% raw encoder-drop rate / 0.0% drop rate excluding underruns** split. Sweep §5's mechanism in §3.4 of the lucky-regime report holds.

The headline: **the smoother does its job hardest exactly when the BT regime is bad** — which is exactly when you want it to. Removing it (encoded mode) is brutal under stress.

#### 4d.3 Latency parity holds in the bad regime

JB per-frame delay: 121.6 ms (re-encode) vs 127.6 ms (encoded). Δ = 6 ms. Within the same noise band as last night's 104.6 / 112.7 / 98.5 ms triple.

The "extra Mac-relay hop adds latency we're not measuring" concern from this morning's discussion ([#5 in next steps](#5-next-steps)) doesn't show up in the receiver-perceived latency. This *doesn't* prove the relay is free; it confirms only that whatever the relay adds is below the receiver's jitter-buffer noise floor in the BT-bound regime. Absolute latency instrumentation remains the right way to settle it definitively if we want a hard claim — see [#5 in next steps](#5-next-steps).

#### 4d.4 Subjective ↔ data

Vincent's live observations during the runs:
- **Encoded**: "very choppy" → matches 29 freezes, 3-second worst freeze
- **Re-encode**: "less choppy than encoded, image quality very degraded" → matches 12 freezes / 0.3s worst freeze + transcode loss on a low-bitrate (0.75 Mbps) encode at 504×896

The trade-off is now visible from both directions: encoded keeps the per-frame quality but exposes the wire to DAT burstiness; re-encode masks the stalls but pays double codec loss + a low-bitrate encode budget that can't recover detail.

#### 4d.5 What this means for the encoded-default decision

Last night's lucky-regime data argued for "encoded is a real improvement, file the freeze regression as next-step work." This morning's stressed-regime data argues the freeze regression is **architecturally load-bearing**: without the smoother, the encoded path is unusable in the regimes the system is most likely to actually face (apartment BT, glasses-on-face motion, ambient interference). The PTS-paced TCP writer (next-step #1) isn't a polish item — it's the gate before encoded can ship as default.

---

## 5. Next steps

1. **PTS-paced TCP writer on the iPhone** — the plan already described the shape: queue NAL units, write to socket on a wall-clock schedule aligned to original frame PTS, drop-newest-non-IDR-P on overrun. This is the missing stall-masking equivalent for pass-through. Expected outcome based on §3.4 mechanism: freeze count closer to re-encode's, no impact on jb_per_frame.
2. **File-source baseline through the relay** — `lk room join --publish "$ASSET"` against a viewer with `&debugStats=1` to capture freeze metrics. Confirms the relay is innocent of timing additions.
3. **Fix SIGSEGV on `EAAccessory` disconnect in encoded mode** — blocking before flipping `Config.glassesEncodedIngest = true` as default. Suspect: frame closure firing with a torn-down `CMVideoFormatDescription` while the HEVC Annex-B extractor walks parameter sets.
4. ~~**Tech debt: profiler-without-track**~~. ✅ Fixed 2026-05-28: `VideoQualityProfiler` runs a 1-second `DispatchSourceTimer` when `start()` is called with no attached track, emitting the same `profile_window` shape from `GlassesProfilerCounters` snapshots. Encoded runs starting from the next A/B will populate §3a DAT/capturer rows.
5. **Before closing this feature, decide whether absolute-latency instrumentation is needed.** Our only latency signal is `jitter_buffer_per_frame_delay_ms` (receiver-side target delay). It's invariant to absolute path latency: the encoded path's extra Mac-relay hop can add net glass-to-render time without changing this proxy. The Waza project pitch is sub-second POV, so if we want to defend an absolute number — or compare absolute latency between paths — file as tech debt before this feature lands: wall-clock-stamp frames at iPhone send, side-channel the stamp to the viewer via DataChannel, derive `glass_to_render_ms` per frame. NTP-synced clocks give ~tens of ms accuracy, plenty for our use. Decide at feature close whether to file.
6. **CPU/thermal instrumentation (side quest)** — to confirm or refute §4d.1's hypothesis that iPhone's decode+re-encode pipeline contends with the DAT listener thread (encoded delivers 30 fps DAT vs re-encode's 24 fps under stress, same hardware 5 min apart). Add per-window: `ProcessInfo.thermalState`, `task_info` for CPU percent, `host_processor_info` for system load. If encoded is consistently cooler / lower CPU, this becomes a battery + thermal-headroom argument for encoded that goes beyond freeze/quality. Two lines per metric in the profiler; <1 hour to wire.
7. **File-source baseline through the relay (side quest)** — `lk room join --publish "$ASSET"` against a viewer with `&debugStats=1`. Steady 30 fps file → if viewer is smooth, the relay is provably timing-neutral and the choppiness traces unambiguously to iPhone-side cadence (DAT + no smoother). Doesn't require glasses, doesn't require BT — a useful control to file before declaring the PTS-pacer the right fix. Already mentioned at §3.6 of the lucky-regime report.

---

## Appendix: re-running this report

```sh
node scripts/compare-profile-runs.js profiler/
```

The script auto-pairs iOS + viewer JSONLs by `run_id`, labels columns from the iOS `run_start` event's `glasses_encoded_ingest` + `smoothing_buffer_depth` fields, and emits markdown. Pass specific files or a directory.
