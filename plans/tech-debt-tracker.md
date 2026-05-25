# Tech debt tracker

Things knowingly deferred. Each entry: what, why deferred, what would trigger paying it down.

## iOS publisher: video quality defaults

**What:** The iPhone front-camera feed published from the WazaProto iOS app (step #4) uses the LiveKit Swift SDK's out-of-the-box encoding defaults — simulcast on (LOW/MED/HIGH), default bitrate caps, default resolution. Subjectively the feed is "not amazing" though it functions end-to-end.

**Why deferred:** Step #4's done-criteria was "browser viewer shows the iPhone feed with sub-second latency", not "feed looks great." Tuning is premature until we know what the *final* pipeline (post-WDAT, step #5+) constrains us to.

**What would trigger paying it down:**
- Before showing the prototype to anyone outside the project.
- If WDAT integration (step #5+) reveals encoder load is a thermal/battery problem on the phone — at which point dropping simulcast or one tier would help.
- If the browser viewer's `RTCStatsReport` shows unexpected packet loss or jitter pointing to upstream bitrate.

**Where to start:** `room.localParticipant.setCamera(enabled:captureOptions:publishOptions:)` — the third arg is `VideoPublishOptions` which controls simulcast, bitrate, and codec. `CameraCaptureOptions(position:dimensions:fps:)` controls capture-side resolution and frame rate.

## iOS publisher: SwiftProtobuf duplicate class warnings

**What:** On launch, the ObjC runtime logs ~4 warnings like:

```
objc[…]: Class _TtC13SwiftProtobuf17AnyMessageStorage is implemented in both
  …/MWDATCore.framework/MWDATCore (0x…) and
  …/WazaProto.debug.dylib (0x…).
  This may cause spurious casting failures and mysterious crashes.
  One of the duplicates must be removed or renamed.
```

The `MWDATCore.framework` XCFramework (Meta WDAT SDK v0.7) statically links SwiftProtobuf into its binary. The LiveKit Swift SDK *also* pulls SwiftProtobuf via SPM. Two copies of the same Swift Protobuf classes end up loaded into the process; the ObjC runtime registers whichever loads first and warns about the rest.

**Why deferred:** Real fix is vendor-side — Meta would need to either dynamic-link SwiftProtobuf or rename their internal copy's symbols. In practice the warning is benign for our use of LiveKit (we don't serialise SwiftProtobuf messages in any code path that crosses framework boundaries), and no observed crash or behavioural bug so far in step #5. Workarounds (manually strip SwiftProtobuf symbols from the XCFramework, fork & rebuild MWDATCore against shared SwiftProtobuf) are disproportionate to the prototype's scope.

**What would trigger paying it down:**
- Any "mysterious" cast failure or crash in a SwiftProtobuf-touching code path (e.g. LiveKit signaling, DAT capability negotiation).
- If Meta ships an `MWDATCore` build with SwiftProtobuf dynamically linked — pick up the upgrade.

**Where to start:** File a tracking issue with Meta WDAT (link to `https://github.com/facebook/meta-wearables-dat-ios/issues`) referencing the dual-link conflict with `livekit/client-sdk-swift`'s SwiftProtobuf dependency. Until a vendor fix exists, document the warning is expected in `README.md` so it doesn't get re-debugged.

## Glasses stream: bitrate / codec headroom

**What:** Glasses POV is configured with `StreamConfiguration(videoCodec: .raw, resolution: .high, frameRate: 30)`. Subjectively the resolution and fluidity are notably below the iPhone front-camera path even at `.high`/30 — the BT link between glasses and phone is the effective bottleneck, and `.raw` (uncompressed NV12 frames) is the worst case for that link.

**Why deferred:** v0.05 demands "a recognisable POV with sub-second latency", which we hit. Switching to `videoCodec: .h264` from DAT would yield much better effective bitrate over BT, but it means feeding LiveKit an *encoded* sample stream rather than the raw pixel buffers `BufferCapturer.capture(_:)` expects — that's a bigger LiveKit-side refactor (probably a custom `RTCVideoEncoder` or pre-encoded track path) than the prototype warrants.

**What would trigger paying it down:**
- Before any demo where the glasses feed needs to look polished.
- If DAT exposes a higher-throughput pixel path on a future SDK rev.
- If we move past prototyping into a real product where glasses image quality matters.

**Where to start:** Investigate DAT's `videoCodec: .h264` output — it likely emits `CMSampleBuffer`s with H.264 AVCC data instead of raw pixel buffers. Then either (a) feed those directly into a LiveKit "encoded track" surface (the SDK has paths for this for screen-share / external codecs) or (b) decode them on-device with VideoToolbox first and pipe the decoded pixel buffers into `BufferCapturer` (no win — same bottleneck). Option (a) is the real fix.
