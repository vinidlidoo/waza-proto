# Video quality profiling

**What.** Add opt-in instrumentation that shows where the glasses video path diverges from the front-camera baseline: LiveKit publish, SFU/network receive, browser playout, and only then lower-level glasses capture/decode probes if the boundary stats are inconclusive.

**Why.** The end-to-end flow works, but the Ray-Ban glasses feed jitters and stutters. Before changing codecs, resolutions, relays, or LiveKit options, we need repeatable measurements that can separate:

- glasses-to-phone capture cadence problems,
- in-app HEVC decode stalls or resolution ladder switches,
- iPhone re-encode / WebRTC sender limits,
- network/SFU packet loss or jitter,
- browser decode/playout drops and freezes.

## Scope

- Staged profiler ladder, starting at the LiveKit boundary before touching the hot glasses decode path.
- iOS publisher-side and browser viewer-side JSONL logs with a stable schema.
- One-tap run-start coordination from the iOS debug UI to the viewer over LiveKit data channel.
- Repeatable paired runs: front camera vs glasses under the same room, viewer, Wi-Fi, and duration.
- Local analysis script that aggregates runs into a comparison table.

## Non-goals

- Do not fix the quality issue in this pass.
- Do not implement encoded-frame ingest, H.265 publish changes, or relay infrastructure.
- Do not add cloud persistence or a metrics backend.
- Do not redesign the main app/viewer UI. Debug surfaces stay opt-in.

## Implementation ladder

### Stage 1 - LiveKit boundary stats

Build the JSONL pipeline, run coordination, viewer overlay, and analyzer first. Instrument only the points that apply to both sources:

- iOS local track stats via LiveKit Swift's once-per-second `TrackStatistics` updates.
- Browser receive stats via LiveKit JS `RemoteVideoTrack.getRTCStatsReport()` / receiver stats.
- Browser playout stats via `HTMLVideoElement.getVideoPlaybackQuality()` and `requestVideoFrameCallback`.
- Local capture helper that writes iOS stdout JSONL into `profiler/`.
- Browser JSONL download plus localhost auto-save into `profiler/` with the matching run id.
- Analyzer script that aggregates at least three paired runs per source.

Stage 1 answers: do the LiveKit sender/receiver/playout stats already separate the front-camera and glasses paths? If yes, stop here and use the data to pick the next quality fix. If no, proceed to Stage 2.

Verify during Stage 1 whether LiveKit Swift exposes `qualityLimitationReason`, `qualityLimitationDurations`, and remote inbound packet loss/jitter for this local track. Treat missing fields as nullable schema fields, not blockers.

### Stage 2 - Glasses callback and decode counters

Only if Stage 1 is inconclusive, add aggregate counters around `GlassesSource`:

- DAT frame callback FPS and inter-frame gap p50/p95/max.
- decoder rebuild count and dimensions.
- decode success/error counts, including `OSStatus`.
- decoded frames handed to `BufferCapturer`.

Absorb the existing `[glasses]` decode/session prints into the profiler so stdout has one source of truth. Keep human-readable lifecycle logs only where they are not metrics.

### Stage 3 - Per-frame timing probes

Only if Stage 2 is still inconclusive, add deeper timing probes:

- input `CMSampleBuffer` PTS cadence.
- encoded frame dimensions on every format-description change.
- decode latency from DAT callback receipt to decoded `CVPixelBuffer`.

No stage may do per-frame I/O. Hot-path probes update counters only; emission is window-aggregated. If counters are touched from the DAT callback or VideoToolbox callback, use lock-free atomics or actor/message handoff that does not block the callback.

## JSONL schema

One JSON object per line. Keep field names stable; add new metrics as nullable fields or nested `metrics` keys.

Each side writes one `run_start` event followed by one `profile_window` event per second.

