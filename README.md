# Waza Proto

End-to-end prototype: live POV video from Ray-Ban Meta glasses to a remote browser, sub-second latency, on owned infrastructure (no RTMP/HLS in the path).

The streaming pipeline is the load-bearing piece and may be a useful reference for anyone building POV streams off Ray-Ban Meta.

## Architecture

```
Ray-Ban Meta Gen 2
        │ Bluetooth Classic (Meta WDAT SDK)
        ▼
iPhone app (Swift, LiveKit Swift SDK)
        │ WebRTC over UDP, sub-second
        ▼
LiveKit Cloud (signaling + SFU + STUN + TURN)
        │ WebRTC over UDP
        ▼
Browser viewer on Mac (LiveKit JS SDK + plain HTML)
```

Someone wearing the glasses moves around; a laptop in another room shows the POV feed at <500 ms latency. That's it.

## Prerequisites

- Wearables Developer Center account + registered app. Self-serve at <https://wearables.developer.meta.com/>. SDK itself is public on SPM: <https://github.com/facebook/meta-wearables-dat-ios>.
- Apple Developer account ($99/yr) — only needed for background streaming or TestFlight. Free Apple ID sideloading via Xcode is enough for foreground-only dev.
- Xcode (latest stable) on Mac.
- LiveKit Cloud account (free tier covers prototype traffic).
- Ray-Ban Meta Gen 2 paired with an iPhone running iOS 17+.

## Build ladder

The repo is organized around staged validation — each step exercises one slice of the pipeline so failures are localized. Implementation notes for each step live in [`plans/completed/`](plans/completed/); the [plans index](plans/index.md) is the progressive-disclosure summary.

1. **LiveKit Cloud setup.** Project, URL, API key + secret.
2. **Browser viewer with hardcoded JWT.** Plain HTML + LiveKit JS via CDN, subscribes to a hardcoded room.
3. **Test publisher via `livekit-cli`.** Confirms the subscriber path before any native code.
4. **iOS shell publishing the iPhone front camera** via LiveKit Swift SDK. No WDAT yet.
5. **Glasses frames via WDAT** in place of the front camera. WDAT's `videoFramePublisher` callback feeds LiveKit's `BufferCapturer`; HEVC is decoded in-app via `VTDecompressionSession` so LiveKit's H.264 encoder can take over.
6. **Shareable viewer link** with per-invite HS256 token mint, deployed at `waza-proto.vercel.app`.
7. **Background streaming.** Keeps publishing while the iPhone app is backgrounded or screen-locked.
8. **Local test suite.** Vitest + XCTest + XCUITest + Playwright; one `just test` runs all tiers.
9. **App icon.**
10. **Publisher JWT minted at connect time.** Long-lived JWT in `Secrets.swift` replaced with on-demand mint via `/api/publisher-token`, gated by HS256 signing seeds.
11. **Video-quality profiling.** End-to-end JSONL profiler (publisher + viewer) that pinpointed the BT-cadence root cause; see the featured write-up at the top of this README.

## Testing

Locally-runnable test suites grow one tier per stage of [plan 08](plans/completed/08-test-suite.md). Stage status drives this list — each stage adds one line.

