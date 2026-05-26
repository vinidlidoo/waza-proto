# 07 — Background streaming (glasses path)

Build ladder step #7. Lets the iPhone keep publishing the glasses POV to LiveKit while the user is in another app (or the screen is locked). Front-camera backgrounding is explicitly deferred — see §Key decisions. v0.07.

## Goal

Tap Connect with source=Glasses, switch to another app (Messages, Maps, Safari) or lock the screen, and the viewer URL keeps receiving video uninterrupted. Tapping back into WazaProto resumes the local preview without a reconnect. No degradation in latency or framerate from the foreground case.

Front-camera source either explicitly shows a "foreground only" affordance or pauses cleanly when backgrounded — TBD per §Open questions.

## Why this slice

In every demo so far the iPhone has to stay foreground for the stream to keep flowing, which means the publisher can't *use* their phone while wearing the glasses. The whole product premise of step #5 — POV-from-glasses — assumes the wearer is doing something else with their hands and attention. Foreground-only is the bug; backgrounding is the feature.

Glasses-source backgrounding is the cheap win: the phone isn't capturing video itself, just relaying frames the glasses already encoded over Bluetooth. iOS allows network activity in the background indefinitely, so the LiveKit upstream half is unblocked. The only unknowns are whether the DAT SDK's Bluetooth/session maintenance survives backgrounding, and whether the right `Info.plist` capability + `UIBackgroundModes` flag is enough to keep the WebRTC connection alive past the ~30s default suspension.

Front-camera backgrounding is the expensive case (Apple actively prevents normal apps from capturing camera in the background — see §Key decisions for the three escape hatches) and isn't worth tackling in the same slice.

## Approach

Two pieces.

### 1. Enable background execution for the LiveKit upstream + DAT pipe

Add to `Info.plist` (combining LiveKit's and Meta's authoritative guidance):

```xml
<key>UIBackgroundModes</key>
<array>
    <string>audio</string>
    <string>bluetooth-peripheral</string>
    <string>external-accessory</string>
</array>
<key>UISupportedExternalAccessoryProtocols</key>
<array>
    <string>com.meta.ar.wearable</string>
</array>
<key>NSBluetoothAlwaysUsageDescription</key>
<string>Needed to connect to Meta Wearables</string>
```

- **`audio`** — LiveKit's [Swift quickstart](https://docs.livekit.io/transport/sdk-platforms/swift/) and [media-publish docs](https://docs.livekit.io/transport/media/publish/) both prescribe this as the single mode needed to keep audio sessions (which include the WebRTC PeerConnection carrying video) alive in background. Cross-platform docs (Flutter, generic) say the same. The SDK's own test host plist additionally lists `voip` — likely for testing CallKit-style scenarios, not a requirement for normal video publishing. Start with `audio` only.
- **`bluetooth-peripheral`** and **`external-accessory`** — both required per Meta's [DAT iOS integration guide](https://wearables.developer.meta.com/docs/develop/dat/build-integration-ios). The DAT pipe is **two channels, not one**:
  - **Control plane (BLE)**: pairing, discovery, capability negotiation, session state. Covered by `bluetooth-peripheral` (counter-intuitively named — the phone isn't acting as a central scanner; it's exposing services that the glasses consume).
  - **Data plane (ExternalAccessory framework)**: the actual video bytes. Apple's ExternalAccessory is an MFi-only API that abstracts the physical transport — under the hood, Ray-Ban Meta video almost certainly rides a Wi-Fi peer-to-peer link, not BLE (BLE peaks at a few Mbps real-world, nowhere near enough for HD@30fps). Your app sees an `EASession` with input/output streams keyed by the registered protocol `com.meta.ar.wearable`; iOS picks the physical link invisibly.

  Both modes are needed because dropping either kills the pipe: lose BLE and the session terminates; lose ExternalAccessory and the video stops even though the session looks alive. Meta's docs also call for the `UISupportedExternalAccessoryProtocols` array (registers our app to see accessories speaking that protocol — without it the OS refuses to surface them) and the `NSBluetoothAlwaysUsageDescription` privacy string.

The trick is that `audio` is technically dishonest for a video-only publisher. Two alternatives to evaluate only if `audio` proves insufficient:
- Publish a silent audio track alongside video — turns the claim into truthful, App Store reviewer-safe
- Add `voip` mode + CallKit + PushKit — legitimate fit for "this is a live A/V session", but heavy and requires CallKit integration since iOS 13 (Apple now requires VoIP background apps to use CallKit/PushKit)