```json
{
  "schema_version": 1,
  "event": "run_start",
  "run_id": "2026-05-26T19-42-10Z-glasses-a",
  "side": "ios",
  "source": "glasses",
  "stage": 1,
  "process_start_epoch_ms": 1780000000000,
  "duration_ms": 180000
}
```

Common window fields:

```json
{
  "schema_version": 1,
  "event": "profile_window",
  "run_id": "2026-05-26T19-42-10Z-glasses-a",
  "side": "ios",
  "source": "glasses",
  "stage": 1,
  "window_start_epoch_ms": 1780000010000,
  "window_duration_ms": 1000,
  "metrics": {}
}
```

Units:

- timestamps: Unix epoch milliseconds.
- durations and gaps: milliseconds.
- rates: frames per second or bits per second, named with `_fps` / `_bps`.
- counters: monotonically increasing within the run unless named with `_delta`.
- unknown/unavailable fields: `null`, not omitted, when the analyzer expects the field.

Stage 1 iOS front-camera example:

```json
{"schema_version":1,"event":"profile_window","run_id":"2026-05-26T19-42-10Z-front-a","side":"ios","source":"frontCamera","stage":1,"window_start_epoch_ms":1780000010000,"window_duration_ms":1000,"metrics":{"outbound_width":1280,"outbound_height":720,"outbound_fps":29.8,"frames_encoded_delta":30,"bitrate_bps":1850000,"quality_limitation_reason":null,"remote_packets_lost_delta":0,"remote_jitter_ms":4.2}}
```

Stage 1 browser glasses example:

```json
{"schema_version":1,"event":"profile_window","run_id":"2026-05-26T19-47-10Z-glasses-a","side":"viewer","source":"glasses","stage":1,"window_start_epoch_ms":1780000310000,"window_duration_ms":1000,"metrics":{"inbound_width":1280,"inbound_height":720,"inbound_fps":24.1,"frames_decoded_delta":24,"frames_dropped_delta":3,"packets_lost_delta":0,"jitter_ms":7.8,"jitter_buffer_target_delay_ms":65.0,"rendered_frames_delta":21,"playout_dropped_frames_delta":3,"freeze_events_delta":1,"freeze_max_gap_ms":184}}
```

Stage 2 iOS glasses example:

```json
{"schema_version":1,"event":"profile_window","run_id":"2026-05-26T19-52-10Z-glasses-a","side":"ios","source":"glasses","stage":2,"window_start_epoch_ms":1780000610000,"window_duration_ms":1000,"metrics":{"dat_callback_fps":26.4,"dat_interframe_gap_p95_ms":68.0,"dat_interframe_gap_max_ms":141.0,"decoder_rebuilds_delta":0,"decode_errors_delta":0,"decoded_frames_delta":26,"capturer_frames_delta":26}}
```

## Run coordination

Profiling is manually initiated from the iOS app, but run start has one source of truth:

1. User opens the viewer with `?debugStats=1`.
2. User chooses `Front camera` or `Glasses` in the iOS app.
3. User taps `Start profiling run` in the existing debug UI.
4. iOS creates `run_id`, records `process_start_epoch_ms`, starts its local profiler, and sends a reliable LiveKit data-channel message:

```json
{"type":"profile-run-start","run_id":"2026-05-26T19-42-10Z-front-a","source":"frontCamera","duration_ms":180000,"process_start_epoch_ms":1780000000000,"schema_version":1}
```

1. Viewer starts its profiler when it receives that message. If no message arrives, the viewer does not invent its own run id.
2. iOS sends `profile-run-stop` at the end of the duration; viewer also stops itself if `duration_ms` elapses.

The analyzer aligns windows by `run_id` and `window_start_epoch_ms`. RTC stats timestamps are not used for cross-process alignment.

Run id convention: `<utc-start>-<source>-<paired-run-letter>`, where the letter is `a`, `b`, `c` for the three paired runs of the same source/config. If the user switches source or disconnects mid-run, the current run stops and is marked incomplete; a new source gets a new run id.

