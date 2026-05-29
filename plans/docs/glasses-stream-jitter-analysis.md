# Ray-Ban Meta glasses video stream: jitter root-cause analysis

**Date:** 2026-05-27
**Author:** Vincent Ethier
**Context:** Building a POV streaming prototype w/ the Ray-Ban Meta glasses

---

## TL;DR

The Ray-Ban Meta Gen 2 glasses POV stream looks visibly choppy compared to the iPhone front-camera stream pushed through the same pipeline. I added end-to-end instrumentation to the iPhone publisher and the browser viewer to pinpoint where the two streams diverge.

The root cause appears to be a **bursty frame delivery from the glasses to the iPhone over the Bluetooth Classic link** — not bandwidth saturation, not in-app decode, not network loss, not browser playback. Median inter-frame gap from the DAT SDK is a healthy 33 ms, but the p95 is 86 ms and worst-case bursts hit 633 ms. Every downstream symptom (LiveKit encoder dropping 7% of input frames, viewer needing ~103 ms of jitter buffer vs ~23 ms for the smooth baseline, 54 perceptible freezes over a 3-minute session) follows from that single upstream cadence problem.

Lowering the requested resolution from `.high` to `.medium` did not improve delivery cadence and made encoder drops *worse* (7.1% → 18.5%), confirming the bottleneck is link-layer scheduling rather than throughput.