With [`just`](https://github.com/casey/just) installed (`brew install just`), `just test` runs all four tiers and prints a pass/fail/duration summary; `just --list` shows the per-tier recipes (`test-unit`, `test-e2e`, `test-ios-unit`, `test-ios-ui`). `just test-detail` runs everything in verbose mode and emits a per-test catalog grouped by tier, with a one-line description of what each tier verifies. The raw commands below are what each recipe runs.

- `cd viewer && npm test` — Vitest unit tests for the Vercel token-mint + room-lifecycle APIs (`viewer/api/{viewer-token,publisher-token,close-room,coach-dispatch}.js`). Covers envelope verification, JWT minting (grants + TTL), per-session room create/delete, the closed-session re-entry gate, missing-env behavior, and identity collision-resistance. ~200 ms.
- `cd viewer && npm run test:e2e` — Playwright end-to-end test for the browser viewer. Creates a per-run session room (`waza-proto-e2e<ts>`; auto-create is off in prod, so the room is created explicitly — see [plan 23](plans/active/23-room-close-on-disconnect.md)), spawns `lk room join --publish` into it with a generated H.264 test pattern, serves `viewer/index.html` + the local token endpoint on `http://localhost:4173`, opens the page in system Chrome (not Playwright's vendored Chromium — that ships without H.264 codec support and silently drops the subscribed track), asserts the `<video>` element receives non-zero dimensions, then deletes the room. ~10 s. Requires repo-root `.env` (`LIVEKIT_*`, `INVITE_SIGNING_SECRET`), and `lk` CLI installed. First-run setup: `cd viewer && npm install && npx playwright install chrome`.
- iOS suite — two `xcodebuild test` commands, scoped with `-only-testing` so each tier reports separately. The shared scheme at `WazaProto.xcodeproj/xcshareddata/xcschemes/WazaProto.xcscheme` includes both `WazaProtoTests` and `WazaProtoUITests`, so a single bare `xcodebuild test` would run everything in one bundle — the split below is for cleaner per-tier accounting (matches `just test`'s tiers). From `ios/WazaProto/`:
  ```
  xcodebuild test -project WazaProto.xcodeproj -scheme WazaProto \
    -destination 'platform=iOS Simulator,name=iPhone 17' \
    -parallel-testing-enabled NO -only-testing:WazaProtoTests
  xcodebuild test -project WazaProto.xcodeproj -scheme WazaProto \
    -destination 'platform=iOS Simulator,name=iPhone 17' \
    -parallel-testing-enabled NO -only-testing:WazaProtoUITests
  ```
  The first runs `WazaProtoTests` (Secrets shape validation, `PublisherTokenClient` HS256 envelope, `RoomConnection.Status` equality + labels, viewer-identity filter helper, MockDeviceKit smoke test). The second runs `WazaProtoUITests` (launches the app with `--ui-testing`, drives Meta's Mock Device test server, asserts the SwiftUI Connect button enables once the mock pair propagates). Requires `Secrets.swift` — run `./scripts/refresh-secrets.sh` first on a fresh checkout; the script reads `INVITE_SIGNING_SECRET` and `PUBLISHER_SIGNING_SECRET` from repo-root `.env` (generate each with `openssl rand -hex 32`, also add to Vercel project env). The script no longer mints a LiveKit JWT — the app fetches one from `/api/publisher-token` at connect time. `-parallel-testing-enabled NO` keeps tests on the explicitly-booted simulator; cloned-simulator parallel runs have been flaky on iOS 26.5.

## Profiling

The glasses feed jitters and stutters where the iPhone front camera doesn't. To measure (rather than guess) where the divergence lives, the project ships a paired-run profiler that captures one second of stats per side per window across the LiveKit boundary and inside `GlassesSource`. Full design + findings: [plan 11](plans/completed/11-video-quality-profiling.md). Headline writeup: [jitter root-cause analysis](plans/docs/glasses-stream-jitter-analysis.md). Fix shipped: [plan 12 — glasses smoothing buffer](plans/completed/12-glasses-smoothing-buffer.md). Sweep write-up: [docs/glasses-stream-buffer-sweep.md](plans/docs/glasses-stream-buffer-sweep.md).

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
node scripts/analyze-video-quality.js                  # all runs in profiler/
node scripts/analyze-video-quality.js profiler/<file>  # specific files
```

The analyzer prints a comparison table grouping runs by `source × side` with median sent/received fps, total dropped/freeze counts, worst freeze gap, per-frame jitter-buffer delay, and publish-stall window count.

## What this prototype doesn't cover

- Audio from viewer back to publisher (one-way video only).
- Live translation, recording, multi-party rooms.
- Annotations or overlays rendered into the wearer's lens — WDAT does not expose HUD output on any Meta glasses model, including the Display.

The point is to validate one thing — the one-way POV stream on owned infrastructure — and nothing else.

## References

- Meta Wearables Device Access Toolkit (developer preview): <https://developers.meta.com/horizon/develop/wearables/>
- LiveKit Cloud: <https://livekit.io>
- LiveKit Swift SDK: <https://github.com/livekit/client-sdk-swift>
- LiveKit JS SDK: <https://github.com/livekit/client-sdk-js>

## License

MIT — see [LICENSE](LICENSE).