For v0.07, start with the three-mode array above. Refactor to honest-mode in a follow-up if review feedback (or our own taste) demands it.

> **Note on App Store distribution**: Meta's docs explicitly warn that the DAT SDK currently triggers App Store rejection due to MFi program + privacy-manifest requirements, so distribution is via TestFlight / release channels only. Not actionable for v0.07 but worth tracking — this is why we don't need to over-engineer the "is `audio`-mode honest?" question yet.

### 2. DAT session survives suspension

The DAT SDK's `DeviceSession` runs on a `WearablesInterface` that talks to glasses over Bluetooth and processes incoming frames. Two questions:

- Does the `videoFramePublisher.listen { ... }` callback keep firing while backgrounded? If yes, frames keep flowing into the `BufferCapturer` and LiveKit publishes them as normal. If no, we need to find an SDK hook to keep the session warm.
- Does `AutoDeviceSelector`'s reconnection loop survive backgrounding? If the user toggles glasses on/off while phone is backgrounded, do we still get the device-change events?

**Research finding (de-risked):**

1. Grepping MWDATCore + MWDATCamera swiftinterfaces (`background|suspend|appState|UIApplication|scenePhase|...`) returns zero hits — the DAT SDK is *agnostic* to UIApplication state, with no public hooks for foreground/background transitions.
2. Meta's own session-lifecycle docs define three `SessionState` values: `RUNNING` (active streaming), `PAUSED` ("Session is temporarily suspended. Hold work. Paths may resume."), and `STOPPED` (terminal). Critically: "`SessionState` does not expose the reason for a transition." So backgrounding *may* surface as a `PAUSED` event but so may other causes (low battery, glasses removed, system pre-emption). Our existing `GlassesSource.swift` watchdog already treats only `.stopped` as terminal and just logs other state transitions — that contract holds.
3. We bypassed the broken wearables-dat MCP by reading Meta's published `llms.txt` directly (`https://wearables.developer.meta.com/llms.txt?full=true`). The MCP returns `FlexBoxBackground` for every query regardless of phrasing — this is a tool-broken issue worth filing, not a docs gap.

**Implementation finding (resolved the actual bug):**

The §1 plist + `suspendLocalVideoTracksInBackground=false` + active AVAudioSession (via `setMicrophone(enabled:true)`) are all necessary but **not sufficient**. Live test on a connected phone showed:

- Hera (XMS_WARP / `MediaQualityMonitor`) keeps reporting 30 fps from the glasses regardless of foreground/background — the glasses-to-phone link is fine.
- Our per-frame counter inside `videoFramePublisher.listen` **stops firing the instant the app backgrounds** (frame count freezes at whatever it was when the user swiped home).

The cause is documented in DAT's `VideoCodec` enum reference (https://wearables.developer.meta.com/docs/reference/ios_swift/dat/0.6/mwdatcamera_videocodec):

> **`raw`**: "Raw decompressed video frames (420v YUV pixel buffers). Note: Video frames are only delivered while the app is in the foreground. When the app enters background, frame delivery stops. **Use hvc1 if you need to receive frames while backgrounded.**"
> **`hvc1`**: "Compressed HEVC video frames. Frames are delivered as compressed `CMSampleBuffer`s without decoding, in both foreground and background."

We're on `.raw`. The decompression DAT does internally (presumably VideoToolbox-backed) is foreground-only. With `.hvc1`, DAT hands us the compressed HEVC `CMSampleBuffer` directly and decoding becomes our problem — but that decode happens in our process (which is alive via `external-accessory` background mode), so it works.

**Fix plan (ready to apply, not yet applied):**

1. **`GlassesSource.swift:55`**: change `videoCodec: .raw` → `videoCodec: .hvc1`.
2. **Add a `VTDecompressionSession`** lazily on first frame (extract format description from the first `CMSampleBuffer`, build session with no output callback so we can use the synchronous closure form).
3. In the frame listener, route through `VTDecompressionSessionDecodeFrame(..., outputHandler: { [capturer] status, _, imageBuffer, _, _ in ... })` and on success call `capturer.capture(pixelBuffer, timeStampNs:, rotation:)` — LiveKit's `BufferCapturer` has a direct `CVPixelBuffer` overload, no need to rewrap into a `CMSampleBuffer`.
4. Tear down the decompression session in `unpublish` (alongside the existing `stream.stop` / `deviceSession.stop`).

