# Features roadmap

Forward-looking ideas surfaced during implementation that don't belong in the current rung but are worth tracking. One entry per idea — when we pick one up, move it to a `plans/active/NN-…md`.

## H.265 publish to LiveKit (codec swap only — *not* pass-through)

**What.** Switch the LiveKit publish codec from H.264 (current default) to H.265, with H.264 as `preferredBackupCodec` to cover subscribers whose browsers can't decode HEVC.

```swift
VideoPublishOptions(simulcast: false,
                    preferredCodec: .h265,
                    preferredBackupCodec: .h264)
```

This is **purely a codec change for the WebRTC encoder inside the Swift SDK**. It doesn't remove the decode step that step 7 introduces in `GlassesSource` — the SDK still takes raw `CVPixelBuffer`s as input. To actually skip the decode + re-encode, see [[encoded-frame-ingest]] below.

**Why.** ~30-50% bitrate reduction at the same visual quality, which matters on weak Wi-Fi and LTE. On iPhone, encode CPU is the same (VideoToolbox HW path either way).

**Why not now.** Surfaced during step 7 research but orthogonal to the backgrounding fix, and brings its own complexity:
- Backup codec triggers simulcast → roughly 2× publisher upload bandwidth + encode work to cover non-HEVC subscribers.
- Browser HEVC subscribe support varies: Safari ✓, recent Chrome/Edge mostly ✓ on macOS, Firefox patchy, Linux Chrome patchy.
- Best validated by A/B against the H.264 baseline to confirm the win is real.

