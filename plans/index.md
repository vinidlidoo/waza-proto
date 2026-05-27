# Plans index

Progressive-disclosure summary of architectural plans. One line per plan with a link.

- [Features roadmap](features.md) — forward-looking ideas surfaced during implementation that don't belong in the current rung.

## Active

_(none)_

## Completed

- [11 — Video quality profiling](completed/11-video-quality-profiling.md) — staged profiler that started with LiveKit sender/receiver/playout stats, then added glasses DAT/decode counters. Stage 2 + Meta-docs verification + `.medium` config sweep proved BT Classic delivery cadence (median 23.8 fps, bursts to 49 fps, stalls to 695 ms) is the root cause of glasses stutter; lowering the requested resolution made things worse (encoder drops doubled). Fix split out as [features/glasses-smoothing-buffer.md](features/glasses-smoothing-buffer.md).
- [08 — Automated test suite (local)](completed/08-test-suite.md) — cross-cutting infra (not a build-ladder rung). Five staged tiers, all locally-runnable: Vercel token-mint (Vitest), iOS pure-logic XCTest, iOS XCTest against Meta's MockDeviceKit, iOS XCUITest via MDK's test server, browser viewer Playwright + `lk` publisher. Stages 3 and 4 re-scoped to smoke-only after empirical finding that `stream.videoFramePublisher` doesn't fire under MDK on iOS 26.5 sim — upstream issue [#197](https://github.com/facebook/meta-wearables-dat-ios/issues/197). CI integration tracked separately in [features/ci-integration.md](features/ci-integration.md).
- [07 — Background streaming (glasses path)](completed/07-background-streaming.md) — iPhone keeps publishing the glasses POV while the app is backgrounded or the screen is locked. Required four load-bearing knobs in concert: `UIBackgroundModes` (`audio` + Meta's BLE/MFi modes), `RoomOptions(suspendLocalVideoTracksInBackground: false)`, a published mic track to activate `AVAudioSession`, and a codec swap to `VideoCodec.hvc1` + in-app `VTDecompressionSession` with runtime decoder-rebuild on DAT's adaptive-ladder resolution swaps. Closes v0.07.
- [06 — Shareable viewer link](completed/06-shareable-viewer.md) — viewer hosted at `waza-proto.vercel.app`; Vercel Node serverless token mint gated by per-invite HS256 JWTs (3h TTL, no denylist); iPhone "Copy viewer link" button + "N watching" overlay badge. Closes v0.06.
- [05 — Glasses frames via WDAT, published through LiveKit](completed/05-wdat-glasses-frames.md) — swapped iPhone front camera for Ray-Ban Meta POV via DAT v0.7; frame bridge `videoFramePublisher.listen { capturer.capture($0.sampleBuffer) }`; live source swap, hinge-fold teardown, Developer Mode credentials. Closes v0.05.
- [04 — iOS shell publishing the iPhone front camera](completed/04-ios-front-camera.md) — minimal SwiftUI app; LiveKit Swift SDK 2.14.1; `setCamera(enabled:captureOptions:)` publishes the front camera to `waza-proto` room; browser viewer confirmed end-to-end.
- [03 — Test publisher via LiveKit CLI](completed/03-test-publisher.md) — locally-generated H.264 test pattern published via `lk room join --publish`; closed the loop on the SFU/codec/viewer pipeline before any native code.
- [02 — Browser viewer with hardcoded JWT](completed/02-browser-viewer.md) — static HTML + LiveKit JS SDK subscribing to a hardcoded room. Validated against a manually-minted token; awaits test-pattern publisher in step #3.
