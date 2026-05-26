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

With the plist set per §1 (`bluetooth-peripheral` + `external-accessory`) and the SDK being app-state-agnostic, the expected behavior is: backgrounding does not stop frame delivery, `videoFramePublisher.listen` continues firing, and the only state we might see is occasional `.paused` → `.running` transitions (which the existing code already handles).

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

## Decisions logged during implementation

*(Fill in as we go.)*

## Vincent's learnings

*(Fill in as we go.)*

## Tech debt opened

*(Likely: long-session JWT refresh, possibly a silent-audio-track workaround. Log to `plans/tech-debt-tracker.md` as it surfaces.)*