Estimated diff: ~35-50 lines net add, all in `GlassesSource.swift`. `RoomConnection.swift` unchanged from current state (which already has `suspendLocalVideoTracksInBackground=false` and `setMicrophone(enabled:true)` — those remain necessary, since the §1-style plist + active audio session is what convinces iOS to keep the WebRTC sockets alive; the codec change only fixes the *source* of frames).

**Risks / known costs:**

- CPU: we now decode HEVC then WebRTC re-encodes to H.264 (or VP8) per frame. At 30 fps × 720p this is real work — both VideoToolbox HW paths so probably fine on iPhone 17, but worth a thermal/battery measurement after it works.
- Latency: one extra decode round-trip. Likely <5 ms; well within the sub-second budget.
- Alternative considered and rejected: pass HEVC bytes straight to LiveKit. Grepping `livekit/client-sdk-swift` for `HEVC|H265|hvc1` returns zero hits — no HEVC pass-through support. The transcode is the only realistic path.

Mitigation if frames stall despite the above: capture-side keepalive (publish a transparent 1×1 frame every N seconds when no glasses frame has arrived), watchdog-restart the DAT session if `videoFramePublisher` goes silent for >5s.

## File layout (delta from step #6)

```code
ios/WazaProto/WazaProto/
  Info.plist                      ← + UIBackgroundModes
  ContentView.swift               ← optional: "foreground only" affordance for front-camera source
  RoomConnection.swift            ← maybe: silent audio track if backgrounding requires it
```

No new files expected. Tiny config change + possibly a few lines of LiveKit publish-options.

## Key decisions (upfront)

- **Glasses path only.** Front camera backgrounding requires one of three workarounds, all expensive: PiP (fiddly capture-into-PiP plumbing), CallKit + VoIP background mode (PushKit, call lifecycle, real overhead), or a custom system-level capability we won't get. For v0.07 we either disable Connect when source=frontCamera + app-is-backgrounded, or document "front camera is foreground-only" and pause cleanly. Re-evaluate front-camera backgrounding only if real demo feedback says it matters.
- **`UIBackgroundModes = ["audio", "bluetooth-peripheral", "external-accessory"]` is the starting point** — `audio` from LiveKit's Swift docs; `bluetooth-peripheral` + `external-accessory` from Meta's own DAT iOS integration guide (which also requires `UISupportedExternalAccessoryProtocols=[com.meta.ar.wearable]` and an `NSBluetoothAlwaysUsageDescription` privacy string). If WebRTC still suspends despite `audio`, escalate to `voip` + CallKit — but don't add CallKit speculatively, the surface area (PushKit, providers, call updates) is large and meaningful to test.
- **No silent-audio-track upfront.** Try without it. If `["audio"]` is rejected by review or fails to keep the connection alive without an actual audio track, add one — but the cost (an unused upstream track on every viewer) is real, so prove it's needed first.
- **Don't change the `BufferCapturer` or `GlassesSource` lifecycle.** The bet is that backgrounding just works with the right plist flag + DAT SDK behavior. Refactors come only if the bet loses.

## Open questions

