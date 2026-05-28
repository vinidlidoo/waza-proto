# 15 — Encoded-frame ingest (HEVC pass-through)

Drop the in-app HEVC decode + LiveKit H.264 re-encode in the glasses path. Today: glasses HEVC → `VTDecompressionSession` → raw `CVPixelBuffer` → `BufferCapturer.capture(...)` → LiveKit re-encodes to H.264 → SFU → viewer. Target: glasses HEVC → SFU → viewer, with no codec round-trip on the iPhone.

## Goal

Pre-encoded HEVC sample buffers from `MWDATCamera.Stream.videoFramePublisher` reach the LiveKit room without local decode and without re-encode. The viewer plays back the same bitstream the glasses produced.

## Why this slice — four wins combined

- **Latency.** ~15–50 ms net saved at the publisher (decode + re-encode pipeline depth + compute), after accounting for the smoothing buffer story (see below).
- **Quality.** Eliminates generation loss from the H.265 → raw → H.264 cascade — both lossy at 0.79 Mbps. Literature: ~1–3 dB PSNR / ~3–8 VMAF penalty. Plus single-pass HEVC at 0.79 Mbps ≈ H.264 at ~1.1 Mbps equivalent (codec-efficiency bump for free).
- **Power / thermals.** Drops one HW decode + one HW encode per frame — roughly half the codec work on the iPhone. Matters most for long backgrounded sessions (plan 07's regime).
- **Bitrate.** ~30% reduction at equivalent quality from the HEVC efficiency curve.

The codec-swap-only feature (`features/h265-publish.md`) only delivers the bitrate bullet. Full pass-through is the lever.

## Landscape (2026-05-27)

Two paths to true pass-through:

**Path A — Swift SDK native API.** `livekit/rust-sdks#1048` ("encoded_video_ingest") prototypes `EncodedVideoTrackSource` + `PassthroughVideoEncoder` with H.264/H.265 parameter-set auto-prepend. **Still OPEN, REVIEW_REQUIRED, last commit 2026-05-05.** Critical gotcha: `client-sdk-swift` has its own libwebrtc-sys bindings (not the Rust FFI), so #1048 merging is necessary but not sufficient — a separate Swift port is required and **no such PR is in flight**. Realistic outlook: 3–6+ months minimum.

**Path B — `livekit-cli` TCP relay.** Shipped (livekit/livekit-cli#722, merged 2026-01-12). `lk room join --publish h265://host:port` reads raw HEVC NAL units over TCP and publishes them to the room with no re-encode. Works today; cost is a Go process colocated with the iPhone.

**Recommendation: Path B.** Path A is the right long-term answer but uncommitted; Path B is shippable now, validates the full pipeline (including viewer HEVC playback that Path A would also need), and is forward-compatible — when Path A lands, we swap the relay for a native API call. The LAN constraint is acceptable for v0.x where Vincent is the wearer; not acceptable for "wearer on cellular," but that's out of scope.

## Scope (this plan)

Three stages, each gated on the prior.

### Stage 0 — Viewer HEVC playback verification

Flip the Swift SDK's publish codec to H.265 while keeping the current decode+re-encode path:

```swift
VideoPublishOptions(simulcast: false, preferredCodec: .h265)
```

**No `preferredBackupCodec: .h264`.** Adding it would trigger simulcast (publishing both codecs concurrently to cover non-HEVC subscribers), doubling publisher upload + encode work. For v0.x our subscribers are Safari (macOS/iOS) and Chrome (macOS) — both decode HEVC over WebRTC. If a future subscriber lacks HEVC, they can't watch this room.

**Done.** `viewer/` plays the H.265 track on Safari (macOS) and Chrome (macOS); plan 11 profiler shows ~30% bitrate drop at the same visual quality.

### Stage 1 — iPhone HEVC TCP listener

Extract HEVC Annex-B from each DAT `frame.sampleBuffer` and serve it over a `Network.framework` `NWListener` on TCP port 16400.

Implementation notes:
- **Source.** `GlassesSource.swift:102` already has the `videoFramePublisher.listen { frame in … }` listener. Add an Annex-B extraction step (length-prefix → start-code conversion; SPS/VPS/PPS injection at IDRs from the cached `CMVideoFormatDescription` since DAT doesn't ship them inline).
- **Listener.** Single client (`lk` is the only consumer). Survives backgrounding under our existing setup — see Risks below.
- **Behind a Config toggle.** New `Config.glassesEncodedIngest: Bool` (default false). When true, `GlassesSource` skips the LiveKit `BufferCapturer.publish` path entirely; only the TCP server runs. When false, current path unchanged.

**Done.** TCP listener serves Annex-B HEVC to a local `ffplay`/`nc` consumer; bytestream plays as recognizable POV video; hinge-fold + session restart tear down cleanly; 5-min backgrounded run from the Home screen (not Xcode) with an actively-reading TCP client on the LAN keeps data flowing — listener-alive alone isn't a sufficient probe.

### Stage 2 — Go relay + end-to-end measurement

- **Relay.** `lk room join --publish h265://<iphone-ip>:16400 <room>` on Vincent's Mac, same LAN. If single-stream HEVC SFU forwarding (server-sdk-go#901, still open) bites, the fallback is `lk-cli`'s multi-`--publish` code path which doesn't share the server-sdk-go bug — exact invocation is a Stage 2 implementation detail (the README's simulcast syntax expects distinct resolutions per port, so we'd either lie about layer dimensions or wait for #901).
- **Switchover.** With `glassesEncodedIngest = true`, the iPhone's LiveKit `Room` no longer publishes a video track for the glasses path. Mic track (plan 07's `AVAudioSession` keep-alive) stays exactly as-is — and this is load-bearing: the active audio session is what keeps the app un-suspended, which is what keeps the TCP listener serving. **Two-participant model:** iPhone joins the room as audio-only publisher, `lk` joins as a separate identity (e.g. `glasses-passthrough`) as video-only publisher. The viewer already iterates remote participants and subscribes to all their tracks, so no viewer change expected; confirm during integration.
- **A/B measurement.** Plan 11 profiler in both modes, matched 3-min sessions. Compare:
  - **`jitter_buffer_per_frame_delay_ms`** — explicit acceptance metric. Prediction: rises from ~86 ms (current paced path) back toward ~114 ms (plan 11 baseline) on unpaced pass-through. If it lands close to 86 ms, no pacer needed; if it climbs back toward 114 ms, that's the quantitative threshold for "build the TCP pacer."
  - **Viewer freeze rate + worst-freeze ms** (plan 12's headline metrics) — confirm pass-through doesn't regress freeze behavior.
  - **Round-trip latency proxy** (`remote_round_trip_time_ms` + jitter-buffer combined).
  - **iPhone thermal state** (`ProcessInfo.thermalState`) and Xcode Energy Log on a 10-min session.
  - **Subjective VMAF / visual A/B** on a fixed scene.

**Done.** Pass-through mode delivers (a) latency proxy within or below current pipeline, (b) freeze rate at or below current path, (c) measurably cleaner motion edges, (d) lower thermal/CPU on a 10-min session.

## Out of scope

- Hosted relay + carrier NAT tunnel (production mobility) — defer until product shape demands it.
- Multi-resolution simulcast.
- Path A integration — watch upstream, plan a follow-up if/when it ships.
- Front-camera pass-through (front camera publishes raw frames, not encoded — doesn't apply).

## Key decisions

- **Path B over Path A.** Already explained above; Path A's timeline is uncommitted.
- **Stage 0 first.** One-day codec swap that validates the viewer side before any TCP-server investment. If HEVC playback doesn't work on Safari/Chrome over LiveKit, the plan is moot and we learn that immediately.
- **Smoothing buffer is an open empirical question.** The plan-12 buffer did three jobs (per the sweep report §5.4): stall-mask, burst-absorb, pace. On pass-through:
  - **Stall-mask** → N/A. The browser's `<video>` element naturally holds the last decoded frame across PTS gaps.
  - **Burst-absorb** → N/A. No LiveKit encoder on the publisher to protect from bursty input.
  - **Pace** → the only remaining job, and worth a concrete number: plan 12 measured paced input cutting the viewer's `jitter_buffer_per_frame_delay_ms` from ~114 → ~86 ms (~28 ms saved per frame). Without pacing on pass-through, expect that to drift back up.

  So "do we need a smoother on pass-through?" reduces to "do we want ~28 ms latency reduction in exchange for the engineering effort?" The ~15–50 ms decode/re-encode savings and the ~28 ms re-inflation are in the same ballpark — they could partly cancel.

  Pacing is technically achievable on the pass-through wire: raw Annex-B NAL units don't carry an authoritative RTP timestamp; `lk` derives RTP timing at packetization from when bytes arrive over TCP. So a PTS-paced TCP writer on the iPhone (queue NAL units, write to socket on a wall-clock schedule aligned to original frame PTS) is feasible. Overrun policy should stay *light* — plan 12's runs saw low single-digit overrun rates, sustained overrun isn't the regime — so *drop newest non-IDR P* or *hard cap + reject for one frame interval* fits the data, and **not** "drop to next IDR" (would lose seconds at DAT's 1–4 s GOP). Stage 2 measures freeze rate **and** jitter-buffer delay first without any encoded-side smoother; design and add the pacer only if the numbers say so.
- **`Config.glassesEncodedIngest` toggle.** Same pattern as `Config.glassesSmoothingDepth` — lets us flip paths in testing without rebuilding, and ship the new path as opt-in until it's run for a week without regressions.

## File layout (expected delta)

```code
ios/WazaProto/WazaProto/GlassesSource.swift   ← Annex-B extraction, TCP listener, gated by Config.glassesEncodedIngest
ios/WazaProto/WazaProto/Config.swift          ← new knob
ios/WazaProto/WazaProto/RoomConnection.swift  ← skip video publish when in encoded-ingest mode
ios/WazaProto/WazaProto/Info.plist            ← add UIRequiresPersistentWiFi; possibly NSLocalNetworkUsageDescription
plans/active/15-encoded-frame-ingest.md       ← this file
plans/features/h265-publish.md                ← retire as Stage 0 closes it
plans/features/encoded-frame-ingest.md        ← retire (superseded by this plan)
plans/index.md
```

No Go code in this repo — `lk` is invoked from the command line.

## Risks and unknowns

- **Backgrounding lifecycle: resolved.** Per Apple's official guidance (TN2277 + DTS threads): `NWListener` survives backgrounding *as long as the app isn't suspended*. Our existing `audio` background mode + the active `AVAudioSession` from plan 07's mic publish is exactly the mechanism that prevents suspension — same path that keeps DAT delivery + LiveKit publish alive today. Required additions: set `UIRequiresPersistentWiFi = YES` in `Info.plist` so iOS doesn't disassociate from Wi-Fi when backgrounded. Validation gotcha: must test from the Home screen with system log capture, not Xcode-attached, because the debugger suppresses suspension and masks the real behavior.
- **GOP cadence and initial-frame delay.** `lk` README explicitly notes: *"pre-encoded video's fixed keyframe intervals … initial delay before the video becomes visible to the remote viewer."* DAT's IDR cadence is unknown; probably 1–4 s. Subscribers joining mid-stream wait for the next IDR. Likely acceptable; flag if worse than expected.
- **`server-sdk-go#901` single-stream HEVC SFU forwarding bug.** Still open. Fallback: invoke simulcast path via two `--publish` flags pointing at the same source (e.g. two TCP listeners on different ports, both serving identical bytestreams) — adds publisher complexity, unblocks.
- **Parameter-set injection.** `CMSampleBuffer` from DAT carries VPS/SPS/PPS out-of-band via `CMVideoFormatDescription`. The TCP wire format needs them prepended to every IDR or `lk` rejects the stream. One-time-cache-and-prepend at the listener boundary. **Verify in Stage 1** that DAT's `CMSampleBuffer` is HVCC (length-prefixed NAL units) — the typical VideoToolbox shape — so the conversion to Annex-B (start codes) is straightforward; if it's already Annex-B from the SDK, the conversion step drops out.
- **Viewer HEVC compat.** Stage 0 de-risks. Chromium on Linux is the known weak spot; not a v0.x target.

## Done criteria (overall plan)

1. Stages 0/1/2 each meet their stage-level done criteria.
2. End-to-end glasses → viewer with `Config.glassesEncodedIngest = true` plays at full quality on Safari (macOS) and Chrome (macOS).
3. Plan 11 profiler shows lower thermal/CPU and equal-or-better latency proxy vs. the current path.
4. Visual A/B on a fixed scene shows perceptibly cleaner motion edges (subjective is fine for v0.x).
5. Current re-encode path remains the default; pass-through ships opt-in until at least three real-session runs (foreground + backgrounded + hinge-fold cycle) pass cleanly.

## Decisions logged during implementation

*(filled in as we go)*

## Vincent's learnings

*(filled in as we go)*

## Tech debt opened

*(filled in as we go)*

## Status

Drafted 2026-05-27. Stage 0 implementation committed on `plan/15-encoded-frame-ingest` (`abdf7b8`); builds clean, app boots on device without crash. Awaiting glasses-on-face verification of viewer HEVC playback (Safari + Chrome on macOS) and the ~30% bitrate drop via plan 11 profiler before promoting Stage 1.
