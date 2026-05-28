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

## Glasses stream: re-encode default vs HEVC pass-through (plans 15–17)

**What:** The shipped glasses path (default) decodes the glasses' HEVC in-app via `VTDecompressionSession` and **re-encodes to H.265** inside the LiveKit Swift SDK (`preferredCodec: .h265`, `maxBitrate: 4 Mbps` cap; measured 1.54 Mbps actual). This pays a HW decode + HW re-encode per frame and adds a modest **second-generation (tandem-coding) softness** vs passing the glasses' HEVC bytes straight through. The zero-transcode alternative (Path B, `Config.glassesEncodedIngest`) is **built and in the tree but flag-gated OFF.**

**Why deferred (i.e. why we ship the re-encode, not pass-through):** Plans 15–17 measured both. Pass-through's freezes were root-caused as **PLI deadlock** ([[encoded-pli-deadlock]]) — the relay can't manufacture a keyframe on PLI; the in-app encoder can, which is why re-encode is freeze-free. Plan 17 Stage 1 (parameter sets only at true IRAPs) cut pass-through worst-freeze 3,068 → 411 ms, but it still has GOP-bounded catch-up jumps (≤ ~3 s; DAT exposes no keyframe control — [[dat-no-encoder-control]]) and higher latency. The re-encode wins the live experience (snappier, ~half jb latency, no jumps, relay-free). Quality bar is "no *visible* tax," and the tandem softness clears it. Full decision: `plans/completed/17-encoded-freeze-recovery.md`.

**Path B's own open bugs (must clear before it could ever become default):**
- **SIGSEGV on Ray-Ban accessory disconnect in encoded mode** — the frame closure fires with a torn-down `CMVideoFormatDescription`; the re-encode path doesn't trip this (decoder rebuilt-or-bailed defensively). Guard the closure on a live format descriptor before extraction.
- **Watchdog misses `EAAccessory`-level disconnects** — pre-existing (plan 13 territory); the BT accessory disconnect doesn't promote to `DeviceSession.stateStream`/`errorStream`, so `onTerminated` never fires and the UI shows "Connected" while detached.
- **GOP-bounded catch-up jumps** — architectural (no DAT keyframe control); needs the deferred stateful GOP-replay Go relay (plan 17 Stage 2) to fix.

**What would trigger paying it down:**
- A quality-critical mode where the tandem softness becomes unacceptable → revisit Path B (fix the bugs above) or push the transcode to a Mac-side relay at high bitrate.
- Battery / thermal complaints during long backgrounded sessions (the re-encode is the hot path; §4d.1 showed it starves DAT ~6 fps under stress).
- LiveKit shipping a Swift-native encoded-frame ingest API **with** a stateful keyframe-on-PLI story (native ingest alone relocates the deadlock, doesn't close it).

**Where to start:** `plans/completed/17-encoded-freeze-recovery.md` (Outcome + Shipping checklist §4) and `plans/completed/15-encoded-frame-ingest.md`. Path B wiring lives behind `Config.glassesEncodedIngest` in `GlassesSource.swift` (`HEVCAnnexBExtractor` + `EncodedFrameTCPServer`); the Mac relay is `scripts/run-glasses-relay.sh <ip>`.

## Glasses stream: background-transition reference-frame stutter

**What:** Every foreground↔background app transition produces ~5 seconds of `kVTVideoDecoderReferenceMissingErr` (-17694) in the in-app HEVC decode path. The HW decoder loses its reference frame across the suspension and waits for the next IDR before recovering. Heartbeat resumes at ~25-30 fps once the IDR arrives.

**Why deferred:** Acceptable for the "publisher puts phone in pocket and walks around" use case (one transition, then steady). DAT's public API doesn't currently expose a way to request an immediate keyframe, so the fix would be either a runtime workaround (drop frames silently until the next IDR, which we effectively already do) or a vendor request to Meta.

**What would trigger paying it down:** Use cases that involve frequent app switching, or demo feedback specifically calling out the post-transition stutter.

**Where to start:** File a feature request against `facebook/meta-wearables-dat-ios` for a `Stream.requestKeyframe()` (or equivalent) hook. In the meantime, an option worth experimenting with: log an explicit "decoder recovering" status to the UI during the stutter so the user knows the freeze is intentional.

## RoomConnection: reconnect-on-stale-token fallback

**What:** If the iOS app stays disconnected from LiveKit long enough for the server-pushed cached refresh token (10-min TTL) to age out, the SDK's automatic reconnect will fail with an auth error and the room ends up in `.failed`. The fix is small — catch the failed reconnect and call `connect()` again, which re-mints a fresh publisher JWT via `/api/publisher-token`.

**Why deferred:** Plan 10 closed out without ever observing this in practice. The risk only materializes if the app sits backgrounded *without network* for >10 min and then tries to reconnect. Real backgrounded sessions on cellular/wifi keep the WebSocket alive and the server keeps pushing fresh refresh tokens, so the cache never goes stale. Adding the fallback now would be speculative — wait for a real session log showing the failure mode.

**What would trigger paying it down:** A glasses session where `RoomConnection.Status` flips to `.failed("…401…")` (or another auth-shaped error) after a long backgrounded period, ideally with an iOS console log capturing which exact LiveKit reconnect path failed.

**Where to start:** `RoomConnection.swift` — extend the `RoomDelegate` handling to detect `Room.didDisconnect` with reason `.tokenExpired` (or an auth-marker in the underlying error string) and call `connect(source:, glasses:)` instead of surfacing as `.failed`. Roughly ~10 LOC. Stage 3 of plan 10 was scoped for this and explicitly skipped — full finding in `plans/completed/10-jwt-auto-refresh.md` Decisions logged section.