- ~~Which of `audio` / `voip` keeps the LiveKit WebRTC PeerConnection alive~~ — **resolved by research:** LiveKit's official Swift quickstart + media-publish docs both prescribe `audio` as the single mode needed. `voip` only appears in their test host plist and is the heavier escalation (requires CallKit + PushKit on modern iOS).
- ~~Does the DAT SDK keep delivering frames in the background~~ — **resolved by Meta's own iOS integration guide** (fetched via published `llms.txt` after the wearables-dat MCP returned junk). The plist needs `bluetooth-peripheral` + `external-accessory` + `UISupportedExternalAccessoryProtocols=[com.meta.ar.wearable]`; with those set, the SDK is app-state-agnostic and `videoFramePublisher` should keep firing. SessionState may transition to `.paused` for unrelated reasons (low battery, etc.) — our watchdog already only tears down on `.stopped`, so no code changes needed for that.
- What's the right UX when source=frontCamera and user backgrounds the app? Three options: (a) pause publishing silently and resume on foreground; (b) show a notification "front camera paused — return to app or switch to glasses"; (c) leave a placeholder frame ("camera paused" graphic) so viewers know it's intentional. Default to (a) unless testing reveals viewer confusion.
- Does screen lock count as backgrounding for the camera-access restriction? Glasses-source shouldn't care (it's not using the phone camera), but worth testing explicitly since lock-screen is the common case ("user puts phone in pocket while wearing glasses").
- Battery / thermals: how much hotter does the phone run while backgrounded-publishing for 10+ minutes? Could be a tech-debt item if it's bad enough to throttle.
- Does the LiveKit JWT in `Secrets.swift` (6h TTL) need a refresh path before we trust long backgrounded sessions? Today the publisher JWT is regenerated manually via `refresh-secrets.sh` — fine for demos, but a backgrounded stream that runs for 6+ hours hits expiry. Out of scope, but flag for tech debt.
- ~~Does the glasses video pipe use BLE end-to-end or Wi-Fi-direct~~ — **resolved**: Meta's docs reveal it uses the iOS `ExternalAccessory` framework (MFi-style) registered to the `com.meta.ar.wearable` protocol for the high-bandwidth path, plus BLE under the `bluetooth-peripheral` mode for the control channel. Both are covered by the §1 plist.

## Done criteria

1. With source=Glasses, tap Connect. Stream is live on the viewer URL.
2. Press the home gesture (or switch to another app). Stream keeps flowing on the viewer for ≥5 minutes with no visible interruption or framerate drop.
3. Lock the screen. Stream keeps flowing for ≥5 minutes.
4. Foreground the app again. Local preview resumes from current state (not a stale freeze frame).
5. While backgrounded, toggle the glasses' hinges open/closed. The hinge-fold teardown still tears down the LiveKit publication cleanly and surfaces an error when the app is reopened.
6. With source=frontCamera, backgrounding behaves per whatever UX we settle on in §Open questions — verify the behavior is intentional, not crashy or silently broken.
7. No memory or battery surprises: 10 minutes of backgrounded glasses streaming uses no more than ~1.5× the foreground baseline of either.
8. Console logs from the backgrounded period (captured via `devicectl device process launch --console`) show the LiveKit PeerConnection staying connected, no reconnect storms.

### No-regression gate

Adding the HEVC decode step inside our app moves work that previously ran inside Meta's Hera process into our process. The bet is "same operation count, same hardware path, no observable change in the foreground experience" — that bet needs evidence:

- **R1 — Foreground FPS unchanged**: the `[glasses] decode fps=X` heartbeat logged once per second from `GlassesSource` reports ~30 fps (matches the pre-fix `.raw` baseline) for the entire foreground portion of a session.
- **R2 — Background FPS at parity**: same heartbeat continues at ~30 fps after backgrounding. No sustained drops, no zero-fps gaps longer than the codec keyframe interval.
- **R3 — Visual quality parity**: side-by-side or before/after viewer check during a foreground capture finds no perceptible quality regression.
- **R4 — Latency parity**: glanceable check — point the glasses at a stopwatch, look at the viewer-side delay. Should be within the same envelope as the `.raw` baseline (no extra ~50ms+ added by the new decode hop).
- **R5 — No leaks across a long session**: 10 min foreground + 10 min backgrounded, app memory footprint at the end ≤ 1.3× the post-publish baseline. (Glance via Xcode debug navigator memory graph or `devicectl device info processes` over time.)

R1, R2, and R5 are the load-bearing ones — if any fails, do not close step 7.

## Decisions logged during implementation

- **All four publish-side knobs are load-bearing** — none are redundant. Confirmed empirically by reverting each in isolation:
  1. `Info.plist` `UIBackgroundModes` = `audio` + `bluetooth-peripheral` + `external-accessory` + `processing` + `bluetooth-central` (Meta's set plus LiveKit's `audio`)
  2. `RoomOptions(suspendLocalVideoTracksInBackground: false)` — without this, LiveKit calls `.suspend()` on any `source=.camera` track the instant the app backgrounds, regardless of the plist. (See `livekit/client-sdk-swift#832`.)
  3. `room.localParticipant.setMicrophone(enabled: true)` — `UIBackgroundModes=audio` only keeps WebRTC sockets warm when there's an *active* `AVAudioSession`. Publishing a (currently silent / unused) mic track is the cheapest way to satisfy that. Without it the WebRTC PeerConnection still pauses despite the plist. (See `livekit/client-sdk-swift#510`.)
  4. `GlassesSource`: `VideoCodec.hvc1` + in-app `VTDecompressionSession`. Documented in DAT's `VideoCodec` reference: `.raw` is *foreground-only by design* — DAT's internal decoder stops delivering frames the instant the app loses foreground. `.hvc1` delivers compressed HEVC `CMSampleBuffer`s continuously, and we decode in our own process (which stays alive via `external-accessory`).
