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

Locally-runnable test suites grow one tier per stage of [plan 08](plans/active/08-test-suite.md). Stage status drives this list — each stage adds one line.

- `cd viewer && npm test` — Vitest unit tests for the Vercel token-mint API (`viewer/api/token.js`). Covers invite verification, JWT minting, missing-env behavior, and identity collision-resistance. ~200 ms.
- `cd ios/WazaProto && xcodebuild test -project WazaProto.xcodeproj -scheme WazaProto -destination 'platform=iOS Simulator,name=iPhone 17' -parallel-testing-enabled NO` — XCTest unit tests in the `WazaProtoTests` target. Covers `Secrets` shape validation, `RoomConnection.Status` equality + labels, the viewer-identity filter helper, and a MockDeviceKit smoke test (pair Ray-Ban → `Wearables.shared` discovers it). Requires `Secrets.swift` (run `./scripts/refresh-secrets.sh` first on a fresh checkout). `-parallel-testing-enabled NO` keeps tests on the explicitly-booted simulator; the cloned-simulator path has been flaky for us on iOS 26.5.

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
