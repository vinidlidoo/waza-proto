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

- **Stage 0 viewer compat confirmed (2026-05-27).** Vincent verified `video/H265` on Chrome `chrome://webrtc-internals` with the codec swap; Safari + Chrome both play. The plan-level "viewer HEVC over LiveKit WebRTC" risk is closed.
- **Stage 1 file layout split (2026-05-27).** Plan envisioned all Stage 1 logic landing in `GlassesSource.swift`. Implementation pulled the Annex-B conversion and the TCP server into their own files (`HEVCAnnexBExtractor.swift`, `EncodedFrameTCPServer.swift`) so `GlassesSource.swift` stays under control (~270 added lines of pure logic in two files vs one bloated file). `GlassesSource.swift` only carries the wiring + branch-on-toggle.
- **TCP single-client policy: latest wins.** Plan said "single client"; implementation drops the prior socket on a new connect (rather than rejecting the new one). Reason: makes ffplay reconnects during testing painless, and the `lk` relay should never produce a second concurrent client in normal use.
- **No Stage 1 pacer / backpressure logic.** `NWConnection.send` with completion-logging only. The plan-12 smoothing-buffer carryover question is explicitly Stage 2's call — measure freeze rate + `jitter_buffer_per_frame_delay_ms` before designing one.
- **Parameter-set injection per keyframe, not per IDR-type-check.** Used `kCMSampleAttachmentKey_NotSync` to detect keyframes rather than parsing the NAL header's `nal_unit_type`. CoreMedia gives us the sync-sample flag for free; HEVC NAL parsing is finicky (16-21 covers IDR/CRA/BLA, but exact mapping varies). On the false-positive side (sync sample absent but we inject anyway), it costs a few hundred bytes per frame in the worst case.
- **Local Network Privacy preflight via NWBrowser, not `listener.service`.** First attempt attached a Bonjour service to the listener (`listener.service = NWListener.Service(...)`) on the theory it'd trigger the LNP prompt. It did trigger the prompt, but inbound connections still got stuck in `.preparing` forever — Apple TN3179 + DTS thread 768666 confirm LNP cache desync between Settings toggle and the running listener's auth handle. Fix: separate `LocalNetworkAuthorization` class runs an `NWBrowser` preflight that publishes-and-browses a throwaway `_wazaproto-preflight._tcp` service, completing only once the user actually grants the prompt. The real listener is then plain raw TCP (no `.service`), bound after grant is verified. Also added `pathUpdateHandler` on inbound connections so future LNP denials surface explicitly via `unsatisfiedReason`.
- **TCP listener is a process-wide singleton across publish→unpublish cycles.** `allowLocalEndpointReuse = true` doesn't help when the same process tries to rebind the same port before the kernel's released the prior socket (cross-process only). Recreating per publish cycle reliably hit `POSIXErrorCode 48: Address already in use` on the second connect. Fix: `GlassesSource.sharedTcpServer` is static, bound once on first encoded publish, and survives subsequent unpublish→publish cycles. Per-cycle `unpublish` only drops the active client (`dropClient()`), not the listener.
- **"Grant camera access" gate restored.** Plan 13 (`40ff073`) dropped the gate on the assumption Meta's DAT SDK would self-prompt via `session.start`. Empirically false on fresh installs (DAT 0.7.0) — Vincent never saw the prompt. Restored the gate's original logic (`activeDeviceID != nil && cameraPermission != .granted` → show "Grant camera access"). Note this is a regression fix scoped *outside* plan 15's nominal scope but surfaced by the testing path.

### Stage 2 — measured findings (2026-05-27)

- **Stage 2 acceptance metric (`jitter_buffer_per_frame_delay_ms`) MET.** Encoded 3-min viewer-side run today: **91.83 ms** median; d=2 smoothed-re-encode baseline from sweep §4b: 86.00 ms. The plan's open empirical question was "does the receiver's jitter buffer adapt to unpaced wire input, or does it drift back toward 114 ms?" — it adapts. **No TCP pacer needed for latency.**
- **Freeze rate regresses to pre-smoothing (d=0) levels.** Encoded: 45 freezes, 1,864 ms worst, 15.5% playout-dropped. d=0 (no smoothing, from sweep §4b): 45 freezes, 1,437 ms worst, 9.0% playout-dropped. d=2 (smoothing): 10 freezes, 323 ms worst, 0.6% playout-dropped. Pass-through ≈ d=0 because plan 12's smoother did its 78% freeze reduction primarily via **stall-masking** (23% of pulls were repeat-last frames per sweep §5.4) — that path doesn't exist in pass-through. The latency metric and the freeze-masking effect are decoupled; the latency win held, the freeze-masking win is gone. **Fix path: PTS-paced TCP writer on the iPhone** (plan already sketched this — queue NAL units, write to socket on wall-clock schedule aligned to original frame PTS, drop-newest-non-IDR-P on overrun). Defer pending decision on whether the visual chop is acceptable vs the implementation cost.
- **Image-quality win is real but partly confounded.** Two contributors:
  1. **No transcode loss** — H.265 → raw → H.264 cascade eliminated. Plan-predicted ~1–3 dB PSNR / ~3–8 VMAF; **directly attributable to pass-through**.
  2. **Full 720×1280 vs d=2 baseline's 504×896** — encoded run held the HIGH rung; baseline had DAT-demoted to the medium rung. Possible causes: (a) today's BT was just better (sweep §3.1 documents non-stationary cadence), (b) the pass-through path removes in-app codec/thermal pressure, leaving DAT more comfortable at the high rung. One run can't disambiguate. To isolate: re-run d=2 at matched 720×1280 (force the high rung), or run pass-through at 504×896.