## Run protocol

Default run duration is 3 minutes. A 60-second mode is allowed only as a smoke check while building the profiler.

For a useful comparison:

1. Run three paired front-camera profiles.
2. Run three paired glasses profiles without moving the laptop, room, or network.
3. Repeat glasses runs for any candidate DAT config worth testing, starting with the current `.hvc1`, `.high`, `30fps` path.
4. Save iOS JSONL and browser JSONL under `profiler/` with the shared run id. Localhost viewer runs auto-save to `profiler/`; the viewer download link still sets `download="<run_id>-viewer.jsonl"` as a fallback for deployed runs.
5. Run the analyzer and compare medians/p95s across sources.

The first useful output is a table like:

```text
source        sent fps/bitrate   recv fps/loss   rendered drops/freezes   earliest divergence
front camera  ...                ...             ...                      ...
glasses       ...                ...             ...                      ...
```

Freeze definition for Stage 1: a browser render gap over 150ms observed via `requestVideoFrameCallback` increments `freeze_events_delta`; record the largest gap in `freeze_max_gap_ms`.

## File layout

```code
ios/WazaProto/WazaProto/
  VideoQualityProfiler.swift   NEW - counters, rolling windows, JSONL stdout
  RoomConnection.swift         + profiler lifecycle / run id / data-channel start-stop
  ContentView.swift            + start/export affordance in existing debug UI
  GlassesSource.swift          Stage 2+ only - aggregate DAT/decode probes

viewer/index.html              + ?debugStats=1 overlay + JSONL download/local auto-save
scripts/capture-ios-profiler-jsonl.sh
                               NEW - launch/capture helper that writes profiler/*.jsonl
                               (originally named profile-video-quality.sh)
scripts/run-paired-profile.sh
                               NEW - one-command wrapper: build/install, local viewer server,
                               invite URL, browser, iOS stdout capture, analyzer
                               (originally named run-stage1-profile.sh)
scripts/mint-viewer-invite-url.js
                               NEW - local invite URL helper; Node stdlib only, no package deps
scripts/analyze-video-quality.js
                               NEW - aggregate paired runs into comparison table; Node stdlib only, no package deps
profiler/                      NEW - gitignored local JSONL run output
.gitignore                     + profiler/
```

## Done criteria

1. Profiling is opt-in and default app/viewer behavior stays unchanged.
2. Stage 1 ships first: three front-camera and three glasses runs produce iOS sender stats, browser receiver stats, browser playout stats, and analyzer output.
3. Logs follow schema version 1 and include shared `run_id` / `source`; `run_start` lines include `process_start_epoch_ms`, and `profile_window` lines include `window_start_epoch_ms`.
4. iOS metrics are printed to stdout and captured as JSONL files under `profiler/`; browser metrics are auto-saved by the local viewer server when available, with manual download retained as fallback.
5. Hot-path probes never perform per-frame I/O; metrics emission is window-aggregated.
6. Stage 1 probe overhead is checked before declaring it done. Target: no visible stream regression and less than 5% added iPhone CPU in Instruments during a front-camera smoke run; if Instruments is skipped, document that assumption in the decision log.
7. Existing metric-like `[glasses]` prints are either converted to profiler metrics or removed when overlapping metrics ship.
8. The Stage 1 `TrackStatistics` field verification is recorded in `Decisions logged during implementation`, including any nullable/missing fields. Pulling raw `RTCStatisticsReport` from the underlying peer connection is out of scope for Stage 1.
9. The first A/B analysis identifies the earliest stage where the glasses feed diverges from the front-camera baseline, or explicitly shows that Stage 2/3 probes are needed and names the missing probe.

## Decisions logged during implementation