**Status.** Researched 2026-05-25.
- LiveKit Server enabled H.265 by default July 2025 (livekit/livekit#3773, 1-line change).
- Swift SDK has had H.265 publish since v2.7.0 (Aug 2025) — we're on 2.14.1, nothing blocks us API-wise. PR #746, issue #710.
- Android SDK shipped the equivalent in v2.20.0 (Aug 2025) — PR #742. JS SDK gained publish + E2EE for H.265 in the v2.15.5 line (Aug 2025).
- The recent single-stream H.265 SFU forwarding bug at livekit/server-sdk-go#901 is **Go-specific** — the Swift SDK's `PublishTrack` populates `SimulcastCodecs[0]` properly, so our path is unaffected.
- **Ingress (RTMP/WHIP) does NOT support H.265** (livekit/ingress#400, open). Doesn't affect us since we publish via the Swift SDK, not via Ingress.

## Encoded-frame ingest (true HEVC pass-through)

**What.** Pass DAT's `.hvc1` `CMSampleBuffer`s directly to the LiveKit room **without decoding in our app and without LiveKit re-encoding**. The cleanest possible glasses-to-viewer path: one HW encode on the glasses, one network hop, browser HW decode. This is fundamentally different from the [[H.265 publish to LiveKit]] entry above, which still does decode + re-encode in our app.

**Why.** Eliminates the HW decode + HW encode per frame on the iPhone. Lower CPU, lower battery, slightly lower latency, no transcoding quality loss. Today's pipeline does both because LiveKit's `BufferCapturer` only accepts raw pixel formats.

### Path A — wait for Swift SDK native encoded ingest

The "right" long-term answer: a native API on `LocalParticipant` that takes pre-encoded `CMSampleBuffer`s and treats them as the wire format.

**Status as of 2026-05-25.** *Far from ready.*
- The upstream prototype is **livekit/rust-sdks#1048** ("encoded_video_ingest"), open since 2026-04-27, ~4200 lines across 38 files. Commits show real architectural infra: `webrtc-sys: add EncodedVideoTrackSource + PassthroughVideoEncoder`, `libwebrtc: expose NativeEncodedVideoSource`, `livekit-ffi: encoded video source API`, `webrtc-sys: cache and auto-prepend H.264/H.265 parameter sets`.
- Maintainer review explicitly invoked LiveKit's "New Product Development Process Template" — i.e. formal API design review, not a quick patch.
- **Critical gotcha**: the Swift SDK is **not** built on rust-sdks / livekit-ffi. It has its own libwebrtc-sys bindings (custom m144 fork, see recent commits in client-sdk-swift `.changes`). So even after #1048 merges in rust-sdks, **a separate port to client-sdk-swift is required**. No such PR is in flight today. The Android SDK is in the same boat. JS SDK is on its own runtime too.
- Realistic outlook: 3-6+ months for rust-sdks #1048 to merge and stabilize, then Swift port becomes a discrete prioritization decision. Could be "this year," could be "never" if maintainers decide [Path B](#path-b--use-livekit-cli-as-a-relay-today) is the canonical answer.

### Path B — use `livekit-cli` as a relay today

`livekit-cli` (Go binary, `lk`) already ships encoded-bytestream publish: `lk room join --publish h265://host:port` makes it a TCP client that reads raw HEVC NAL units and injects them directly into the LiveKit room. Landed via livekit/livekit-cli#722 (merged Jan 2026); details in the README's *Publish from TCP* section.

Architecture:

```text
[iPhone: DAT .hvc1 → TCP listener on a port]
                          ↑
                          │ raw HEVC bytestream over TCP
                          ↓
                   [Go process running `lk room join --publish h265://...`]
                          ↓
                   [LiveKit Cloud SFU → viewer]
```

**What's required to ship this:**
- A Go process running `lk` somewhere that can reach (a) the iPhone's TCP port and (b) LiveKit Cloud. On home Wi-Fi a laptop on the same LAN suffices for demos. For "wearer walks around with the glasses on cellular," a hosted relay (Fly.io / Railway / DO droplet) is required, plus a tunnel back to the iPhone (carrier NAT blocks inbound from the public internet).
- On the iPhone side: a long-lived TCP listener that survives backgrounding. Solvable with Network.framework + the right session entitlements, but it's a *second* class of background plumbing layered on top of step 7's `external-accessory` work — non-trivial integration.
- Caveat: the `livekit-cli` H.265 simulcast path uses `PublishSimulcastTrack` underneath (which populates `SimulcastCodecs` properly). Single-stream H.265 publish via the CLI is currently affected by the server-sdk-go #901 bug — until that lands, prefer simulcast or wait.

**When to do this:** when publisher battery/thermals on long sessions become a real measured pain point and we're ready to invest in the relay infra. Probably not before we have a clearer product shape than v0.x prototyping.

### Pairing with H.265 publish

Both Path A and Path B compose naturally with [[H.265 publish to LiveKit]] above — once we're sending pre-encoded HEVC end-to-end, the publish codec is decided by what the glasses produce. The codec-swap roadmap entry is independent and stand-alone (works today via Swift SDK alone); the pass-through entry is the bigger architectural shift.

## Long-session JWT auto-refresh on the publisher

**What.** Add a refresh path on the iOS publisher's LiveKit JWT (today minted with a 6h TTL by `scripts/refresh-secrets.sh`). Either rotate via the same Vercel mint endpoint used by viewers, or vend short-lived publisher tokens from a separate endpoint.

**Why.** Backgrounded glasses sessions could run hours. The current manual-refresh workflow is fine for demos but breaks the moment a session crosses the 6h boundary.

**Why not now.** Surfaced as an open question in step 7. The current demo cadence (sub-hour) doesn't hit it. Bundle with whatever step touches `Secrets.swift` or the auth side again.

## Front-camera backgrounding

**What.** Keep the iPhone front-camera source publishing while the app is backgrounded.

**Why.** Symmetry with glasses-source backgrounding. The wearer might be doing a hands-free walk-and-talk and want their face on stream too.

**Why not now.** Apple actively blocks normal apps from capturing the camera in the background. The three escape hatches all cost a lot: PiP (fiddly capture-into-PiP plumbing), CallKit + VoIP background mode (PushKit, call lifecycle, real overhead), or a privileged entitlement we won't get. Re-evaluate only if demo feedback says it matters; for now we treat the front-camera source as foreground-only.