- **SIGSEGV on Ray-Ban accessory disconnect in encoded mode — blocking.** Hit twice today. The `EAAccessoryManager` disconnect doesn't surface as `DeviceSessionState.stopped` in DAT; the next `videoFramePublisher` frame closure fires with a torn-down `CMVideoFormatDescription`, and either the `HEVCAnnexBExtractor` parameter-set walk or the `tcpServer.send()` queue access segfaults. The legacy re-encode path doesn't trip this because the `VTDecompressionSession` is rebuilt-or-bailed defensively. **Must fix before `Config.glassesEncodedIngest = true` ships as default.** Suggested fix: guard the frame closure on `Self.sharedTcpServer != nil` AND validate `CMSampleBufferGetFormatDescription` returns a still-live descriptor before extraction.
- **Watchdog doesn't catch `EAAccessory` disconnects — pre-existing regression.** Independent of plan 15 but uncovered by Stage 2 testing. The watchdog observes `DeviceSession.stateStream` + `errorStream`. The BT accessory disconnect at `EAAccessoryManager` level doesn't promote to either, so `onTerminated` never fires. UI keeps showing "Connected" while glasses are detached and DAT is silent. Plan 13's territory; should be filed as tech debt or a separate fix in `GlassesGateway`/`GlassesSource`.

### Stage 2 — matched-session three-run A/B (2026-05-27, evening)

After the rushed first encoded vs sweep-day-d=2 comparison hit several confounders (different BT regime, different resolution rung), we ran a clean A/B in a single session: encoded #1 → re-encode d=2 → encoded #2, all at 720×1280 HIGH rung, same Wi-Fi, same room. The two encoded runs sandwich the re-encode to bound any drift between them. Full table + analysis at [`plans/features/encoded-ingest-ab.md`](../features/encoded-ingest-ab.md).

