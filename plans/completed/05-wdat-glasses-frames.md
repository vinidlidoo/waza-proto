# 05 — Glasses frames via WDAT, published through LiveKit

Build ladder step #5 (see `README.md`) — the final v0.05 slice. Replaces the iPhone's built-in front camera (step #4) with the Ray-Ban Meta glasses' POV camera, delivered through the Meta Wearables Device Access Toolkit (WDAT) SDK and forwarded into the same LiveKit room.

## Goal

The iOS app, running on a real iPhone paired to Ray-Ban Meta Gen 2 glasses, publishes the **glasses' camera feed** (not the phone's) to the `waza-proto` LiveKit room. The browser viewer shows what the learner sees, sub-second latency. v0.05 is done.

## Why this slice

This is where the real project risk lives. Steps #1–#4 validated every piece of *non-WDAT* infrastructure on real hardware. Everything that can fail in step #5 is localised to:

- WDAT SDK setup (Info.plist, Wearables.configure, URL callback handling).
- Meta AI registration + camera-permission flow.
- DAT `DeviceSession` + `Stream` lifecycle on actual glasses.
- The **frame bridge**: DAT `VideoFrame` → a `CVPixelBuffer` LiveKit will accept on `BufferCapturer.capture(_:)`.

If the bridge works, v0.05 ships. If it doesn't, the architecture rationale in README needs revisiting (specifically: whether DAT's decoded-frame surface is fast enough to be a real-time POV source, or whether we eventually need a deeper integration).

## Approach

Three pieces, in order.

### 1. Add the WDAT SDK and configure the app

- Add `https://github.com/facebook/meta-wearables-dat-ios` via SPM, latest tagged version (v0.7 per CHANGELOG). Modules: `MWDATCore`, `MWDATCamera`. **Skip** `MWDATDisplay` (the Ray-Ban Meta Gen 2 hardware has no display — `MWDATDisplay` targets the separate "Meta Ray-Ban Display" model) and `MWDATMockDevice` (we have real hardware; mocks are scope creep).
- `Info.plist` additions. Xcode's `INFOPLIST_KEY_*` build settings can express flat arrays-of-strings but not the **nested dicts** WDAT requires (`CFBundleURLTypes` is an array of dicts; `MWDAT` is a dict). Xcode 26 didn't change this — same limitation as 16. So we introduce a real `Info.plist` file for the WazaProto target, move the privacy strings from build settings into it (single source of truth, no precedence ambiguity), and set `GENERATE_INFOPLIST_FILE = NO` for that target.
  - `CFBundleURLTypes` with scheme `wazaproto`
  - `UISupportedExternalAccessoryProtocols`: `com.meta.ar.wearable`
  - `UIBackgroundModes`: `processing`, `bluetooth-central`, `bluetooth-peripheral`, `external-accessory` (sample app v0.7 ships all four — `bluetooth-central` for the iPhone-as-client role, `processing` for background frame work)
  - `NSBluetoothAlwaysUsageDescription`
  - `NSLocalNetworkUsageDescription` + `NSBonjourServices: ["_bonjour._tcp"]` (added in v0.7 sample — glasses-over-Wi-Fi discovery path)
  - `MWDAT` dict: `AppLinkURLScheme = wazaproto://`, `MetaAppID = 0` (Developer Mode). v0.7 also documents `ClientToken`, `TeamID`, `DAMEnabled` — only needed for production / Display features; omit for now.
  - Keep `NSCameraUsageDescription` / `NSMicrophoneUsageDescription` from step #4.
  - **Omit** `LSApplicationQueriesSchemes: fb-viewapp` — the AGENTS.md still mentions it but the v0.7 integration guide and shipping sample drop it. Add only if Meta AI's callback fails.
- Initialise the SDK at launch: `try Wearables.configure()` in `WazaProtoApp.init()`.
- Wire `.onOpenURL { url in await Wearables.shared.handleUrl(url) }` so Meta AI's callback after registration lands back in the app.

### 2. Registration + permission UI

WDAT gates everything behind two prerequisites: the app must be registered with Meta AI (one-time per device), and the user must have granted camera permission (one-time, can be `.allowOnce` per session).

Add a `GlassesGateway` `ObservableObject` that exposes:

- `registrationState: RegistrationState` — observed from `Wearables.shared.registrationStateStream()`.
- `cameraPermission: PermissionStatus` — observed lazily; refreshed on demand via `Wearables.shared.checkPermissionStatus(.camera)`.
- `register()` async — calls `startRegistration()`. Surfaces Meta AI app for approval.
- `requestCameraAccess()` async — calls `requestPermission(.camera)`.

The UI flows top-down: if not registered, show "Register with Meta AI" button. Once registered, if camera not granted, show "Grant camera access". Once both green, show the existing Connect / Disconnect button. The status label gets richer to surface all four sub-states (registration / camera permission / device-session / stream).

### 3. Frame bridge: DAT `Stream` → LiveKit `BufferCapturer`

This was the load-bearing unknown going in. It de-risked nicely: `VideoFrame` in `MWDATCamera` exposes a public `sampleBuffer: CMSampleBuffer` property (documented at `…/mwdatcamera_videoframe`), and LiveKit's `BufferCapturer` has a `capture(_ sampleBuffer: CMSampleBuffer)` overload. With `videoCodec: .raw`, the buffer is `kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange` ("420v" NV12), which LiveKit's `BufferCapturer.supportedPixelFormats` accepts. The bridge is literally one call.

```swift
// Build the LiveKit side once.
let bufferTrack = LocalVideoTrack.createBufferTrack(
    name: "glasses-camera",
    source: .camera,
    options: BufferCaptureOptions()
)
let capturer = bufferTrack.capturer as! BufferCapturer

// Build the DAT side.
let session = try Wearables.shared.createSession(
    deviceSelector: AutoDeviceSelector(wearables: .shared)
)
try session.start()
for await state in session.stateStream() where state == .started { break }

let stream = try session.addStream(config: StreamConfiguration(
    videoCodec: .raw,
    resolution: .medium,
    frameRate: 24
))!

// One-line bridge. Don't async-hop — the DAT docs explicitly say the
// CMSampleBuffer is shared and unsynchronised; LiveKit's capturer copies
// into its own pipeline synchronously.
let frameToken = stream.videoFramePublisher.listen { frame in
    capturer.capture(frame.sampleBuffer)
}

await stream.start()
try await room.localParticipant.publish(videoTrack: bufferTrack)
```

The first frame **must** flow into the capturer before `publish(videoTrack:)` returns, or LiveKit times out resolving track dimensions (per `BufferCapturer.swift` source). The natural ordering — `await stream.start()` → wait for one `videoFramePublisher` event → then `publish` — handles this; codify the wait.

Local preview reuses the step-#4 `LocalPreview: UIViewRepresentable` wrapping LiveKit's `VideoView` bound to the new `bufferTrack` — same view, different source.

### 4. Source toggle — front camera vs glasses (A/B comparison)

Step #4's iPhone-front-camera publish path stays. The app gains a `Source` enum (`.frontCamera`, `.glasses`) and a SwiftUI `Picker` above the Connect button. The picker is enabled only while disconnected — mid-stream source-switching is not in scope; teardown + reconnect is the swap mechanism. This is enough for the A/B-quality comparison the user wants and avoids the harder "renegotiate the published track" path.

`RoomConnection` becomes source-agnostic — it just publishes whatever `LocalVideoTrack` it's handed. The two source implementations live in separate types:

- `FrontCameraSource` — wraps step #4's `room.localParticipant.setCamera(...)` path. Exposes a `connect()` returning the `LocalVideoTrack` LiveKit creates.
- `GlassesSource` — wraps the DAT session + stream + `BufferCapturer` from §3. Exposes the same `connect()` signature, returning the `BufferCapturer`-backed `LocalVideoTrack`.

`RoomConnection.connect(source:)` picks one, awaits its track, then publishes. `disconnect()` tears down whichever is active. Source-gate states (registration / camera permission) apply only when `.glasses` is selected — picking `.frontCamera` skips them entirely.

### File layout (delta from step #4)

```code
ios/WazaProto/WazaProto/
  WazaProtoApp.swift            ← + Wearables.configure(); + .onOpenURL
  ContentView.swift             ← + source picker; + WDAT gate states
  RoomConnection.swift          ← source-agnostic: connect(source:), disconnect()
  FrontCameraSource.swift       ← NEW — step #4's setCamera path, extracted
  GlassesSource.swift           ← NEW — DAT session + stream + frame bridge
  GlassesGateway.swift          ← NEW — registration/permission ObservableObject
  Info.plist                    ← NEW — WDAT + privacy strings
  Secrets.swift                 ← unchanged
```

