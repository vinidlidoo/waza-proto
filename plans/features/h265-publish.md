# H.265 publish to LiveKit (codec swap only — *not* pass-through)

**What.** Switch the LiveKit publish codec from H.264 (current default) to H.265, with H.264 as `preferredBackupCodec` to cover subscribers whose browsers can't decode HEVC.

```swift
VideoPublishOptions(simulcast: false,
                    preferredCodec: .h265,
                    preferredBackupCodec: .h264)
```

This is **purely a codec change for the WebRTC encoder inside the Swift SDK**. It doesn't remove the decode step that step 7 introduces in `GlassesSource` — the SDK still takes raw `CVPixelBuffer`s as input. To actually skip the decode + re-encode, see [[encoded-frame-ingest]].

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