The proposed fix is a small ring buffer between the in-app HEVC decoder and the LiveKit capturer, drained on a steady display-link timer, so the LiveKit encoder sees a paced input instead of bursts and stalls (spec'd separately).

---

## 1. Problem

This prototype publishes a sub-second POV video stream from Ray-Ban Meta glasses to a browser viewer. The pipeline has a **glasses-specific upstream segment** that feeds into a **shared downstream segment** also used by the iPhone front-camera baseline:

```text
            glasses                       iPhone front camera
               │                                    │
        BT Classic stream                           │
               │                                    │
        DAT listener         ─┐                     │
               │              │                     │
        HEVC decode           ├── Stage 2           │
               │              │    (glasses         │
        BufferCapturer       ─┘    only)            │
               │                                    │
               └─────────────────┬──────────────────┘
                                 │
                                 ▼
                          LiveKit encode      ─┐
                                 │             │
                                 ▼             │
                                SFU            ├── Stage 1
                                 │             │    (shared by
                                 ▼             │     both sources)
                          browser decode       │
                                 │             │
                                 ▼             │
                              <video>         ─┘
```

The front-camera stream is smooth; the glasses stream visibly stutters, with periodic freezes lasting from 100 ms up to multiple seconds. End-to-end latency is in budget, but the choppiness is the dominant complaint when anyone watches the live stream.

Because the two streams share every downstream stage, the diagnostic question is:

> **Where in the pipeline does the glasses stream first diverge from the front-camera baseline, and why?**

## 2. Profiling Methodology

The instrumentation was built **in two stages, deliberately ordered**: first the shared-segment probes (Stage 1), then — only because Stage 1 was inconclusive about *which side* of the LiveKit encoder the divergence originated on — the glasses-only upstream probes (Stage 2). The diagram above shows which boundaries each stage covers.

**Stage 1 — shared-segment boundaries.** Probes at every measurable point that exists for both sources, so the front-camera baseline can be compared like-for-like with the glasses stream. iPhone-side via the LiveKit Swift SDK's `TrackStatistics` (1-Hz updates of `OutboundRtpStreamStatistics` and `RemoteInboundRtpStreamStatistics`). Browser-side via `RTCRtpReceiver.getStats()` for ingress, `HTMLVideoElement.getVideoPlaybackQuality()` for decoded-vs-rendered counts, and `requestVideoFrameCallback()` for per-paint timing (the only way to observe browser freezes >150 ms).

Stage 1 showed that the glasses stream already arrives at the LiveKit encoder with a lower cadence than front camera, but couldn't distinguish "the encoder is the problem" from "something upstream of the encoder is delivering frames bursty." That ambiguity is what motivated Stage 2.

**Stage 2 — glasses-only upstream probes.** Counters added around the DAT frame callback and the VTDecompressionSession callback: inter-frame gaps (p50/p95/max per 1-second window), decoded frame count, decoder rebuild count, decode-error count, frames handed to `BufferCapturer`. These have no front-camera counterpart — the front camera doesn't go through DAT or in-app decode — so Stage 2 metrics are reported only for the glasses runs.

Two cross-cutting design constraints applied to both stages:

- **Same JSONL schema on both sides** (iPhone and browser), correlated by a shared `run_id` minted on the publisher and announced to the viewer over a LiveKit data channel.
- **Hot-path safety.** All counters are written from frame-delivery and decode callbacks, but only ever increment lock-guarded atomics; metric aggregation and JSONL emission happen on a 1-Hz timer, never per-frame.

I took **paired 3-minute runs** in the same room, on the same Wi-Fi, with the same viewer, switching only the source (`frontCamera` ↔ `glasses`) and then sweeping one config knob (DAT `.resolution = .medium` instead of `.high`).

### Setup

| Component | Version / Identifier |
|---|---|
| Publisher hardware | iPhone 17 |
| Glasses hardware | Ray-Ban Meta Gen 2 |
| Glasses SDK | Meta WDAT iOS 0.7 (`MWDATCore.framework`) |
| Glasses config | `videoCodec: .hvc1`, `frameRate: 30` |
| Publisher SDK | LiveKit Swift 2.14.1 |
| SFU | LiveKit Cloud |
| Viewer | Static HTML + LiveKit JS SDK |
| Run duration | 3 minutes each |

The numbers in §3 come from one paired HIGH run (front camera + glasses, same room and Wi-Fi back-to-back) plus a single MEDIUM glasses sweep done the same way.

## 3. Results

All values are per-window medians unless suffixed `(total)` (3-minute sum) or `(worst)` (run maximum). Empty cells (`—`) mean the metric does not apply to that source.

### 3a. iPhone publisher side

| Stage | Metric | front camera | glasses HIGH | glasses MED |
|---|---|---:|---:|---:|
| **1. DAT delivery** | callback fps | — | **23.83** | **23.88** |
| | callbacks (total) | — | 4,311 | 4,375 |
| | inter-frame gap p50 ms | — | 33.63 | 35.19 |
| | inter-frame gap p95 ms | — | **86.20** | **85.50** |
| | inter-frame gap max ms (worst) | — | **633.59** | **695.03** |
| **2. In-app decode** | decoder rebuilds (total) | — | 0 | 0 |
| | decode errors (total) | — | 0 | 0 |
| | decoded frames (total) | — | 4,310 | 4,374 |
| **3. Capturer hand-off** | capturer frames (total) | — | 4,310 | 4,374 |
| **4. LiveKit encode** | outbound fps | 30 | **23** | **20** |
| | frames encoded (total) | 5,277 | 4,002 | 3,566 |
| | encoder-drop rate | **0%** | **7.1%** | **18.5%** |
| | bitrate (median, Mbps) | 1.70 | 0.78 | 0.44 |
| | resolution | 720×1280 | 504×896 | 360×640 |
| | quality\_limitation reason | none | none | none |
| **5. Network (RTCP)** | remote jitter ms | 5.48 | **22.64** | **23.38** |
| | round-trip time ms | 58.25 | 58.70 | 58.07 |

### 3b. Browser viewer side

| Stage | Metric | front camera | glasses HIGH | glasses MED |
|---|---|---:|---:|---:|
| **6. WebRTC ingress** | inbound fps | 30 | **24** | **20** |
| | frames decoded (total) | 5,255 | 3,965 | 3,507 |
| | frames dropped (total) | 0 | 0 | 0 |
| | packets lost (total) | 0 | 0 | 0 |
| | jitter ms | 7 | **21** | **23** |
| | jitter-buffer per-frame delay ms | 23.4 | **102.7** | **119.9** |
| **7. `<video>` playout** | rendered frames (total) | 5,131 | 3,377 | 3,236 |
| | playout-dropped frames | 94 (1.8%) | **234 (5.9%)** | **112 (3.2%)** |
| | freeze events (total) | 2 | **54** | **25** |
| | worst freeze ms | 5,898¹ | **993** | **5,145** |

¹ One-off browser/OS suspend during the front-camera baseline run; unrelated to the publisher path.

## 4. Findings

### 4.1 DAT delivery is the upstream root cause

The p50 inter-frame gap of 33 ms matches a clean 30-fps cadence — when DAT is delivering, it's delivering on time. But the p95 of 86 ms means 5% of consecutive callbacks are spaced >2.5× the nominal frame interval, and the worst observed single gap was 633 ms. That tail is what produces the observable judder. The mean rate of 23.8 fps is the smoothed consequence of those stalls, not the rate the glasses are encoding at.

Mechanically, every downstream divergence in the table follows from this one cadence problem:

- **In-app decode is healthy.** 0 decoder rebuilds, 0 decode errors, full 1:1 parity between callbacks → decoded → capturer (4,311 / 4,310 / 4,310). The decode stage is not a source of loss.
- **The LiveKit encoder drops 7.1% of captured input frames** because the input arrives in bursts that exceed its instantaneous encode budget. The encoder is not CPU- or bandwidth-limited in the sustained sense (`quality_limitation_reason: none` throughout); it's making per-burst pacing decisions to avoid bitrate overshoot.
- **The SFU sees 4× more RTCP jitter** for glasses (22.6 ms) than front camera (5.5 ms) — the burstiness propagates from the DAT callback through the encoder onto the wire.
- **The browser viewer is forced to add ~103 ms of jitter buffer** to keep playback smooth, vs ~23 ms for the front-camera baseline. The ~80 ms of *extra* buffering is a real, measured latency cost paid downstream specifically because the input was bursty.
- **The `<video>` element drops ~6% of decoded frames at composition time** because clumps of frames arrive after their natural display deadline.
- **54 freezes >150 ms** are observed at the viewer for glasses HIGH, vs 2 for front camera (one of which was an unrelated browser suspend).

Network loss, decode failure, and bandwidth saturation are all explicitly ruled out by the table: 0 lost packets at the viewer, 0 decode errors on iOS, `quality_limitation_reason: none` at the encoder.

### 4.2 Lowering bitrate did *not* improve delivery cadence

I swept the DAT `resolution` knob from `.high` to `.medium` to test the hypothesis that BT bandwidth saturation was driving the bursts. Meta's DAT integration guide describes an adaptive ladder where bandwidth constraints first drop resolution one step, then drop framerate, never below 15 fps. If bandwidth were saturating, asking for less should produce smoother delivery.

It did not.

```text
                                   HIGH               MEDIUM
DAT inter-frame gap p50            33.6 ms            35.2 ms     (no change)
DAT inter-frame gap p95            86.2 ms            85.5 ms     (no change)
DAT inter-frame gap max           633.6 ms           695.0 ms     (slightly worse)
DAT mean rate                      23.8 fps           23.9 fps    (no change)
Bitrate                            0.78 Mbps          0.44 Mbps   (-44%)
LiveKit encoder drop rate           7.1%              18.5%       (much worse)
```

Two takeaways:

1. **BT cadence is independent of bitrate.** The delivery jitter I'm seeing is not driven by hitting a throughput ceiling. It's more consistent with link-layer scheduling jitter: Bluetooth Classic uses 625 μs slots with master-decided polling intervals; the iPhone's 2.4 GHz radio shares time between BT and Wi-Fi; the DAT pipeline itself may buffer internally. Any of those produces bursts/stalls at the MAC layer regardless of how much data is flowing.
2. **Smaller frames make encoder drops worse, not better.** The LiveKit encoder's drop decision is gated by *bitrate budget per second*, not CPU. A smaller target bitrate shrinks the per-burst headroom faster than smaller frames shrink the per-burst cost. So `.medium` reduced the budget and increased the drop rate.

## Next Steps

The divergence enters the system upstream of LiveKit, and the layers where it actually originates — the BT Classic link and DAT's internal scheduling — are not reachable from inside the iPhone app. The true fix lives on Meta's side of the API; what I can do from the app is decouple the LiveKit encoder's input cadence from DAT's delivery cadence. The natural place is between the in-app HEVC decoder and `BufferCapturer.capture(...)`: a small ring buffer that absorbs bursts and replays the last good frame on stalls, drained on a steady display-link timer. Spec'd in [plan 12 — glasses smoothing buffer](../completed/12-glasses-smoothing-buffer.md); depth-4 default, sweeping `{2, 4, 6}` after the first cut to find the latency/smoothness sweet spot.

The latency cost is the buffer depth divided by 30 fps. A depth-of-4 buffer adds ~133 ms; I'd expect to recover ~80 ms of that from the viewer's reduced jitter-buffer target (from 102.7 ms back toward the \~23 ms front-camera baseline), for a net \~53 ms added latency on the glass-to-glass path. Comfortably within the sub-second budget. Alongside the buffer, the in-app decode-error counter should be split by class, specifically tagging `kVTVideoDecoderReferenceMissingErr` separately, so post-stall recovery can be measured properly once the buffer is in place.

**Open question to Meta DAT team:** at 30 fps `.hvc1`, I observe p95 inter-frame gap of 86 ms and worst-case 633 ms at the `videoFramePublisher` callback, with no improvement when dropping from `.high` to `.medium` (i.e. bandwidth saturation is ruled out). Is this cadence inherent to the BT Classic link/profile WDAT uses, or is there an internal aggregation/pacing stage between the radio and `videoFramePublisher` that could be smoothed?¹

¹ Closest prior public acknowledgements: [meta-wearables-dat-ios discussions/134](https://github.com/facebook/meta-wearables-dat-ios/discussions/134) (Meta on unspecified "technical constraints from getting frames from the video stream over Bluetooth") and [meta-wearables-dat-android discussions/44](https://github.com/facebook/meta-wearables-dat-android/discussions/44) (SDK-side throttling that fires independently of actual link bandwidth). Neither characterizes inter-frame cadence at this granularity.

---

## Appendix A — End-to-end pipeline

```text
                  FRONT CAMERA                              GLASSES
                  ────────────                              ───────
                                                      Meta camera sensor
                                                              │
                                                      DAT encode (HEVC)
                                                              │
                                                      BT Classic stream
                                                              │
                                                   ┌──────────▼──────────┐
                                                   │ DAT listener on     │ ← dat_callback_fps
                                                   │ iPhone              │   dat_interframe_gap_*
                                                   │ (videoFramePublisher)│  dat_callbacks_delta
                                                   └──────────┬──────────┘
                                                              │
                                                   ┌──────────▼──────────┐
                                                   │ VTDecompression-    │ ← decoder_rebuilds_delta
                                                   │ Session (HEVC →     │   decode_errors_delta
                                                   │ CVPixelBuffer)      │   decoded_frames_delta
                                                   └──────────┬──────────┘
                                                              │
            AVCaptureDevice                          BufferCapturer.capture(_:) ← capturer_frames_delta
                  │                                           │
                  ▼                                           ▼
            ┌─────────────────────────────────────────────────────┐
            │ LiveKit Swift SDK — encode (H.264) + RTP packetize  │ ← outbound_fps, frames_encoded
            │                                                     │   bitrate_bps, outbound_w/h
            │                                                     │   quality_limitation_reason
            └──────────────────────────┬──────────────────────────┘
                                       │                          ← remote_jitter_ms (RTCP from SFU)
                                       │                            remote_round_trip_time_ms
                                       ▼
                         LiveKit Cloud SFU (forward)
                                       │
                                       ▼   (browser viewer)
            ┌─────────────────────────────────────────────────────┐
            │ WebRTC inbound RTP → jitter buffer → H.264 decode   │ ← inbound_fps, frames_decoded
            │                                                     │   frames_dropped, packets_lost
            │                                                     │   jitter_ms
            │                                                     │   jitter_buffer_target_delay_ms
            └──────────────────────────┬──────────────────────────┘
                                       │
                                       ▼
            ┌─────────────────────────────────────────────────────┐
            │ <video> element playout                             │ ← rendered_frames_delta (rVFC)
            │                                                     │   playout_dropped_frames_delta
            │                                                     │   freeze_events_delta (>150ms)
            │                                                     │   freeze_max_gap_ms
            └─────────────────────────────────────────────────────┘
```

Two notes about this picture:

- **Stages 1-3 (DAT, decode, capturer) only exist for glasses.** The front camera goes straight from `AVCaptureDevice` into the LiveKit encoder, so there is nothing analogous to measure.
- **From `BufferCapturer.capture(_:)` onward the two paths merge.** Stages 4-7 use the same code and same metrics for both sources, which is what makes the "earliest divergence" framing tractable.

## Appendix B — Metric reference

### Pre-LiveKit (glasses only)

| Field | Source | Definition |
|---|---|---|
| `dat_callback_fps` | DAT listener | Times per second `videoFramePublisher.listen { ... }` fired in the window. |
| `dat_callbacks_delta` | DAT listener | Raw callback count for the window. |
| `dat_interframe_gap_p50/p95/max_ms` | DAT listener | Rolling percentiles of the wall-clock gap between consecutive callbacks (using `ProcessInfo.systemUptime`, monotonic). |
| `decoder_rebuilds_delta` | VT decode | Times the `VTDecompressionSession` was torn down and rebuilt (e.g. resolution-ladder swap). |
| `decode_errors_delta` | VT decode | Decode calls that returned `OSStatus != noErr`. |
| `decoded_frames_delta` | VT decode | `CVPixelBuffer`s successfully produced. |
| `capturer_frames_delta` | After decode | Pixel buffers handed to LiveKit's `BufferCapturer`. |

### LiveKit encode boundary (both sources)

| Field | Source | Definition |
|---|---|---|
| `outbound_fps`, `frames_encoded_delta` | `OutboundRtpStreamStatistics` | What the H.264 encoder actually emitted onto the wire. |
| `bitrate_bps` | derived from `bytesSent` | Egress bitrate at the sender. |
| `outbound_width / _height` | `OutboundRtpStreamStatistics` | Encoder output resolution. |
| `quality_limitation_reason` | `OutboundRtpStreamStatistics` | WebRTC's diagnosis: `none`, `cpu`, `bandwidth`, `other`. Sustained limitation, not short-burst drops. |
| `quality_limitation_duration_*_s` | same | Seconds spent in each limitation state over the window. |
| `quality_limitation_resolution_changes` | same | Times the encoder stepped its own resolution. |

### Network (sender's view via RTCP)

| Field | Source | Definition |
|---|---|---|
| `remote_jitter_ms` | `RemoteInboundRtpStreamStatistics` | RFC 3550 inter-arrival jitter as computed by the SFU. Exponentially smoothed: `J += (|D| − J) / 16`. |
| `remote_round_trip_time_ms` | `RemoteInboundRtpStreamStatistics` | Sender-side RTT to the SFU, from RTCP receiver reports. |
| `remote_packets_lost_delta` | `RemoteInboundRtpStreamStatistics` | Packets the SFU told me it didn't receive. |

### Browser ingress (viewer)

| Field | Source | Definition |
|---|---|---|
| `inbound_fps`, `inbound_width/height` | `RTCInboundRtpStreamStats` | Per-second cadence and resolution as the browser receives it. |
| `frames_decoded_delta` | same | Frames successfully decoded by the browser's WebRTC stack. |
| `frames_dropped_delta` | same | Frames received but not decoded (e.g. missing reference, corrupted). |
| `packets_lost_delta`, `jitter_ms` | same | Receiver-side network loss and jitter. |
| `jitter_buffer_target_delay_ms` | same | Cumulative WebRTC counter for chosen jitter-buffer depth (sum-over-frames). The repo's analyzer ([`scripts/analyze-video-quality.js`](../../scripts/analyze-video-quality.js)) reports the per-frame mean as `jb_perframe_ms` (= cumulative ÷ total decoded frames). |

### Browser playout

| Field | Source | Definition |
|---|---|---|
| `rendered_frames_delta` | `requestVideoFrameCallback` | Frames actually painted by the `<video>` element. |
| `playout_dropped_frames_delta` | `HTMLVideoElement.getVideoPlaybackQuality()` | Frames decoded but not painted (newer frame already due, GPU pressure, etc.). |
| `freeze_events_delta` | rVFC timestamps | `requestVideoFrameCallback` gaps >150 ms. |
| `freeze_max_gap_ms` | rVFC timestamps | Largest such gap. **Cumulative-max within a run**, not per-window; the analyzer takes the max across windows correctly but the field name is misleading. |

## Appendix C — Caveats and instrumentation limits

**Things I can measure but have to interpret carefully.**

- `freeze_max_gap_ms` is cumulative-max-since-start within a run, so every window in a single run reports the same value (the worst gap observed so far). The analyzer's max-across-windows reducer gives the right run-level number; the raw per-window field is not safe to interpret on its own.
- `jitter_buffer_target_delay_ms` is a cumulative WebRTC counter, scaling with run duration. The analyzer (`scripts/analyze-video-quality.js`) divides by total `frames_decoded` and reports the per-frame mean as `jb_perframe_ms`.
- `quality_limitation_reason: none` means WebRTC isn't sustained-limited, not that no input frames were dropped. Short-burst encoder drops show up only as `frames_encoded_delta` < `capturer_frames_delta`.

**Things I cannot see.**

- **Inside the BT Classic link layer.** No probes on the actual L2CAP / ACL transport. My earliest observable signal is the DAT callback firing on iPhone.
- **Inside DAT.** Whether the SDK is buffering frames internally before invoking `videoFramePublisher.listen { ... }`, and whether the observed bursts reflect raw link delivery or post-buffering shape, cannot be distinguished from app-side instrumentation.
- **Glasses-side encoding.** No visibility into the on-glasses encoder's actual output cadence or PTS spacing.
- **LiveKit's internal frame-drop decision.** I observe the net effect (`frames_encoded_delta` < `capturer_frames_delta`) but not the per-frame "encoded vs dropped" tag.

A note on terminology, given the above: where this report says "BT Classic delivery cadence is bursty," what's actually measured is the cadence at the first app-accessible point downstream of the BT link — the `videoFramePublisher` callback. The bandwidth-sweep evidence in §4.2 rules out throughput saturation as the cause, but the burstiness cannot be localized to a specific layer of the BT/DAT stack from app-side instrumentation alone.

## Appendix D — Frame types primer

H.264 and HEVC streams are sequences of **access units**, each of which decodes into exactly one output picture. In this pipeline there are two flavors that matter:

- **I-frame (keyframe).** Self-contained; the decoder can start here without any prior context. Large — typically 10-100× the size of a P-frame.
- **P-frame (predicted).** Encodes the delta from a previous reference frame. Small. Requires the reference to decode.
- **B-frame (bidirectional).** Predicts from past and future frames. Disabled in both DAT and LiveKit's H.264 config because "future" implies added latency.

**Implications for the metrics in this report.** Every counter that says "frames" counts access units, regardless of type — `dat_callbacks_delta` counts I-frames and P-frames the same way, `frames_encoded_delta` likewise. In the steady state with no losses (which is my situation), `dat_callbacks ≈ decoded_frames ≈ capturer_frames`.

**Implication for failure modes.** Losing an I-frame is much worse than losing a P-frame: every subsequent P that references the missing I (or chains back to it via other Ps) is undecodable, causing either visible corruption or a stall until the next keyframe arrives. In this analysis I observed neither (0 packet loss, 0 decode errors), so frame-type discrimination wasn't necessary for the finding. It does become necessary for the proposed smoothing buffer — its overrun-drop policy needs to prefer dropping P-frames over I-frames to avoid breaking the prediction chain.
