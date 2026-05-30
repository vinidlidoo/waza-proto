# 25 — Phone screen as a fourth publish source (ReplayKit broadcast)

Today the publisher offers three sources — iPhone **front** camera, iPhone **rear** camera, and the **glasses** POV (`RoomConnection.Source` = `.frontCamera` / `.rearCamera` / `.glasses`). Add the **phone's screen** as a fourth source, so the bottom-left switcher blooms **Front · Rear · Glasses · Screen** and selecting *Screen* streams everything on the device — other apps included — to the viewer and the coach.

(Plan 24's full-bleed switcher already renders one pill per `Source.allCases`, so a fourth case adds a fourth pill for free. This plan is "feature 24" in conversation only — the next free plan number is **25**; plan 24 is the shipped UI rewrite.)

## Goal

A fourth switcher pill — a display/screen glyph — that, when selected and connected, publishes the **whole device screen** through the existing LiveKit room as the single live video track. Live-switching to and from Screen works without dropping the room (the `switchSource` flow). The broadcast keeps running when the user leaves Waza to show another app (this is the entire point). The phone stays the lone publisher — no second participant joins.

Two distinct "stops", treated differently (see *Two ways a screen broadcast ends*):

- **In-app Stop** — Waza's own red Stop button → full disconnect, the deliberate end-of-session.
- **Out-of-band stop** — the user ends the broadcast from iOS itself (the red status-bar/Dynamic-Island indicator, or Control Center). This is often *unintended* (a fat-finger, or they meant to do something else), so it must **not** kill the stream: the room, mic, and coach stay up; only the screen video drops, and the UI offers a one-tap resume.

### Prior art: this is exactly ChatGPT's Advanced Voice Mode screen share

ChatGPT's AVM "share your screen" uses the same machinery: a Broadcast Upload Extension + App Group, surfaced through the identical system **"Screen Broadcast → Start Broadcast"** dialog that `BroadcastManager.requestActivation()` triggers (the "Everything on your screen, including notifications, will be recorded. Enable Do Not Disturb…" copy is iOS-provided — we get it for free). The behavior we're matching: when the user stops the broadcast mid-session, **ChatGPT keeps the voice conversation alive** and simply stops seeing the screen. That confirms the out-of-band-stop decision above — the session persists; the screen feed is supplemental, not load-bearing on the connection.

## Why this slice — and why it's *not* just another `makePublisher` arm

The other three sources are in-process capturers: `CameraSource` wraps `createCameraTrack`, `GlassesSource` pumps DAT frames into a `BufferCapturer`. iOS **cannot** capture the system-wide screen from inside the app process. ReplayKit offers two modes, and only one does what "the phone's screen feed" means:

- **In-app capture** (`createInAppScreenShareTrack`, the default for `setScreenShare`) — captures **only Waza's own window**. For us that's the viewfinder rendering itself: a recursive hall of mirrors, useless. Rejected.
- **Broadcast capture** (`createBroadcastScreenCapturerTrack`) — captures the **entire device**, including other apps, via a separate **Broadcast Upload Extension** process. This is the one we want, and it is structurally heavier than every prior source: a new app-extension target, a shared App Group, IPC over a Unix socket, and a user-gated system picker to start.

So the source-layer abstraction still holds — Screen becomes one more `VideoPublisher` (`ScreenSource`) behind `makePublisher` — but the publisher's *lifecycle* mirrors `GlassesSource`, not `CameraSource`: an external process owns the capture, the publish is gated on a user gesture, and an out-of-band stop (Control Center) must tear the LiveKit side down. That parallel to the glasses watchdog (`handleGlassesTerminated`) is the design spine.

## How LiveKit's broadcast path actually works (verified against the vendored SDK)

Confirmed by reading `client-sdk-swift/Sources/LiveKit/Broadcast/*` and `LocalParticipant.swift:251-286,393-415`:

1. The **extension** (`LKSampleHandler` subclass) receives `CMSampleBuffer`s from ReplayKit and writes them to a Unix socket in the shared App Group container (`group.<bundleid>/rtc_SSFD`). It posts Darwin notifications `iOS_BroadcastStarted` / `…Stopped` around its lifecycle.
2. `BroadcastManager.shared` (in the **main app**) listens for those Darwin notifications and exposes `isBroadcasting` / `isBroadcastingPublisher`. `requestActivation()` pops the system broadcast picker; `requestStop()` posts a Darwin stop.
3. `LocalVideoTrack.createBroadcastScreenCapturerTrack(options:)` makes a `BroadcastScreenCapturer` (a `BufferCapturer`) that **reads** the socket on the main-app side and feeds the track. The main app publishes that track on its existing room — **the app is still the only participant**; the extension is just a sample pump.
4. By default (`shouldPublishTrack == true`) `LocalParticipant` auto-calls `setScreenShare(enabled:true)` when a broadcast starts, which races and bypasses our explicit publish bookkeeping. **We set `BroadcastManager.shared.shouldPublishTrack = false` and publish manually** so the screen track flows through the same `VideoPublisher.publish(to:)` / `unpublish(from:)` path as every other source, preserving the single-track invariant and `switchSource`/profiler/preview wiring.

Bundle-naming defaults (`BroadcastBundleInfo`): extension bundle id must be `<main>.broadcast`, App Group `group.<main>`. With `com.vincent.WazaProto` that's `com.vincent.WazaProto.broadcast` and `group.com.vincent.WazaProto` — so **no `RTCAppGroupIdentifier`/`RTCScreenSharingExtension` Info.plist overrides are needed** if we follow the convention. `hasExtension` (socket path resolvable + extension id present) is what gates the whole feature at runtime.

## Direction

1. **Add the extension target** (`WazaProtoBroadcast`, Broadcast Upload Extension) in Xcode. This is the one step that is *not* a free drop-in file: the main target's `PBXFileSystemSynchronizedRootGroup` auto-includes new files, but a new **target** must be created through Xcode (target, bundle id `com.vincent.WazaProto.broadcast`, embed-extension build phase, its own provisioning under team `ZA3LRD9PGM`).
2. **App Group on both targets.** Add the `App Groups` capability + `group.com.vincent.WazaProto` to the main app **and** the extension. This means the main app gains an entitlements file for the first time (`WazaProto.entitlements`, `CODE_SIGN_ENTITLEMENTS` build setting) and the extension gets its own.
3. **Extension code = three lines.** Replace the generated `SampleHandler.swift` with an `LKSampleHandler` subclass (`enableLogging = true` for Console troubleshooting). All sample-pumping/IPC is in the SDK base class.
4. **`ScreenSource.swift`** — a new `VideoPublisher` modeled on `GlassesSource`'s external-lifecycle + watchdog shape: request the picker, await broadcast-start, publish the broadcast track, and tear down on out-of-band stop.
5. **Add the `.screen` case** to `RoomConnection.Source` (+ `profileID`), wire `makePublisher`, set `shouldPublishTrack = false` once at startup.
6. **UI**: a fourth glyph in the switcher `extension`, `canConnect(.screen)`, and a **non-recursive preview placeholder** for the screen source (don't render the screen track into a `VideoView` that's on that same screen).
7. **No viewer change, no pipeline change, no coach change.** The screen track is an ordinary `screenShareVideo` track the viewer already renders like any other; the coach already subscribes to whatever video the publisher sends.

## Approach

### Extension target — `WazaProtoBroadcast/SampleHandler.swift`

```swift
import LiveKit

#if os(iOS)
@available(macCatalyst 13.1, *)
class SampleHandler: LKSampleHandler {
    override var enableLogging: Bool { true }   // surfaces in Console under category "LKSampleHandler"
}
#endif
```

The extension must link the same `LiveKit` package product as the app (add it to the extension target's "Frameworks and Libraries"). Keep the extension's deployment target ≤ the app's. No other code: `LKSampleHandler` owns `BroadcastUploader`, the socket, and the Darwin notifications.

### `ScreenSource.swift` (new) — `VideoPublisher`

The shape mirrors `GlassesSource`: an external process drives capture, so `publish` *awaits a start signal*, and we install a watchdog that fires when the broadcast ends out-of-band. Unlike the glasses fold (which kills the room), the screen watchdog only drops the *video* — `onEnded` keeps the session alive (see `handleScreenBroadcastEnded`).

```swift
@MainActor
final class ScreenSource: VideoPublisher {
    private let onEnded: () -> Void          // out-of-band stop only; in-app Stop goes through unpublish()
    private var publication: LocalTrackPublication?
    private var watchdog: AnyCancellable?

    init(onEnded: @escaping () -> Void) { self.onEnded = onEnded }

    func publish(to room: Room) async throws -> VideoTrack? {
        guard BroadcastBundleInfo.hasExtension else { throw ScreenSourceError.extensionMissing }

        // User-gated start: pop the system picker, then await the extension's
        // broadcastStarted Darwin signal. Cancel/timeout if the user dismisses.
        if !BroadcastManager.shared.isBroadcasting {
            BroadcastManager.shared.requestActivation()
            try await awaitBroadcastStart(timeout: .seconds(30))   // throws on timeout → caller reverts
        }

        let track = LocalVideoTrack.createBroadcastScreenCapturerTrack(
            options: ScreenShareCaptureOptions(dimensions: .h720_169, fps: 15)   // 720p, see Key decisions
        )
        let pub = try await room.localParticipant.publish(
            videoTrack: track,
            options: VideoPublishOptions(simulcast: false)
        )
        publication = pub

        // Out-of-band stop (Control Center / status bar): drop the video but keep
        // the room. Suppress while WE are tearing down (unpublish() clears the
        // watchdog first) so an in-app Stop doesn't double-fire onEnded.
        watchdog = BroadcastManager.shared.isBroadcastingPublisher
            .filter { !$0 }
            .sink { [onEnded] _ in Task { @MainActor in onEnded() } }

        print("[screen] published \(pub.sid)")
        return track
    }

    func unpublish(from room: Room) async {
        watchdog = nil   // clear first → requestStop()'s false-event won't trip onEnded
        if BroadcastManager.shared.isBroadcasting { BroadcastManager.shared.requestStop() }
        if let publication { try? await room.localParticipant.unpublish(publication: publication) }
        publication = nil
    }
}
```

- `awaitBroadcastStart` = a `first(where: { $0 })` on `isBroadcastingPublisher` raced against a `Task.sleep` timeout (implement as a small `withThrowingTaskGroup` or `AsyncPublisher` + cancellation). A dismissed picker fires no event → timeout → throw → the existing `connect`/`switchSource` `catch` reverts (status `.failed`, teardown for fresh connect; revert for swap).
- `ScreenSourceError: LocalizedError` (e.g. `extensionMissing`, `broadcastNotStarted`) so `RoomConnection.failureMessage` surfaces user-actionable text in the message pill, exactly like `GlassesSourceError`.

### `RoomConnection.swift`

```swift
enum Source: String, CaseIterable, Identifiable {
    case frontCamera = "Front"
    case rearCamera  = "Rear"
    case glasses     = "Glasses"
    case screen      = "Screen"
    var id: String { rawValue }
    var profileID: String {
        switch self {
        case .frontCamera: return "frontCamera"
        case .rearCamera:  return "rearCamera"
        case .glasses:     return "glasses"
        case .screen:      return "screen"
        }
    }
}

// init() — once, after super.init(): suppress the SDK's auto-publish so the screen
// track flows through our explicit VideoPublisher path (single-track invariant).
BroadcastManager.shared.shouldPublishTrack = false

// makePublisher(source:)
case .screen:
    return ScreenSource(onEnded: { [weak self] in self?.handleScreenBroadcastEnded() })
```

`handleScreenBroadcastEnded()` — the gentle counterpart to `handleGlassesTerminated()`. It **keeps the room connected** (mic + coach untouched) and only drops the video, so an unintended Control-Center stop doesn't end the session:

```swift
private func handleScreenBroadcastEnded() {
    guard publisher is ScreenSource, case .connected = status else { return }
    Task {
        await stopProfiling(incomplete: true)
        if let publisher { await publisher.unpublish(from: room) }  // requestStop is a no-op (already stopped); unpublishes the track
        localVideoTrack = nil
        profiler.attach(to: nil)
        // Deliberately NOT cleared: room, mic, coach, publisher (stays ScreenSource
        // so a re-tap of the Screen pill re-pops the picker). status stays .connected.
        screenIdle = true   // drives the "resume" card; cleared on the next successful publish
    }
}
```

`screenIdle` is a new `@Published private(set) var` flipped false at the top of every `connect`/`switchSource` success and in `disconnect`. (Alternatively encode it as a `.connected` substate, but a flag is the smaller change.) Contrast with `handleGlassesTerminated`, which keeps its `room.disconnect()` + `.failed` teardown — a folded pair of glasses genuinely can't continue; a stopped screen broadcast can be restarted in place.

### `ContentView.swift`

- **Glyph** — add to the `RoomConnection.Source` extension:
  ```swift
  case .screen: return "rectangle.on.rectangle"   // or "iphone" / "display"
  ```
- **`canConnect(for:)`** — Screen is always *offerable*; the picker, not a pre-check, gates the actual start:
  ```swift
  case .frontCamera, .rearCamera, .screen: return true
  case .glasses:                           return glasses.isReady
  ```
- **Preview anti-recursion + resume card** — when Screen is the live source, rendering `connection.localVideoTrack` into the on-screen `VideoView` captures itself. Show a placeholder instead; when the broadcast was stopped out-of-band (`connection.screenIdle`), the placeholder becomes the resume affordance:
  ```swift
  if source == .screen, isConnected {
      if connection.screenIdle {
          screenResumeCard      // glyph + "Screen sharing stopped" + "Tap to resume" → selectSource(.screen)
      } else {
          screenShareCard       // glyph + "Sharing your screen" + "Tap Stop to end"
      }
  } else if connection.localVideoTrack == nil {
      wazaLogo
  } else {
      // existing LocalPreview branch
  }
  ```
- **Re-tap-to-resume** — after an out-of-band stop, `source` is still `.screen`, so `selectSource`'s `guard newSource != source` would swallow a re-tap. Relax it for the idle case so re-selecting Screen (via the card or the pill) re-pops the picker:
  ```swift
  // in selectSource(_:), before the equality guard
  if isConnected, connection.screenIdle, newSource == .screen {
      connection.switchSource(to: .screen, glasses: glasses); return
  }
  guard newSource != source else { return }
  ```
  (`switchSource(.screen)` with the still-`ScreenSource` publisher: `.switching` → `unpublish` old (no-op stop) → fresh `ScreenSource.publish` → picker. On success `screenIdle` clears.)
  (`mirror` already keys on `.frontCamera` only, so Screen renders un-mirrored — moot given the placeholder, but correct for the viewer.)
- `messagePill` and `glassesGateCard` are glasses-specific (`source == .glasses` guards) — **untouched**.
- The switcher bloom already iterates `Source.allCases`; four 44 pt pills + 10 pt spacing ≈ 216 pt tall from the bottom-left, clearing the top controls on iPhone 17. No layout change.

## Key decisions

- **Broadcast, not in-app, capture.** "The phone's screen" = the whole device; in-app capture only sees Waza's own window (and would render itself recursively). Broadcast is the only mode that satisfies the request, at the cost of an extension target + App Group.
- **Manual publish (`shouldPublishTrack = false`), not the SDK auto-publish.** Keeps the screen track on the same explicit `VideoPublisher` path as every other source, so `switchSource`, the profiler attach, and the single-track invariant all keep working unchanged. The auto-path would publish a track we don't own and race the swap.
- **External lifecycle modeled on glasses — but a gentler stop.** Picker-gated start ≈ "don the glasses". The *stop* diverges deliberately: a glasses fold is unrecoverable (→ `.failed`, room torn down), whereas an out-of-band screen stop is usually unintended and always recoverable, so it keeps the room and only drops the video (`handleScreenBroadcastEnded` → `screenIdle`). Mirrors ChatGPT AVM, where stopping the broadcast leaves the session running. Only Waza's in-app Stop ends the session.
- **Convention-default bundle ids** (`<main>.broadcast`, `group.<main>`) → no Info.plist `RTC*` overrides.
- **Encode profile = 720p @ 15 fps, `simulcast: false`.** Screen content is high-detail, low-motion: 15 fps is plenty and halves bitrate; 720p (`presetScreenShareH720FPS15`) is enough legibility for the demo and lighter than 1080p over the link. `simulcast: false` matches both camera and glasses publishers. (Tunable; revisit against real content.)
- **Device-only testing.** ReplayKit broadcast does not function meaningfully on the simulator — verification follows the existing worktree → `devicectl install`/`launch` flow on the iPhone 17.

## Done criteria

1. Switcher blooms **Front · Rear · Glasses · Screen**; the Screen pill shows a display glyph and is selectable when disconnected.
2. Connecting with Screen selected pops the system **"Start Broadcast"** dialog; tapping Start publishes the whole-screen track and the viewer sees the device screen. Dismissing the dialog reverts cleanly (no wedged `.connecting`).
3. Navigating away from Waza to another app keeps the viewer/coach receiving that app's screen (relies on plan 07's background-streaming knobs — **the key on-device verification**).
4. Tapping **Stop** in Waza ends the broadcast (the red indicator clears) and disconnects fully.
5. Ending the broadcast **out-of-band** (red status-bar indicator / Control Center) keeps the room, mic, and coach alive, drops the video, and shows the **"Screen sharing stopped — tap to resume"** card; tapping it (or the Screen pill) re-pops the picker and resumes. No orphaned track, no `.failed`, no disconnect.
6. Live-switching Screen ⇄ Front/Rear/Glasses works without dropping the room.
7. The local preview shows the **"Sharing your screen"** placeholder (no recursive self-capture) while Screen is live.
8. Existing iOS unit tests still pass; the `Source`-keyed switches are exhaustive (compiler-enforced).

## Risks / blind spots

- **Background survival is the load-bearing risk.** The screen track is published by the *main app* reading the IPC socket; if iOS suspends the app while the user is in another app, frames stop even though the extension keeps capturing. Plan 07 keeps the process alive via `UIBackgroundModes: audio` + an active mic `AVAudioSession` + `suspendLocalVideoTracksInBackground: false`. **Verify on device** that (a) the process keeps pumping the `BroadcastReceiver` loop backgrounded, and (b) the `false` flag, whose comment cites `.camera`-source suspension, also spares the `.screenShareVideo` source. If the source is still suspended, that's a one-line SDK-option follow-up, not a redesign.
- **`RPSystemBroadcastPickerView` is invoked via a private `buttonPressed:` selector** inside the SDK's `requestActivation()`. It works today but is the kind of thing Apple tightens; if a future iOS no-ops it, we'd embed a real picker button. Out of scope now — just flagged.
- **Extension target breaks the "no `project.pbxproj` edits" convenience** plans 22/24 enjoyed. The target, App Group capability, two entitlements files, and embed phase are real project mutations; the shared scheme / entitlements show as diffs that `merge-worktree`'s clean check will catch — commit them deliberately.
- **Aspect mismatch at the viewer.** The viewer box is locked 9:16 (plan 14); an iPhone 17 screen is ~9:19.5, so screen captures letterbox or crop in that box. Cosmetic, acceptable for v0; note if it reads badly.
- **Signing.** The extension needs its own provisioning profile under team `ZA3LRD9PGM`; `-allowProvisioningUpdates` should mint it, but first device build may need a Settings → trust pass.
- **App-audio capture is deliberately out of scope.** `ScreenShareCaptureOptions(appAudio:)` would mix device audio into the mic track; we keep the existing mic-only audio (the coach path depends on the mic) and stream screen *video* only.

## Tech debt / follow-ups

- The two teardown handlers now diverge meaningfully (glasses → `.failed` + disconnect; screen → keep room + `screenIdle`), so they're no longer worth collapsing — the small shared prefix (`stopProfiling` + `unpublish` + `localVideoTrack = nil` + `profiler.attach(nil)`) could be a tiny helper, but don't force a merge.
- Optional: a "Screen" entry in the profiler sweep if we ever want to characterize screen-encode quality the way plan 11 did for glasses.
- Revisit the encode profile (720p/15) against real demo content once seen on the viewer.