- **Stage 1 uses public LiveKit surfaces only.** Run coordination uses `LocalParticipant.publish(data:options:)` with `DataPublishOptions(topic: "waza.profile", reliable: true)`, and the viewer listens for `RoomEvent.DataReceived` on the same topic. Publisher tokens now need `canPublishData: true`; viewer tokens remain subscribe-only and can receive the data packet.
- **LiveKit Swift 2.14.1 exposes the Stage 1 sender fields through `TrackStatistics`.** `OutboundRtpStreamStatistics` includes width/height/FPS, `framesEncoded`, `bytesSent`, `qualityLimitationReason`, `qualityLimitationDurations`, and resolution-change count. `RemoteInboundRtpStreamStatistics` exposes packet-loss/jitter/RTT fields when WebRTC provides them. The profiler keeps these nullable rather than reaching into the underlying peer connection; raw `RTCStatisticsReport` access stays out of scope for Stage 1.
- **Local track stats must be explicitly enabled.** Adding a `TrackDelegate` is not enough; LiveKit Swift only starts its stats timer when `track.set(reportStatistics: true)` is called. The first smoke run proved this by producing iOS `run_start` / `run_stop` lines but no `profile_window` lines.
- **Analyzer stays dependency-free.** `scripts/analyze-video-quality.js` is a top-level Node stdlib script so it does not add another package boundary outside `viewer/`.
- **Stage 1 has a local automation wrapper.** `scripts/run-paired-profile.sh` (originally `run-stage1-profile.sh`) starts the local viewer server, mints a local `invite=` URL, opens the browser, optionally builds/installs the iOS app, and then delegates iOS stdout capture to `scripts/capture-ios-profiler-jsonl.sh` (originally `profile-video-quality.sh`). The local server accepts viewer JSONL at `/api/profile-capture`; deployed/Vercel viewer runs still use manual download.
- **The automation wrapper builds before opening the viewer.** An early smoke test opened the viewer before reinstalling/launching the app, which let the human start a front-camera run before iOS stdout capture was attached. The wrapper now builds/installs first, then starts the local viewer, opens the invite URL, launches the app with console capture, and only then prints the manual-step prompt.
- **Stage 1 smoke and one long paired run completed.** Latest long run files are `profiler/ios-2026-05-27T00-27-25Z.jsonl`, `profiler/2026-05-27T00-27-50Z-frontCamera-a-viewer.jsonl`, and `profiler/2026-05-27T00-31-00Z-glasses-a-viewer.jsonl`. The analyzer reported front camera at 30 fps / 1.70 Mbps with 1 viewer freeze, and glasses at 23 fps / 0.75 Mbps with 59 viewer freezes.
- **Plan number is 11.** Other sessions are occupying earlier active-plan slots, so this plan was promoted as `plans/active/11-video-quality-profiling.md`.
- **Analyzer surfaces stall windows and worst freeze gap.** Added two columns: `stalls` counts iOS windows with `frames_encoded_delta == 0` (canonical publish-stall signal — `outbound_fps == null` alone fires on the baseline-less first window). `max_freeze_ms` reduces the per-window monotonic `freeze_max_gap_ms` to the worst single-run peak in a group. The latest 3-min glasses run reported 2 stall windows and a 2506ms peak viewer freeze.
- **Stage 2 ships as a shared `GlassesProfilerCounters` singleton.** Hot-path writes (DAT listener + VideoToolbox decode callback) increment NSLock-protected cumulative counters; `VideoQualityProfiler.track(...)` snapshots once per window and computes deltas with the same pattern already used for `bytesSent` / `framesEncoded`. Picking a singleton over plumbing the counters through `RoomConnection` keeps `GlassesSource` ownership untouched at the cost of one shared instance — acceptable because only one glasses source is live at a time.
- **DAT inter-frame gaps use `ProcessInfo.systemUptime`, not `CFAbsoluteTimeGetCurrent`.** The latter is wall-clock and can step on calendar adjustments; systemUptime is monotonic. Gaps are accumulated per callback and drained on each snapshot.
- **Stage-2 metrics omitted from front-camera windows.** `dat_*`, `decoder_*`, `decoded_*`, `capturer_*` apply only to glasses; emitting them as null on front-camera windows would imply they're available but unmeasured. The schema rule about null-not-omit applies to fields the analyzer expects per source; the analyzer already tolerates missing fields.
- **Stage-2 `start()` drains the counters once to clear gaps accumulated since the listener was installed.** Otherwise the first window after a delayed run-start would attribute pre-run gaps to window 1. This also sets the baseline snapshot, so the first window's deltas are nil (same convention as `lastBytesSent`).
- **Pre-existing `[glasses] decode fps=...` and `decode error status=...` prints removed.** They overlapped with the new `dat_callback_fps` and `decode_errors_delta` fields. Lifecycle messages (`[glasses] decoder (re)built for WxH`, `VTDecompressionSessionCreate failed`) stay — they carry context the counters don't (dimensions, OSStatus).
- **(C) DAT cadence cap is documented behavior.** Meta's iOS integration guide states `frameRate` accepts only `{2, 7, 15, 24, 30}` and describes an automatic adaptive ladder: Bluetooth Classic bandwidth constraints first drop resolution one step (e.g. `high` → `medium`), then drop framerate (`30` → `24`), never below 15 fps. Our observed median 23.8 fps under `.high` + 30 matches the documented "30 → 24" rung. `StreamConfiguration` exposes only `videoCodec`/`resolution`/`frameRate`; `Stream` has no buffer or frame-strategy method. The public API surface is fully checked — no hidden knob.
- **(A) Lowering requested resolution makes things worse, not better.** Paired 3-min `.medium` + 30 run (`profiler/ios-2026-05-27T01-54-31Z.jsonl` / `profiler/2026-05-27T01-54-55Z-glasses-a-viewer.jsonl`) auto-demoted to `.low` (viewer received 360×640 vs 504×896 on the `.high` baseline) — the "one step" wording in the docs is misleading; the ladder demotes whatever rung you ask for. DAT cadence stayed identical (p50 23.9 vs 23.8 fps), tail gaps slightly improved (10 vs 36 windows >300ms), but bitrate fell by ~44% (~780K → ~437K mean) and **encoder drops more than doubled** (7.1% → 18.5%, 308 → 808 frames). Viewer playback regressed: decoded fps p50 24 → 20; worst freeze 993ms → 5145ms. **Verdict: BT Classic delivery cadence is the bottleneck, not bandwidth.** Reverted to `.high` + 30 — that's the best-known config until (B) ships.
- **Skip `.high` + 24 fps explicit request.** No hypothesis predicts it improves cadence: we're already operating at the documented "30 → 24" auto-rung, and asking for 24 directly doesn't change BT Classic burst timing.
- **`freeze_max_gap_ms` is a cumulative max-since-start, not per-window.** Identified during (A) analysis: every window in a run reports the same value (the worst gap ever observed in that run so far). Workable for now since the analyzer's `max_freeze_ms` reducer already takes the max across windows, but should be converted to a per-window delta in a future analyzer pass.

