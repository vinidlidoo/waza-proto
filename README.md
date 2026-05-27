# Waza Proto

Smallest possible end-to-end demonstration that the Waza streaming architecture works: live POV video from Ray-Ban Meta glasses to a remote browser, sub-second latency, on our own infrastructure.

This is the **v0.05** rung on the Waza experiment ladder — a step between v0.0 (WhatsApp POV proof) and v0.1 (translation overlay). The goal is to retire WhatsApp from the loop and own the streaming stack end-to-end.

## What we're building

```
Ray-Ban Meta Gen 2
        │ Bluetooth Classic (Meta WDAT SDK)
        ▼
iPhone app (Swift, uses LiveKit Swift SDK)
        │ WebRTC over UDP, sub-second
        ▼
LiveKit Cloud (signaling + SFU + STUN + TURN)
        │ WebRTC over UDP
        ▼
Browser viewer on Mac (LiveKit JS SDK + plain HTML)
```

A learner wearing the glasses moves around the kitchen. A laptop in another room shows the POV feed at <500ms latency. That's it.

## Why this architecture

- **WebRTC, not RTMP.** RTMP → HLS = 10–20s glass-to-pixel. Fatal for the correction loop Waza needs. The Streamhand-style path was evaluated and rejected for this reason.
- **LiveKit, not pure P2P.** Skips writing signaling, STUN, TURN, and the SFU ourselves. Free tier covers prototype traffic.
- **iOS first (not Android).** WDAT preview SDK shipped on iOS; Android support reportedly less mature as of early 2026.

## Prerequisites

- [x] Wearables Developer Center account + registered app. Self-serve at <https://wearables.developer.meta.com/>. SDK itself is public on SPM (<https://github.com/facebook/meta-wearables-dat-ios>).
- [ ] Apple Developer account ($99/yr). **Defer until step 4** — free Apple ID sideloading via Xcode is likely enough for foreground-only dev. Pay only if WDAT SDK requires a paid provisioning profile, or once background operation is needed.
- [x] Xcode (latest stable) on Mac.
- [x] LiveKit Cloud account (free tier).
- [x] Ray-Ban Meta Gen 2 paired with personal iPhone running iOS 17+.

## Build ladder

Order chosen so each step validates one slice of the pipeline. If something breaks, the failure is localized.

1. **Set up LiveKit Cloud.** Create project, copy URL + API key + secret. ~10 min.
2. **Browser viewer with hardcoded JWT.** Plain HTML, LiveKit JS SDK via CDN. Subscribes to a hardcoded room name, attaches any incoming video to a `<video>` element. JWT minted locally via CLI script. ~1 hour.
3. **Test viewer with LiveKit CLI's fake publisher.** `livekit-cli` ships a "publish a test pattern" command. Confirms the subscriber path works before any iOS code. ~30 min.
4. **iOS shell with LiveKit Swift SDK, publishing the iPhone's built-in front camera.** Confirms iOS publish path, token mint, and end-to-end view in the browser. *No WDAT yet.* ~2–3 hours.
5. **Swap iPhone front camera for WDAT glasses frames.** Wire WDAT's frame callback into LiveKit's custom video source (`RTCVideoSource`). Pixel format conversion is the load-bearing piece — likely `kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange` → `RTCVideoFrame`. ~4–8 hours, depending on WDAT SDK ergonomics.

## Testing

Locally-runnable test suites grow one tier per stage of [plan 08](plans/completed/08-test-suite.md). Stage status drives this list — each stage adds one line.

