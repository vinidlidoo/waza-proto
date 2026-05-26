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

**What:** Step #7 swapped DAT to `videoCodec: .hvc1` and decodes HEVC in-app via `VTDecompressionSession`, then re-encodes inside the LiveKit Swift SDK (default H.264). This solved foreground-only frame delivery but the publisher still pays a HW decode + HW re-encode per frame — wasted work compared to passing the glasses' HEVC bytes straight through the SFU.

**Why deferred:** Step #7 done-criteria was "backgrounding works at parity," and it does. End-to-end HEVC pass-through requires either a not-yet-shipped Swift SDK API (`livekit/rust-sdks#1048` is in API design review with no Swift port even prototyped) or a Go relay process running `lk room join --publish h265://…` with TCP plumbing on the iPhone side. Neither is justified for v0.07.

**What would trigger paying it down:**
- Battery / thermal complaints during long backgrounded sessions (the re-encode is the hot path).
- Visible quality regression compared to "what the glasses actually shipped to us."
- LiveKit shipping a Swift-native encoded-frame ingest API.

**Where to start:** See `plans/features.md::Encoded-frame ingest (true HEVC pass-through)` for Path A (wait for native API) and Path B (lk CLI relay). Pairs with `plans/features.md::H.265 publish to LiveKit` for the simpler codec-swap-only intermediate win.

## Glasses stream: background-transition reference-frame stutter

**What:** Every foreground↔background app transition produces ~5 seconds of `kVTVideoDecoderReferenceMissingErr` (-17694) in the in-app HEVC decode path. The HW decoder loses its reference frame across the suspension and waits for the next IDR before recovering. Heartbeat resumes at ~25-30 fps once the IDR arrives.

**Why deferred:** Acceptable for the "publisher puts phone in pocket and walks around" use case (one transition, then steady). DAT's public API doesn't currently expose a way to request an immediate keyframe, so the fix would be either a runtime workaround (drop frames silently until the next IDR, which we effectively already do) or a vendor request to Meta.

**What would trigger paying it down:** Use cases that involve frequent app switching, or demo feedback specifically calling out the post-transition stutter.

**Where to start:** File a feature request against `facebook/meta-wearables-dat-ios` for a `Stream.requestKeyframe()` (or equivalent) hook. In the meantime, an option worth experimenting with: log an explicit "decoder recovering" status to the UI during the stutter so the user knows the freeze is intentional.