- **DAT's adaptive ladder requires runtime decoder rebuild.** The bitrate ladder silently swaps resolutions mid-stream (we've observed 720×1280 ↔ 504×896 swaps every few seconds under weak Bluetooth). Each swap ships new SPS/PPS/VPS, so a cached `VTDecompressionSession` rejects every subsequent frame with `-12916` (`kVTVideoDecoderBadDataErr`). Fix: call `VTDecompressionSessionCanAcceptFormatDescription` on each frame and rebuild on mismatch (`VTDecompressionSessionInvalidate` the old one first). Observed multiple clean rebuilds per minute during testing — runtime cost is negligible.
- **DAT hands us real HVCC, not Annex B.** Diagnostic dump confirmed the `CMSampleBuffer` data buffer is already length-prefixed (`00 00 66 52` for a 26194-byte NAL, total buffer 26198 bytes). No Annex B → AVCC conversion needed — VideoToolbox decodes directly.
- **Pixel format**: `kCVPixelFormatType_420YpCbCr8BiPlanarFullRange` — matches what `.raw` was delivering and one of LiveKit `BufferCapturer`'s supported formats. Smooth swap.
- **Background-transition stutter is acceptable, not fixed.** Each foreground↔background swap triggers ~5 seconds of `-17694` (`kVTVideoDecoderReferenceMissingErr`) — the HW decoder lost its reference frame across the suspension and waits for the next IDR before recovering. Heartbeat resumes at ~25-30 fps after the IDR arrives. No clean way to force DAT to emit an immediate keyframe today; logged as tech debt rather than worked around.
- **First-frame signal moved into the VT output handler** (vs. firing on first encoded-sample arrival). More correct — we only consider the publish "ready" once we've actually produced a pixel buffer — at the cost of a hang risk if decode ever drops the first sample. In practice the first sample is always an IDR, so this never bites.
- **Codex review false positive** flagged the `VTDecompressionSessionDecodeFrame` output handler as 6-arg; actual `VTDecompressionOutputHandler` typealias is 5-arg. The 6-arg variant belongs to `VTDecompressionSessionDecodeFrameWithMultiImageCapableOutputHandler`, a different function. Build succeeded, runs on-device. No change.

## Vincent's learnings

- iOS "background modes" don't compose intuitively. `audio` is a *condition* (keep this app's network alive *if* it has an active `AVAudioSession`), not a *promise* (this app is allowed to keep streaming). The trick of publishing a mic track to *activate* an `AVAudioSession` so the `audio` mode kicks in is a recurring iOS-WebRTC pattern, not specific to LiveKit.
- "Background works" is a spectrum. A 5-second reference-frame stutter at every app-switch is fine for "publisher puts phone in pocket and walks around" (one transition, then steady). It would be unacceptable for "publisher actively flips between apps." Worth being honest about the failure mode rather than claiming feature parity.
- Three different vendors' background semantics had to align: Apple's UIApplication suspension, LiveKit's track-suspension policy, and DAT's frame-delivery contract. Each had docs; none mentioned the other two. The interaction is implementation-defined.

## Tech debt opened

Logged to `plans/tech-debt-tracker.md`:

- **Background-transition IDR stutter** (~5s of `-17694` errors at every foreground↔background transition). Force a keyframe on transition once DAT exposes a hook for it.

Forward-looking ideas (not debt — moved to `plans/features.md`):

- H.265 publish to LiveKit (codec swap only — uses the Swift SDK 2.7.0+ `preferredCodec: .h265` path)
- Encoded-frame ingest (true HEVC pass-through, removing the decode+re-encode hop entirely)
- Long-session JWT auto-refresh on the publisher
- Front-camera backgrounding