- **Latency parity confirmed at scale.** `jitter_buffer_per_frame_delay_ms` lands at 104.56 (re-encode) vs 112.71 / 98.54 (encoded #1/#2) — within a 15 ms band. The plan's open question ("does the receiver's jitter buffer adapt to unpaced wire input, or drift back toward 114 ms?") answers as "yes, mostly." No latency-side reason to build a TCP pacer.
- **Encoder-side drops are not free.** Re-encode dropped 15 frames at the LiveKit encoder despite `quality_limitation_reason: none`. Sweep §5.2 hypothesised this; today's data confirms it. Encoded path drops 0 encoder-side frames because there's no encoder. A small win but consistently visible.
- **Image-quality story simplified.** All three runs ran 720×1280 today, so the "encoded held the high rung because no codec/thermal pressure" hypothesis from the morning run is a wash here. The subjective quality win traces **entirely to no-transcode-loss** — plan-predicted 1–3 dB PSNR / 3–8 VMAF, matches observation.
- **Freeze regression confirmed with magnitude.** Re-encode 28 freezes / 703 ms worst vs encoded 45 / 1,864 and 76 / 3,044. The plan-12 smoother's stall-masking (1.2% repeat-last events even in today's lucky regime) is real and irreplaceable in the current pass-through wire. DAT delivery still spikes to 278 ms p95 / max in lucky regime, which the wire faithfully transmits to the viewer.
- **Pass-through is timing-sensitive across runs.** Encoded #1 → #2 went 45 → 76 freezes (70% increase) at "identical" conditions. The smoothed path doesn't show this kind of cross-run swing because it equalises input cadence pre-encoder. Pass-through exposes BT non-stationarity straight to the viewer.
- **The relay (lk-cli) is timing-neutral, not a contributor.** It reads bytes off TCP and packetizes RTP without buffering or pacing. Paced-in → paced-out, bursty-in → bursty-out. Cleanest control test (deferred): `lk room join --publish assets/testsrc.h264` (steady 30 fps file source) through the same relay + SFU + browser. If smooth, the relay is provably innocent. Doesn't require glasses.
- **Tooling: `scripts/compare-profile-runs.js` extended.** It now labels encoded-ingest runs distinctly (via `glasses_encoded_ingest` flag added to the iOS `run_start` event), and `§3c Smoothing buffer` correctly shows N/A for encoded columns. Re-running future A/Bs is `node scripts/compare-profile-runs.js profiler/`.
- **Profiler tech debt: encoded mode emits no per-window stats.** The profiler hooks into `TrackDelegate.didUpdateStatistics` for window emission, but encoded mode publishes no iOS video track. `GlassesProfilerCounters` keeps counting internally — just nothing serialises them. Next session should add a window emitter that runs from a timer when no track is attached, populated from the counter snapshots.
- **Profiler tech debt resolved 2026-05-28.** `VideoQualityProfiler` now starts a 1-second `DispatchSourceTimer` when `start()` is called with no attached track and `source == "glasses"`, emitting the same `profile_window` shape with outbound/RTCP fields nulled out and the glasses-counter merge intact. Encoded runs now populate §3a's DAT delivery + capturer-handoff rows; §3a decode rows are zeros (semantically accurate — encoded path doesn't decode); §3a encoder + RTCP rows stay dashes (no track to report on). No script change needed — the existing `glasses_encoded_ingest` flag still drives the column label; the empty-iosWindows fallback heuristic becomes inert (correctly).
- **Stage 2 — stressed-regime A/B (2026-05-28 morning, 504×896).** Full report at [`plans/features/encoded-ingest-ab.md` §4](../features/encoded-ingest-ab.md#4-stressed-regime-ab-2026-05-28-morning-504896). Two non-obvious findings that change the encoded-default decision:
  - **Encoded delivers ~25% more DAT callbacks than re-encode (30 vs 24 fps)**, same iPhone same glasses 5 min apart. First evidence that the iPhone's VTDecompressionSession + LiveKit encoder pipeline contends with the DAT listener thread — encoded's lightweight TCP send doesn't. Implies encoded uses less CPU/battery (worth instrumenting thermal in a future run); also means the freeze comparison is unfair to re-encode (fewer input frames to smooth).
  - **The plan-12 smoother is architecturally load-bearing under stress, not a polish item.** Re-encode kept worst-freeze to 331 ms vs encoded's 3,068 ms (9× better), and freeze count 12 vs 29 (2.4× better), despite the buffer running at depth p50=1 and 18.4% underrun rate. The smoother is doing its hardest work exactly when BT is worst. Removing it (encoded mode) produces 3-second freezes in real-world regimes. PTS-paced TCP writer is the **gate** before encoded ships as default, not polish work.
- **Latency parity confirmed in stressed regime too.** JB per-frame 121.59 ms re-encode vs 127.58 ms encoded — Δ = 6 ms, within the same band as lucky-regime data (104.56/112.71/98.54 ms). The "extra Mac-relay hop" concern from this morning's discussion doesn't show up in receiver-perceived latency; absolute-latency instrumentation remains a future decision but isn't urgent.

## Vincent's learnings

*(filled in as we go)*

## Tech debt opened

*(filled in as we go)*

## Status

Drafted 2026-05-27.

- **Stage 0** — shipped on branch `plan/15-encoded-frame-ingest` (`abdf7b8`). Viewer compat verified: Vincent confirmed `video/H265` on Chrome WebRTC internals; Safari + Chrome both play. Bitrate-drop measurement deferred to Stage 2's A/B (the meaningful comparison) rather than as a Stage 0 gate.
- **Stage 1** — verified end-to-end on device 2026-05-27. ffplay decodes the Annex-B TCP bytestream as fluid recognizable POV; subjective image quality noticeably better than the LiveKit re-encode path (the headline win); hinge-fold tears the connection down cleanly; backgrounded run via lockscreen holds the stream past the iOS suspension grace windows with no `[tcp] send error` events. Multiple iterations along the way uncovered three load-bearing fixes — see Decisions logged.
- **Stage 2** — measured across two BT regimes 2026-05-27/28. End-to-end pipeline works in both encoded and re-encode modes. Lucky-regime three-run A/B at 720×1280 (evening of 2026-05-27) and stressed-regime two-run A/B at 504×896 (morning of 2026-05-28) both captured. Full report at [`plans/features/encoded-ingest-ab.md`](../features/encoded-ingest-ab.md). **Latency parity confirmed in both regimes** (jb_per_frame Δ ≤ 15 ms). **Image quality wins from no-transcode-loss alone** (resolution matched between paths). **Freeze regression severity tracks BT regime**: lucky 45/76 vs 28 events (1.8–3.0s vs 0.7s worst), stressed 29 vs 12 events (3.1s vs 0.3s worst). **New finding under stress**: encoded path delivers ~25% more DAT frames (30 vs 24 fps), suggesting iPhone CPU contention from decode/encode pipeline throttles DAT delivery in re-encode mode. **Updated gating before flipping `Config.glassesEncodedIngest = true` as default**: (a) SIGSEGV crash on accessory disconnect — blocking; (b) **PTS-paced iPhone-side TCP writer is now the gate, not polish** — stressed-regime data shows the smoother is architecturally load-bearing; without an equivalent in encoded mode the path is unusable in real BT regimes; (c) optional control test with file-source through the relay to prove relay timing-neutrality.
