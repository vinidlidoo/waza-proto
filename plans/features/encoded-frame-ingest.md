# Encoded-frame ingest (true HEVC pass-through)

**What.** Pass DAT's `.hvc1` `CMSampleBuffer`s directly to the LiveKit room **without decoding in our app and without LiveKit re-encoding**. The cleanest possible glasses-to-viewer path: one HW encode on the glasses, one network hop, browser HW decode. This is fundamentally different from [h265-publish.md](h265-publish.md), which still does decode + re-encode in our app.

**Why.** Eliminates the HW decode + HW encode per frame on the iPhone. Lower CPU, lower battery, slightly lower latency, no transcoding quality loss. Today's pipeline does both because LiveKit's `BufferCapturer` only accepts raw pixel formats.

## Path A — wait for Swift SDK native encoded ingest

The "right" long-term answer: a native API on `LocalParticipant` that takes pre-encoded `CMSampleBuffer`s and treats them as the wire format.

**Status as of 2026-05-25.** *Far from ready.*
- The upstream prototype is **livekit/rust-sdks#1048** ("encoded_video_ingest"), open since 2026-04-27, ~4200 lines across 38 files. Commits show real architectural infra: `webrtc-sys: add EncodedVideoTrackSource + PassthroughVideoEncoder`, `libwebrtc: expose NativeEncodedVideoSource`, `livekit-ffi: encoded video source API`, `webrtc-sys: cache and auto-prepend H.264/H.265 parameter sets`.
- Maintainer review explicitly invoked LiveKit's "New Product Development Process Template" — i.e. formal API design review, not a quick patch.
- **Critical gotcha**: the Swift SDK is **not** built on rust-sdks / livekit-ffi. It has its own libwebrtc-sys bindings (custom m144 fork, see recent commits in client-sdk-swift `.changes`). So even after #1048 merges in rust-sdks, **a separate port to client-sdk-swift is required**. No such PR is in flight today. The Android SDK is in the same boat. JS SDK is on its own runtime too.
- Realistic outlook: 3-6+ months for rust-sdks #1048 to merge and stabilize, then Swift port becomes a discrete prioritization decision. Could be "this year," could be "never" if maintainers decide Path B is the canonical answer.

## Path B — use `livekit-cli` as a relay today

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

## Pairing with H.265 publish

Both Path A and Path B compose naturally with [h265-publish.md](h265-publish.md) — once we're sending pre-encoded HEVC end-to-end, the publish codec is decided by what the glasses produce. The codec-swap roadmap entry is independent and stand-alone (works today via Swift SDK alone); the pass-through entry is the bigger architectural shift.