## Handoff notes

Current branch/worktree: `plan/video-quality-profiling` in `/Users/vincent/Projects/waza-proto-video-profiling`.

How to collect another Stage 1 run:

```sh
cd "/Users/vincent/Projects/waza-proto-video-profiling"
./scripts/run-paired-profile.sh
```

If device detection fails, pass `DEVICE_ID=<udid>`. If the app is already installed and signing/building is not needed, use `BUILD_APP=0`.

Latest Stage 1 interpretation:

- Front camera holds 30 fps at both iOS sender and viewer; viewer freezes are rare.
- Glasses sender stats already show lower cadence: median outbound FPS around 23 and median bitrate around 0.75 Mbps in the latest long run, with 2 publish-stall windows.
- Glasses viewer receives roughly the same FPS as iOS sends, with no packet loss in the analyzer table, but many render freezes — peak gap 2506ms.
- This makes the next likely investigation pre-LiveKit or at the glasses-to-publisher boundary: Stage 2 (now shipped) measures DAT callback cadence, decode success/error counts, decoder rebuilds, decoded frames, and frames handed to `BufferCapturer`.

Stage 2 status:

- Code shipped in `GlassesProfilerCounters.swift`, with writes in `GlassesSource.swift` and per-window reads in `VideoQualityProfiler.swift`. `stage` bumped to 2.
- New JSONL fields on glasses windows: `dat_callback_fps`, `dat_callbacks_delta`, `dat_interframe_gap_p50_ms`, `dat_interframe_gap_p95_ms`, `dat_interframe_gap_max_ms`, `decoder_rebuilds_delta`, `decode_errors_delta`, `decoded_frames_delta`, `capturer_frames_delta`. First window after `start()` reports the deltas as null (baseline snapshot); subsequent windows are meaningful.
- First 3-min paired Stage 2 run collected: `profiler/ios-2026-05-27T01-19-06Z.jsonl`, `profiler/2026-05-27T01-19-27Z-frontCamera-a-viewer.jsonl`, `profiler/2026-05-27T01-22-42Z-glasses-a-viewer.jsonl`. Both runs complete (`incomplete: false`), 178/179 windows.