## Key decisions (upfront)

- **No `MWDATMockDevice`.** Real glasses are available; the mock kit's value is testing without hardware. Adding it now is dependency creep — the only thing we'd test against a mock is the frame-bridge code, which we're going to verify on real glasses anyway.
- **`source: .camera` on `createBufferTrack`, not `.screenShareVideo` (its default).** Under the hood the difference is a single flag passed to WebRTC's `peerConnectionFactory.videoSource(forScreenCast:)`. With `forScreenCast: true` (i.e. `.screenShareVideo`), the WebRTC encoder disables CPU-based frame dropping (screen content has long static periods where you want clarity), uses encoder defaults tuned for text/UI, and the track is tagged `screenShareVideo` in track metadata — subscriber clients often render screen-share in a primary slot. With `forScreenCast: false` (i.e. `.camera`), the encoder behaves as a normal camera source: adaptive frame-drop under CPU pressure, codec defaults tuned for natural-image content. Glasses POV is dynamic real-world video, not a desktop — `.camera` matches the encoder strategy and the semantic intent.
- **Start at `.medium` (504×896) @ 24fps.** The skill doc notes lower settings yield higher visual quality due to less Bluetooth compression. `.high` (720×1280) is the target if quality is acceptable; downgrade to `.low` (360×640) is the escape hatch if the bridge is CPU-bound. 24fps is the sweet spot per the skill doc (next step is 30 which Bluetooth often can't sustain).
- **Disable simulcast for the glasses track.** The DAT stream delivers one fixed-resolution feed at one frame rate; spawning LOW/MED/HIGH simulcast layers means re-encoding the same source three times for no real benefit (the viewer is always a desktop browser requesting HIGH anyway). This addresses the tech-debt item already logged. Set on `BufferCaptureOptions` (need to confirm exact knob).
- **Keep the front-camera path as a selectable source, not throw it away.** The natural use is A/B-comparing publish quality from the two cameras (phone front vs glasses POV) — and discarding working code to enforce purity is silly. Cost is one extra file (`FrontCameraSource.swift`) and a SwiftUI Picker; benefit is a real comparison tool that survives into v0.06+.
- **Codec `.raw`, not `.hvc1`.** v0.7 also exposes `.hvc1` (HEVC `CMSampleBuffer`, foreground+background), which we could in theory hand to LiveKit as encoded data and skip its re-encode. But LiveKit's `BufferCapturer` expects *decoded* pixel buffers — feeding HEVC samples would mean writing a custom encoded-track path. Out of scope for v0.05. Stick with `.raw`; LiveKit's WebRTC re-encodes (typically VP8 or H.264) for transport. Note: `.raw` only delivers frames while the app is foreground — that's fine for prototype use.
- **Registration is a separate, explicit user action, not auto-triggered on launch.** Auto-registration would open Meta AI on every cold start until the user completes the dance. Surface the button; let the user tap it.
- **Use the existing free Apple ID provisioning.** Defer the $99 Developer account unless WDAT throws a code-signing or entitlements error that requires it. The README's prereq list calls this out — step #5 is the moment to find out.

## Open questions

- **Does free Apple ID provisioning support `external-accessory` + `bluetooth-peripheral` + `bluetooth-central` background modes?** These are typically allowed without paid entitlements, but some MFi-related entitlements are paid-only. If the build fails signing, we either pay $99 or strip the background modes (we don't need background for the prototype anyway — `.raw` codec only delivers in foreground).
- **`videoFramePublisher.listen` thread.** Not documented; every official sample wraps the callback in `Task { @MainActor in … }`, which strongly implies background-queue delivery. For our LiveKit bridge we *don't* hop to MainActor — we push synchronously into `BufferCapturer.capture(_:)` inside the callback. Verify under load (24fps for ≥30s) that this doesn't stall whatever queue WDAT uses, by checking for dropped frames or backpressure in Instruments.
- **Picker UX while glasses-gate is incomplete.** When the user selects `.glasses` but hasn't registered or granted camera permission, what does the UI show? Options: (a) keep the Connect button hidden until both gates pass; (b) show Connect but make it call out which gate is blocking; (c) inline the gate buttons as a step list above Connect. Lean (c) — clearer than (a), less hidden state than (b).
- **First-frame wait before `publish(videoTrack:)`.** LiveKit's `BufferCapturer` source comment says "at least one frame must be captured before publishing". The natural ordering (start DAT stream → wait for first event → publish) handles it, but the exact mechanism — a `CheckedContinuation` resumed by the first `listen` callback? a small `AsyncStream`? — is an implementation detail to settle when writing `GlassesSource`. Either works; pick the simpler one.
- **Hinge-fold recovery loop.** v0.7 docs say to re-`createSession` after `addLinkStateListener` fires `.connected` again — the original session is terminal once `.stopped`. Implementation question: does the user re-tap Connect, or do we attempt automatic resumption? Lean manual: a "Device disconnected — Reconnect?" prompt. Auto-resume is the kind of thing that misbehaves silently and is hard to debug in a prototype.
- **Audio.** Out of scope for v0.05 per README — explicitly v0.06. No `NSMicrophoneUsageDescription` change, no `MWDATAudio` (does it even exist yet?), nothing.

## Done criteria

1. App builds and installs on the iPhone via free Apple ID provisioning. If it doesn't, the open question about paid Developer accounts resolves itself.
2. Source picker offers `Front camera` and `Glasses`. Selecting `Front camera` skips WDAT entirely and reproduces step #4 behaviour.
3. First launch with `Glasses` selected: `Wearables.configure()` succeeds. Registration button visible. Tapping it opens Meta AI; approval round-trips back to the app via the `wazaproto://` URL scheme. `registrationStateStream` reaches `.registered`.
4. Camera-permission flow: button enabled. Tapping it opens Meta AI; user grants; `checkPermissionStatus(.camera)` returns granted.
5. With glasses donned and paired to Meta AI, tapping Connect (source=glasses):
   - Creates a DeviceSession that reaches `.started`.
   - Adds a Stream that reaches `.streaming`.
   - Pushes frames into LiveKit's `BufferCapturer` via `frame.sampleBuffer`.
   - Publishes the track to the room.
6. Browser viewer (with a fresh viewer token from `mint-token.sh viewer`) shows the **glasses' POV** — confirmed by waving a hand in front of the user's face and seeing it on the laptop in another room.
7. Latency is qualitatively sub-second end-to-end. Visual quality of glasses feed is documented side-by-side with the front-camera feed (this is the A/B point).
8. Closing the glasses' hinges produces a clean `.stopped` state in the UI, the viewer goes to "waiting for video", and reopening + tapping Reconnect works without restarting the app.
9. Disconnect button cleanly tears down: Stream → DeviceSession → LiveKit track → Room. Switching the picker after disconnect lets the user reconnect with the other source.

## Decisions logged during implementation

- **`AutoDeviceSelector` must be a persistent property whose `activeDeviceStream()` is being consumed before `createSession` is called.** Constructing it inline as a throwaway argument produces `DeviceSessionError.noEligibleDevice` even when `link=connected` and `compat=compatible`. The SDK only tracks per-device eligibility while *something* is iterating that stream. See `facebook/meta-wearables-dat-ios#148` and the `DeviceSessionManager.swift` pattern in the `CameraAccess` sample. Lives on `GlassesGateway` (long-lived `ObservableObject`), with `selectorTask` consuming `activeDeviceStream()` started in `startObserving()`. The resolved `activeDeviceID` is exposed on the gateway and gates `isReady` — if the SDK hasn't picked a device, Connect stays disabled.
- **Console-attached launch is the fast debug channel for runtime DAT behavior.** `xcrun devicectl device process launch --console --terminate-existing --device <udid> com.vincent.WazaProto` streams the app's stdout to the controller terminal until the channel drops (which it does when the screen sleeps or the app backgrounds). `print("[glasses] …")` traces in `GlassesGateway` / `GlassesSource` cover state-stream transitions, `activeDevice` resolution, and each `publish()` step. Strictly better than screenshot-driven debugging for everything except the initial UI gate.
- **Session start path matches the sample app's TaskGroup pattern**: race `stateStream` vs `errorStream` so any error event raised during `start()` surfaces with type info instead of waiting for a `.started` that may never come.
- **Live source swap requires explicit `publish(videoTrack:)` + `unpublish(publication:)`, not LiveKit's `setCamera(enabled:)` convenience.** `setCamera(enabled: false)` calls `publication.mute()`, not `unpublish()`, for the `.camera` source slot — so a glasses → front → glasses round-trip leaves a stale, muted camera publication that won't restart its capture pipeline cleanly. Symptom: viewer goes black on the swap-back and only recovers on page refresh. `FrontCameraSource` builds the camera track manually and tears it down via `unpublish(publication:)`. See note: `livekit-setcamera-mutes`.
- **Hinge-fold teardown via a session watchdog.** `GlassesSource` starts a `watchdogTask` after first-frame that observes the live `stateStream` / `errorStream`; on `.stopped` or any error it fires `onTerminated` → `RoomConnection.handleGlassesTerminated()`, which unpublishes the track, disconnects the room, and parks status at `.failed("Glasses session ended — unfold and reconnect")`. Without this the iPhone preview and the browser viewer both freeze on the last-rendered frame when the user folds the glasses.
- **`cameraPermission` doesn't demote on transient `nil`.** `checkPermissionStatus(.camera)` returns `nil` when the SDK can't reach the glasses (e.g. mid hinge fold) — initially we read that as "permission lost" and showed the Grant gate, which was misleading. `refreshCameraPermission` now only writes the new status if it's non-nil or we hadn't seen `.granted` yet. Result: gate surfaces on fresh registration (`nil` with no prior `.granted`) and on real `.denied` revocations, but rides through transient drops.
- **Stuck on Developer Mode (`MetaAppID = 0`, no `ClientToken`)** for v0.05. Registering a real Meta Wearables Developer Center app would commit a long-lived `ClientToken` bearer credential to git for no functional benefit (we don't use DAM/Display, and our blast radius is one phone + one user). Switching to a registered app is a 5-line Info.plist edit when distribution requires it. Note: switching app identity invalidates the previous registration — must `Wearables.shared.startUnregistration()` first; that single call also removes the entry from Meta AI's Connected Apps list (see note: `dat-unregister-is-one-step`).

## Vincent's learnings

- **Console-attached deploy beats screenshot-driven debugging.** `xcrun devicectl device process launch --console --terminate-existing` streams `print()` traces from the iPhone to my terminal in real time. Most of the WDAT lifecycle bugs in this step (the `noEligibleDevice` selector lifecycle, the hinge-fold session-terminated path, the Developer-Mode-permission-nil bug) were diagnosed from the trace in one shot, where the previous loop was "deploy → screenshot → guess". Channel drops when the screen sleeps or the app backgrounds, so for flows that route through Meta AI (registration, camera grant) you lose visibility during the round-trip; relaunch the console after the user returns.
- **A/B vs the iPhone front camera is unambiguous and damning.** Front camera at LiveKit defaults: crisp, fluid. Glasses at `.high`/30 over BT with `.raw` codec: noticeably lower resolution and choppy. The bottleneck isn't WebRTC or the LiveKit pipeline — it's the BT link between glasses and phone carrying uncompressed NV12. Logged to tech debt; the real fix is the DAT `videoCodec: .h264` path, which requires a LiveKit encoded-track surface we didn't want to build for v0.05.
- **The `BufferCapturer` "first frame before publish" requirement is real and easy to miss.** Naive ordering (publish first, then start the DAT stream) silently times out resolving track dimensions. The right order — `addStream` → `listen` → `await stream.start()` → wait for one frame → `publish` — is codified in `GlassesSource.publish()` and worth preserving.

## Tech debt opened

- [Glasses stream: bitrate / codec headroom](../completed/17-encoded-freeze-recovery.md) — `.raw` codec over BT was the bottleneck; the fix was the H.265 path into a LiveKit encoded-track surface. Lineage tracked through plans 15–17; the re-encode-vs-pass-through trade-off is settled there (re-encode shipped as the default).
- [iOS publisher: SwiftProtobuf duplicate class warnings](../tech-debt/ios-publisher-swiftprotobuf-duplicate-warnings.md) — MWDATCore statically links SwiftProtobuf which collides with LiveKit's SPM-resolved copy. Benign but spammy at launch; vendor-side fix.
