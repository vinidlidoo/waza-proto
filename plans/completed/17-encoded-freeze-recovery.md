# 17 — Encoded pass-through freeze recovery (PLI deadlock)

Make the HEVC pass-through path ([plan 15](15-encoded-frame-ingest.md)) freeze-free enough to ship as default, *without* reintroducing the transcode image-quality tax — or decide, on evidence, that we can't, and fall back to a near-lossless re-encode. **Resolved 2026-05-28 → see Outcome.**

## Outcome (2026-05-28) — final decision

**Path A (in-app re-encode → H.265) is the default. Path B (pass-through relay) stays in the tree but flag-gated OFF (`Config.glassesEncodedIngest = false`). Plan 16's `EncodedFrameSmoother` is deleted (not preserved).**

How we got here:
- **Stage 1 fix worked.** The extractor change (parameter sets injected only at true IRAPs, not every frame) eliminated the PLI-deadlock: worst-freeze **3,068 → 411 ms**, **PLI sent = 0**, and we finally measured DAT's GOP at **2.93 s**. Pass-through is now *viable* — but its residual **catch-up jumps** (≤ one GOP ≈ 3 s; architectural — DAT exposes no keyframe control, [[dat-no-encoder-control]]) and higher latency remain.
- **Path A vs Path B A/B (both 504×896, matched).** Path A wins the *live* experience decisively: jb latency **107 vs 199 ms**, steady **30 vs 24 fps**, **3 vs 362** dropped frames, **no jumps**. Path B wins only on image sharpness.
- **The image tax is real but modest — and not a bitrate miss.** Re-encode published **1.54 Mbps with `quality_limitation: none`**: the 4 Mbps cap lifted it from the old 0.79 Mbps default, but the encoder *declined* the remaining headroom. The softness is **second-generation (tandem) coding loss** — NOT lost detail (both paths start from the glasses' identical gen-1 bits; pass-through just skips the second encode). Reducible in principle with more gen-2 bitrate, but the encoder won't spend it and WebRTC exposes no clean "force minimum bitrate" knob. Pass-through is therefore always ≥ re-encode on sharpness; the gap is one extra lossy generation, not a quality floor.
- **Decision rationale:** for a live POV feed, smoothness + low latency + a relay-free, simpler stack outweigh the modest softness. Keep Path B flag-gated for a possible future return (a quality-critical mode, or once native ingest + a stateful GOP-replay relay exist).

## Shipping checklist (this branch spans plans 15 + 16 + 17)

Branch `plan/15-encoded-frame-ingest`. Execute in order. Line numbers are approximate (they shift as you edit); the `rg` checks are the source of truth.

### Already done this session (in tree; built + smoke-tested on iPhone 17)
- `HEVCAnnexBExtractor.annexB()` — Stage 1 fix: parameter sets only at true IRAPs via `containsIRAP` (was every-frame). Validated on device (PLI=0, worst-freeze 411 ms).
- `Config.glassesEncodedIngest = false` — Path A is the default.
- `GlassesSource` re-encode publish — added `VideoEncoding(maxBitrate: 4_000_000, maxFps: 30)` (measured 1.54 Mbps actual, `quality_limitation: none`).
- Profiler: viewer records `pli_count` + `key_frames_decoded`; `scripts/compare-profile-runs.js` shows PLI / key-frames / GOP-length rows. General-purpose — keep.
- Builds clean (`BUILD SUCCEEDED`); Path A installed + smoke-tested on device.

### 1. Purge Plan 16 (`EncodedFrameSmoother`) — ✅ DONE 2026-05-28
Project uses Xcode **synchronized groups**, so deleting the file is sufficient — **no `.pbxproj` edit**. Did NOT touch `FrameSmoothingBuffer`/`smoother` (Plan 12, Path A) or `containsIRAP` (load-bearing for the Stage 1 fix).
- **Delete** `ios/WazaProto/WazaProto/EncodedFrameSmoother.swift`.
- **`Config.swift`** — remove the `glassesEncodedSmootherEnabled` constant + its comment (≈ lines 32–38). Keep `glassesSmoothingDepth`/`glassesSmoothingMaxDepth`.
- **`GlassesSource.swift`** — remove every `encodedSmoother` / `EncodedFrameSmoother` reference:
  - property decl `private var encodedSmoother: EncodedFrameSmoother?` (≈ line 29) and the setup-local (≈ line 48);
  - the `if Config.glassesEncodedSmootherEnabled { … } else { … }` block in the encoded-ingest setup (≈ lines 73–84) → collapse to the bypass case (start TCP server, no smoother);
  - the `encodedSmoother = es/nil` assignments (≈ lines 79, 82, 112);
  - in the frame closure (≈ lines 167–179) drop the `if let encodedSmoother { … push } else { tcpServer.send }` → keep only `tcpServer.send(bytes)` + `counters.recordCapturedFrame()`; remove the now-unused `isIDR`/`containsIRAP` call (≈ line 176) — `containsIRAP` stays defined in the extractor, just not called here;
  - teardown `encodedSmoother?.stop()` / `encodedSmoother = nil` (≈ lines 304–305) — keep `smoother?.drain()`/`smoother = nil`;
  - fix comments mentioning "plan-16 smoother" (≈ lines 80, 83, 167–168).
- **Verified:** `rg -n "[Ss]moother" ios/` shows only `FrameSmoothingBuffer`/`smoother` (Plan 12). Zero hits for `EncodedFrameSmoother`/`encodedSmoother`/`glassesEncodedSmootherEnabled`. Frame closure collapsed to `tcpServer.send(bytes)` + `recordCapturedFrame()`; `containsIRAP` kept in the extractor (no longer called from `GlassesSource`).

### 2. Rebuild + verify — ✅ DONE 2026-05-28
- `xcodebuild -project ios/WazaProto/WazaProto.xcodeproj -scheme WazaProto -configuration Debug -destination "generic/platform=iOS" -derivedDataPath .build/xcode-derived build` → **`BUILD SUCCEEDED`**. Reinstalled on iPhone 17.
- `glassesEncodedIngest` is a runtime `let` (not `#if`), so both branches type-check in one compile — this build verifies Path A (default) **and** Path B (flag-gated) compile. Live glasses runtime re-test deferred to Vincent (needs glasses donned).

### 3. Update plan docs — ✅ DONE 2026-05-28
- **Plan 17** (this file): findings + decision captured. Moved to `completed/`.
- **Plan 15** (`active/`): close Stage 2 — freeze root-caused (PLI deadlock) and *fixed* in pass-through (extractor), but **default ships as Path A (re-encode H.265 @ 4 Mbps cap)**; pass-through retained flag-gated. Drop the "gating before flipping encoded default" criteria (moot). Move to `completed/`.
- **Plan 16** (`completed/`): update "What's preserved in the tree" — `EncodedFrameSmoother.swift` is now **deleted** (Vincent chose not to keep it). `containsIRAP` survives, repurposed by Plan 17.
- **`plans/index.md`**: move 15 + 17 to Completed; refresh one-liners.

### 4. Path B known issues (tech debt; only block if Path B ever becomes default)
- **SIGSEGV on Ray-Ban accessory disconnect in encoded mode** (plan 15 Stage 2): frame closure fires with a torn-down `CMVideoFormatDescription`. Not triggered in Path A. Must guard before any Path-B default.
- **Watchdog misses `EAAccessory` disconnects** (pre-existing, plan 13 territory).
- **Residual catch-up jumps** (≤ GOP ≈ 3 s) — architectural; needs the deferred stateful GOP-replay relay (Stage 2) to fix.

### 5. Commit + ship
- Commit the branch (extractor fix, 4 Mbps, default flip, Plan 16 deletion, profiler additions, plan docs). Co-author line per repo convention.
- Open PR `plan/15-encoded-frame-ingest` → `main`; note it lands plans 15 (encoded ingest, flag-gated) + 16 (abandoned, code purged) + 17 (Path A default).

### Deferred / not now
- Path A image softness (tandem coding) — accepted; revisit only for a quality-critical mode.
- Path A CPU/thermal (2× codec; starves DAT ~6 fps under stress) — monitor for backgrounded long sessions (plan 07 regime).
- Absolute glass-to-render latency instrumentation (plan 15 §5 #5) — still deferred.
- Forcing higher gen-2 bitrate / Mac-side re-encode — uncertain payoff, awkward knob; only if softness becomes a problem.

## The problem, stated precisely

Vincent never experienced a freeze on the pre-plan-15 transcode path in months of testing. The profiler counted 12–28 "freeze events" on re-encode, but those were sub-second stutters the plan-12 smoother masked. The **multi-second "frozen until browser refresh" freezes are new to pass-through** ([encoded-ingest-ab.md §4](../features/encoded-ingest-ab.md#4-stressed-regime-ab-2026-05-28-morning-504896): encoded 3,068 ms worst vs re-encode 331 ms).

Root cause (confirmed [plan 16](../completed/16-encoded-smoother.md), corroborated by research this session): **PLI deadlock.** When a viewer's decoder loses a reference frame it sends a Picture Loss Indication. The SFU forwards it upstream and keeps *no* keyframe cache for existing subscribers — recovery depends entirely on the viewer latching onto the next *natural* IDR. The transcode path was freeze-free because its in-app encoder answered every PLI with an immediate fresh IDR. Pass-through deleted the only element in the path that can manufacture a keyframe on demand.

## The hard constraint that shapes everything (new this session)

**DAT 0.7.0 exposes zero control over the glasses encoder.** Reverse-engineering the `MWDATCamera.framework` binary: `StreamConfiguration` has exactly three fields — `videoCodec` (`.raw`/`.hvc1`), `resolution` (`.high`/`.medium`/`.low`), `frameRate` (UInt). No keyframe interval, no GOP, no bitrate, no force-IDR. The binary carries a dead stub string `[FIXME] EncodedVideoSource not set. Keyframe request ignored.` — Meta's own keyframe-request path is non-functional. No issue/discussion requests it; thread #199 got "it's Bluetooth Classic transport behavior" and nothing on encoder knobs.

This **eliminates the two cleanest fixes** plan 16 sketched:
- ~~Force higher IDR cadence on DAT~~ — no API.
- ~~Request IDR on demand from DAT~~ — no API, stubbed even internally.

And it means **native LiveKit Swift ingest (rust-sdks#1048) would not fix freezes either.** That PR is still an unmerged draft (stalled on LiveKit's product-review process; no Swift port started). I read its branch source: `PassthroughVideoEncoder` answers a keyframe request by calling `on_keyframe_requested()` up to the app **and nothing else** — with no encoder on the iPhone, the app can't satisfy it. Native ingest relocates the deadlock on-device; it doesn't close it. (Its parameter-set auto-prepend logic *is* worth borrowing — see Stage 1.)

## The remaining levers (research-backed)

Every robust pass-through answer the industry uses requires source-encoder control (locked away) or an in-path re-encoder (defeats the purpose). What's actually left to us:

1. **Make the viewer self-heal on the next natural IDR.** A browser *does* recover on the next keyframe — **unless that keyframe isn't recognized as a valid HEVC sync point.** HEVC keyframe recognition is documented-fragile: the browser's `H26xPacketBuffer` requires VPS present (`HasVps()`), params co-timestamped with the IDR, and correct AP/FU packetization; the SFU's `IsH265KeyFrame` keys on SPS/PPS NAL types (33/34). **Our `HEVCAnnexBExtractor` deviates from spec today**: keyframe detection uses `kCMSampleAttachmentKey_NotSync`, which defaults to `true` for DAT samples (they carry no attachments), so it prepends VPS/SPS/PPS to *every* frame. Params-on-every-frame is exactly the pattern shown to make Chrome loop on PLIs and never re-sync (koush/scrypted commit e6eb61f). **Cheap to fix, directly testable, and it targets the "until refresh" symptom head-on.**

2. **Stateful relay that answers PLI by replaying the last GOP.** `server-sdk-go` exposes `ReaderTrackWithRTCPHandler` — a custom Go relay *can* observe incoming PLIs (lk-cli's `ReaderSampleProvider` just ignores them). On PLI, replay the buffered current GOP (IDR + all P-frames since, re-stamped to current RTP time). This is the only architecture that keeps *true* pass-through and answers PLI. Caveats are real: IDR-only replay is **confirmed broken** (P-frames reference the previous frame, not the IDR — LiveKit ingress #226, mediasoup #232); you must replay the whole GOP-so-far, which renders as a brief fast-forward burst; MediaMTX's equivalent PR (#4189) has sat unmerged ~1 year on player-compat edge cases. Medium-to-high effort, imperfect recovery UX, but preserves zero-transcode quality.

3. **Pragmatic hedge: near-lossless re-encode, freeze-free by construction.** The shipped re-encode path is *already* H.265→raw→H.265 (`preferredCodec: .h265`, no explicit bitrate cap) — the ugly H.264-at-0.79 Mbps you remember from before Stage 0 is gone. The residual quality tax is now just **one H.265 generation + LiveKit's default bitrate budget**. Raise the publish bitrate (and/or push the transcode to the Mac so the iPhone stops contending with the DAT listener thread — §4d.1 showed re-encode starves DAT by ~6 fps under stress) and the second-generation loss shrinks toward visually-imperceptible, while the encoder keeps answering PLIs → no multi-second freezes. Lowest risk; gives up "literally zero transcode" for "no *visible* tax."

## Plan — cheapest, highest-information experiment first

### Stage 1 — Bytestream correctness + measure natural-IDR recovery

The bet: the "frozen until refresh" symptom is the viewer failing to *recognize* the next natural IDR, not a terminal WebRTC state. If true, fixing the stream to emit spec-clean IDRs converts "frozen forever" into "freezes for ≤ one GOP, then self-heals" — and if DAT's GOP is short, that may already be acceptable.

Tasks:
1. **Fix keyframe detection + parameter-set injection** in `HEVCAnnexBExtractor` — ✅ **landed 2026-05-28 (untested on device pending capture).** `annexB(from:)` now converts the HVCC body to Annex-B first, then prepends VPS+SPS+PPS **only when `containsIRAP(annexB:)` finds a true IRAP NAL (type 16..23)**, co-timestamped in the same access unit. Removed the always-true `isKeyframe(sampleBuffer:)`/`NotSync` heuristic that was injecting parameter sets on every frame. All three parameter sets come from `CMVideoFormatDescription` (already cached). This is the actual hypothesized fix.
2. **Build + capture on device (Vincent).** Build with `Config.glassesEncodedIngest = true`, run the standard 3-min paired profile (`scripts/run-paired-profile.sh` → `node scripts/compare-profile-runs.js profiler/`). The viewer profiler + comparison table now record the two diagnostics automatically (added 2026-05-28) — no manual `chrome://webrtc-internals` reading needed:
   - **`GOP length (s, ≈)`** — derived from `keyFramesDecoded` rate; this *is* DAT's IDR cadence, the number we never captured directly. Bounds the best-case worst-freeze of any self-healing approach.
   - **`PLI sent (total)`** + **`key frames decoded (total)`** — the deadlock signature. High PLI with stalled keyframes = still deadlocking; PLIs followed by keyframe decodes (and `worst freeze ms` dropping toward re-encode's ~331–703 ms) = the fix works and the viewer self-heals.
3. **Optional control test** (deferred from plan 15): steady file source with a known short GOP through the same relay+SFU+browser. If smooth, relay/SFU are proven innocent and the issue is purely the glasses bytestream.

**Decision gate:** if the corrected stream lets the viewer self-recover within ~one GOP and worst-freeze lands near re-encode's (≈0.3–0.7 s), ship pass-through as default — best outcome, full quality retained. If freezes are still multi-second or non-recovering → Stage 2′ (near-lossless re-encode hedge).

Effort: extractor edit done; remaining is one build + one capture session.

### Stage 2 — Stateful Go relay with PLI-triggered GOP replay (DEFERRED — see decision below)

**Deferred 2026-05-28:** Vincent's quality bar is "no *visible* tax," not "literally zero transcode" — so the weeks-of-effort relay with its fast-forward recovery artifact is not worth it when the near-lossless re-encode hedge clears the same bar at a fraction of the cost. Kept here as the "someday, if we ever need true zero-transcode" path. Pursue only if Stage 1 falls short *and* a future requirement makes zero-transcode mandatory again.

- Replace `lk room join --publish h265://` with a small `server-sdk-go` service. Register `lksdk.ReaderTrackWithRTCPHandler`; on `*rtcp.PictureLossIndication`, replay the buffered GOP (cached VPS/SPS/PPS + last IDR + all subsequent P-frames, in order, re-stamped to current RTP time with monotonic sequence numbers), then resume live forwarding. Rate-limit replays (≥1/s or 2×RTT) per GStreamer/mediasoup convention.
- Buffer bounded à la MediaMTX `maxCachedGOPSize` (cap packets, fall back to next-natural-IDR if a GOP overruns).
- Accept the fast-forward catch-up burst on recovery; document it. This is the known cost of the only true-pass-through fix.
- Forward-compatible: when/if native Swift ingest ships, this same GOP-replay logic moves on-device behind the `EncodedVideoTrackSource` API.

Effort: medium-high. New Go service, RTP timestamp/seq surgery, player-compat testing.

### Stage 2′ (the chosen fallback) — near-lossless re-encode

**This is the fallback, per the 2026-05-28 decision.** Pursue if Stage 1 doesn't clear the freeze bar. Largely independent of Stage 1; can be spiked in an afternoon.

- Set an explicit high `VideoEncoding` bitrate on the re-encode publish path (currently unset → LiveKit default). Target enough headroom that H.265→H.265 second-gen loss is imperceptible at the held resolution.
- A/B the higher-bitrate re-encode vs pass-through on a fixed scene: is the quality gap still visible? If not, the freeze-free re-encode path *is* the answer and pass-through becomes a "someday, when native ingest + DAT keyframe control exist" deferral.
- Optional escalation: move the transcode to a Mac-side relay (decode HEVC → re-encode H.265 at high bitrate) — frees the iPhone from DAT-listener contention (recovers the ~6 fps re-encode loses under stress, §4d.1) and keeps PLI responsiveness. More infra than the bitrate bump; only if the iPhone-side bump leaves a gap.

## Out of scope

- DAT encoder control / keyframe API — does not exist in 0.7.0; would be a net-new feature request to Meta.
- Native LiveKit Swift encoded ingest as a *freeze* fix — relocates the deadlock, doesn't close it. Watch rust-sdks#1048 for the latency/architecture win only.
- Carrier/NAT mobility, simulcast — inherited from plan 15's out-of-scope.

## Risks and unknowns

- **Stage 1 may not be enough.** The bet is "recognition bug, not terminal state." Task 3 (webrtc-internals capture) settles it fast and cheap; if it's terminal, we know before investing in extractor polish.
- **DAT GOP may be long (up to ~4 s).** If so, even perfect self-heal leaves multi-second worst-freezes — Stage 1 alone won't clear the bar, pushing to Stage 2 or the hedge. Task 1 tells us up front.
- **Stage 2 GOP-replay UX.** Fast-forward burst + possible audio desync on recovery. Acceptable vs frozen-until-refresh, but not invisible. MediaMTX's year-long struggle is the cautionary tale.
- **Single-stream H.265 publish is freshly added / under-tested** (livekit-cli#837: empty `TrackPublicationOptions` can leave H.265 "muted forever"). If a Stage-2 custom relay hits zero-forwarding, publish as a 1-layer simulcast track to populate codec metadata. Rule this out before chasing decoder freezes.
- **Hedge gives up the purist goal.** "No visible tax" ≠ "zero transcode." Vincent's call (see question below).

## Key decisions

- **Attack in cost order, gated on evidence.** Stage 1 is a day and could change everything; Stage 2 is weeks and uncertain; the hedge is an afternoon and low-risk. Front-load the cheap high-information experiment.
- **DAT lockout is load-bearing and permanent (for 0.7.0).** Every plan that assumed we could influence IDR cadence is dead. Documented here so we stop re-proposing it.

## Decisions logged during implementation

- **Quality bar = "no *visible* tax", not "zero transcode" (2026-05-28).** Vincent's call. Consequence: the heavy Stage-2 Go relay is deferred indefinitely; the near-lossless re-encode (Stage 2′) is the chosen fallback if Stage 1 falls short. Stage 1 still runs first because if it works we keep zero-transcode for free.
- **Stage 1 fix VALIDATED — PLI-deadlock eliminated (2026-05-28, viewer-only capture `profiler/2026-05-28T20-28-12Z-glasses-a-viewer.jsonl`).** One 3-min stressed run (24 fps inbound, 362 drops — the most-stressed of the day) with the IRAP-gated parameter-set fix: **worst-freeze 411 ms vs unfixed encoded's 3,068 ms (stressed) / 1,864–3,044 ms (lucky) — a ~7.5× collapse, landing at re-encode's 331 ms.** **PLI sent = 0** (the deadlock mechanism requires PLIs) is mechanistic proof the decoder no longer enters the lost-reference state — the malformed-keyframe hypothesis was correct. **GOP length measured at 2.93 s** (first direct measurement of DAT's IDR cadence). Freeze *count* stayed ~31 (vs re-encode 12): pass-through still lacks plan-12's input smoother, so brief DAT-burst stutters remain — but they're short recoverable gaps now, not deadlocks.
- **New residual artifact: GOP-bounded catch-up jumps (2026-05-28).** Vincent's subjective read: "much smoother, freezes much less, but sometimes suddenly jumps to a completely different frame." This is the *recovery working* — on a lost reference the decoder now resyncs at the next natural IDR (≤2.93 s) instead of freezing until refresh; the jump = the head-motion skipped during that stall. Two dials: jump **size** = GOP length (2.93 s, not shrinkable — [[dat-no-encoder-control]]); jump **frequency** = frame-drop rate (tunable via viewer-side jitter-buffer / playout-delay depth, trading latency for continuity). 
- **Caveat: jb_per_frame rose to 198.8 ms** (vs ~121–128 on the other two). Partly the harder regime, partly buffering to ride gaps without PLI. Still sub-second; relevant because the obvious jump-mitigation (deeper playout buffer) pushes it higher.
- **Path A vs Path B A/B, matched 504×896 (2026-05-28).** Captures: Path A `profiler/ios-2026-05-28T21-29-57Z.jsonl` + `…21-32-29Z-…-viewer.jsonl` (paired); Path B `…20-28-12Z-…-viewer.jsonl`. Path A re-encode (H.265, `glassesSmoothingDepth=2`): jb **107 ms**, inbound **30 fps**, **3** dropped, freezes 24/401 ms in a *stressed* regime (buffer underrun 23.2%) — an earlier good-regime Path A run was **0 freezes / 169 ms / jb 55 ms**. Path B pass-through: jb 199 ms, 24 fps, 362 dropped, 31/411 ms, plus the jumps. Path A is the better live experience on every axis except sharpness.
- **Bitrate finding — the 4 Mbps cap is a ceiling the encoder declines (2026-05-28).** Re-encode published **1.54 Mbps, `quality_limitation: none`**. The cap lifted it from the SDK's old 0.79 Mbps default-for-504×896 (~2×) but the encoder voluntarily stopped well below 4 Mbps and was *not* bandwidth/CPU-constrained. So raising the cap further is a no-op on this content.
- **Corrected mechanism — tandem coding, not a "lost-detail floor" (2026-05-28).** Earlier framing ("the glasses threw the detail away, can't resurrect it") was **wrong** as an A-vs-B explanation: both paths start from the glasses' identical gen-1 encode. The only difference is Path A's **second encode generation** (gen-2). The softness is gen-2 tandem-coding loss (re-quantizing decoded-already-compressed video on a shifted grid, with real-time fast settings). It is reducible in principle with more gen-2 bitrate (at the limit Path A → Path B), so it's **not a permanent floor** — but the encoder won't spend the bits and there's no clean WebRTC min-bitrate knob, so it's "hard to shrink with available knobs," and pass-through stays ≥ re-encode on sharpness.
- **FINAL: Path A is the default; Path B flag-gated; Plan 16 deleted (2026-05-28).** Vincent's call after seeing the A/B live: the snappiness + half-latency + no-jumps + relay-free simplicity outweigh the modest softness for a live POV feed. Keep Path B in the tree behind `glassesEncodedIngest=false` (might revisit). Purge `EncodedFrameSmoother` (Plan 16) entirely — see Shipping checklist §1.

## Status

**Resolved 2026-05-28.** Stage 1 fix landed + validated on device (PLI deadlock eliminated). Path A vs Path B A/B run; **Path A (re-encode H.265 @ 4 Mbps cap) chosen as the default**, Path B kept flag-gated, Plan 16 purged. See Outcome + Decisions logged.

**Ship progress** (see [Shipping checklist](#shipping-checklist-this-branch-spans-plans-15--16--17)): §1 purge Plan 16 ✅, §2 rebuild + reinstall ✅, §3 plan docs ✅ (this commit), §4 Path B known issues logged as tech debt ✅. Remaining: §5 commit + open PR `plan/15-encoded-frame-ingest` → `main`. Outstanding human step: live glasses re-test of Path A default on device (build is installed and ready).

## References

- [plan 15 — encoded-frame ingest](15-encoded-frame-ingest.md), [encoded-ingest-ab.md §4](../features/encoded-ingest-ab.md)
- [plan 16 — encoded smoother (abandoned, PLI-deadlock finding)](../completed/16-encoded-smoother.md)
- Research synthesis (chat 2026-05-28): DAT framework binary `StreamConfiguration`; LiveKit SFU `downtrack.go` PLI-upstream + no-cache; `server-sdk-go` `ReaderTrackWithRTCPHandler`; rust-sdks#1048 `PassthroughVideoEncoder` keyframe-request punt; WebRTC `H26xPacketBuffer::BeginningOfStream` VPS requirement; koush/scrypted Chrome HEVC PLI-storm; MediaMTX #4189 GOP-replay; LiveKit ingress #226 reference-chain; mediasoup #232.