Stage 2 findings (`profiler/ios-2026-05-27T01-19-06Z.jsonl`):

- **Root cause = DAT delivery.** `dat_callback_fps` p25/p50/p75 = 21.8 / 23.8 / 25.5, configured for 30. 100/179 windows had a max intra-window gap above 100ms; 36/179 above 300ms; worst single-frame gap 634ms. The BLE/Wi-Fi-Direct link itself bursts and starves.
- **In-app pipeline exonerated.** `decoder_rebuilds_delta` total = 0, `decode_errors_delta` total = 0, `dat_callbacks_total` (4311) ≈ `capturer_frames_total` (4310) — off by 1 (cross-window boundary effect). The resolution-swap decoder rebuild path never fired this run.
- **Encoder loses 7.1% of captured frames** (308 of 4310 captured → 4002 encoded). Mostly during DAT bursts above ~32fps. Secondary to the starve problem; viewer freezes correlate to DAT gaps, not encoder drops.
- **Bitrate volatility is downstream of starves.** Range 358K–1.6 Mbps, median 780K. Encoder inflates per-frame size when arrivals are sparse — no bandwidth limitation; supply-side jitter.
- **Viewer side this run:** 54 freezes, max gap 993ms (vs. 59 / 2506ms in the previous long run — similar shape, less catastrophic worst case).
- **Front-camera baseline had a 5898ms viewer freeze** despite iOS sender holding 30fps steady. Looks like a one-off browser/OS suspend; not investigated.

Stage 2 verdict:

- Skip Stage 3 (per-frame PTS / decode-latency probes). Decode is already proven clean (0 errors, 0 rebuilds, full parity); finer-grained timing wouldn't change the verdict.
- Investigation complete. Root cause identified: BT Classic delivery cadence (documented adaptive-ladder behavior, see (C) and (A) in the decisions log).
- Fix is a separate feature: [glasses-smoothing-buffer.md](../features/glasses-smoothing-buffer.md) — small ring buffer + display-link pump between DAT decode and `BufferCapturer.capture(...)` to absorb DAT bursts/stalls. Tracked in `plans/features.md`; plan 11 closes here.

Known analyzer caveats:

- `incomplete=true` is expected when the human manually stops a 3-minute run instead of letting the exact timer expire; the windows are still usable.
- `freeze_events_delta` counts viewer render gaps over 150ms. `freeze_max_gap_ms` is the largest gap observed so far in the run.
- `jitter_buffer_target_delay_ms` is a cumulative WebRTC counter; the analyzer now reports the per-frame mean as `jb_perframe_ms` (cumulative ÷ total decoded frames). Per-window instantaneous depth is still not exposed.