With [`just`](https://github.com/casey/just) installed (`brew install just`), `just test` runs all four tiers and prints a pass/fail/duration summary; `just --list` shows the per-tier recipes (`test-unit`, `test-e2e`, `test-ios-unit`, `test-ios-ui`). `just test-detail` runs everything in verbose mode and emits a per-test catalog grouped by tier, with a one-line description of what each tier verifies. The raw commands below are what each recipe runs.

- `cd viewer && npm test` — Vitest unit tests for the Vercel token-mint API (`viewer/api/token.js`). Covers invite verification, JWT minting, missing-env behavior, and identity collision-resistance. ~200 ms.
- `cd viewer && npm run test:e2e` — Playwright end-to-end test for the browser viewer. Spawns `lk room join --publish` against the `waza-proto` room with a generated H.264 test pattern, serves `viewer/index.html` + the local token endpoint on `http://localhost:4173`, opens the page in system Chrome (not Playwright's vendored Chromium — that ships without H.264 codec support and silently drops the subscribed track), asserts the `<video>` element receives non-zero dimensions. ~10 s. Requires repo-root `.env` (`LIVEKIT_*`, `INVITE_SIGNING_SECRET`), and `lk` CLI installed. First-run setup: `cd viewer && npm install && npx playwright install chrome`.
- iOS suite — two `xcodebuild test` commands, scoped with `-only-testing` so each tier reports separately. The shared scheme at `WazaProto.xcodeproj/xcshareddata/xcschemes/WazaProto.xcscheme` includes both `WazaProtoTests` and `WazaProtoUITests`, so a single bare `xcodebuild test` would run everything in one bundle — the split below is for cleaner per-tier accounting (matches `just test`'s tiers). From `ios/WazaProto/`:
  ```
  xcodebuild test -project WazaProto.xcodeproj -scheme WazaProto \
    -destination 'platform=iOS Simulator,name=iPhone 17' \
    -parallel-testing-enabled NO -only-testing:WazaProtoTests
  xcodebuild test -project WazaProto.xcodeproj -scheme WazaProto \
    -destination 'platform=iOS Simulator,name=iPhone 17' \
    -parallel-testing-enabled NO -only-testing:WazaProtoUITests
  ```
  The first runs `WazaProtoTests` (Secrets shape validation, `RoomConnection.Status` equality + labels, viewer-identity filter helper, MockDeviceKit smoke test). The second runs `WazaProtoUITests` (launches the app with `--ui-testing`, drives Meta's Mock Device test server, asserts the SwiftUI Connect button enables once the mock pair propagates). Requires `Secrets.swift` (run `./scripts/refresh-secrets.sh` first on a fresh checkout). `-parallel-testing-enabled NO` keeps tests on the explicitly-booted simulator; cloned-simulator parallel runs have been flaky for us on iOS 26.5.

## Profiling

The glasses feed jitters and stutters where the iPhone front camera doesn't. To measure (rather than guess) where the divergence lives, the project ships a paired-run profiler that captures one second of stats per side per window across the LiveKit boundary and inside `GlassesSource`. Full design + findings: [plan 11](plans/completed/11-video-quality-profiling.md). Tracked fix: [glasses smoothing buffer](plans/features/glasses-smoothing-buffer.md).

Run a paired profile (3-min front-camera + 3-min glasses, back-to-back, same room/network):

```sh
./scripts/run-paired-profile.sh
```

The wrapper builds + installs the iOS app, starts the local viewer server on `:4173`, mints an invite URL, opens the browser, captures iOS stdout JSONL into `profiler/`, and prints an analyzer summary table when you Ctrl-C out. Pass `DEVICE_ID=<udid>` if device autodetect picks the wrong target; pass `SKIP_BUILD=1` to skip the rebuild/reinstall.

What gets measured (one JSON object per second per side, schema in plan 11):

- **iOS publisher** — outbound width/height/fps, frames encoded, bitrate, WebRTC `qualityLimitationReason`, remote packet-loss/jitter/RTT (from LiveKit `TrackStatistics`). On the glasses path, also: DAT callback fps, inter-frame gap p50/p95/max, decoder rebuilds, decode errors, decoded frames, frames handed to `BufferCapturer`.
- **Browser viewer** — inbound width/height/fps, frames decoded, frames dropped, jitter, freeze events >150 ms, worst freeze gap (from `getRTCStatsReport()` + `requestVideoFrameCallback`).

Output files land in `profiler/` (gitignored), named `ios-<UTC>.jsonl` and `<UTC>-<source>-<a/b/c>-viewer.jsonl` and keyed by a shared `run_id`. Re-aggregate any time:

```sh
node scripts/analyze-video-quality.js                 # all runs in profiler/
node scripts/analyze-video-quality.js profiler/<file>  # specific files
```

The analyzer prints a comparison table grouping runs by `source × side` with median sent/received fps, total dropped/freeze counts, worst freeze gap, and publish-stall window count.

## Open questions

- **WDAT frame format and surface.** Does the iOS WDAT SDK hand frames as `CMSampleBuffer`, `CVPixelBuffer`, or something else? What pixel format? At what cadence?
- **Audio path back to learner.** WDAT exposes the glasses speakers as a standard Bluetooth headset. iOS audio session config is a separate concern from LiveKit; needs to be wired up so the guide's voice plays through the glasses. Not in scope for v0.05 (one-way video only), but mark for v0.06.
- **Resolution and bitrate trade-off.** WDAT caps at 720×1280 portrait @ 30fps; LiveKit will adapt bitrate per subscriber. Worth measuring what knife-angle detail actually survives the pipeline.

## Out of scope (deliberately)

- Audio back from guide to learner. (v0.06)
- Live translation. (v0.1)
- Recording. (v0.2 via LiveKit egress)
- Annotations or overlays rendered into the learner's lens. (WDAT does not expose HUD output on any model, including the Display.)
- Multi-party rooms. (v0.2)

The point of v0.05 is to validate one thing — the one-way POV stream on our own infra — and nothing else.

## References

- Waza brief: [Live, hands-on tutoring through smart glasses](https://github.com/vinidlidoo/protos/blob/main/Waza%20%E2%80%94%20Live,%20hands-on%20tutoring%20through%20smart%20glasses.md)
- Meta Wearables Device Access Toolkit (developer preview): <https://developers.meta.com/horizon/develop/wearables/>
- LiveKit Cloud: <https://livekit.io>
- LiveKit Swift SDK: <https://github.com/livekit/client-sdk-swift>
- LiveKit JS SDK: <https://github.com/livekit/client-sdk-js>
- Streamhand (RTMP-based alternative evaluated and rejected): <https://thestreamhand.com/guides/meta-glasses>
