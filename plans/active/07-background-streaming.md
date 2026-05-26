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

### 1. Enable background execution for the LiveKit upstream

Add to `Info.plist`:

- `UIBackgroundModes` = `["audio"]` (and possibly `["voip"]` — verify which one LiveKit's WebRTC stack expects to keep the connection alive)
- Justification string if Apple flags it during review (irrelevant for dev builds, document for posterity)

LiveKit Swift SDK should "just work" once the system stops suspending the app — the `Room` and its peer connection are already long-lived objects. Verify against the SDK's background-mode docs and any sample app code.

The trick is that `UIBackgroundModes = ["audio"]` is technically dishonest for a video-only publisher. Two alternatives to evaluate:
- Publish a silent audio track alongside video — turns "audio" mode into truthful, lets us keep the capability without lying to Apple
- Use `voip` mode + CallKit — heavier (PushKit, call object lifecycle), but the legitimate fit for "this is a live A/V session"

For v0.07 we go with whichever works in the simplest test; refactor to honest-mode in a follow-up if review feedback (or our own taste) demands it.

### 2. DAT session survives suspension

The DAT SDK's `DeviceSession` runs on a `WearablesInterface` that talks to glasses over Bluetooth and processes incoming frames. Two questions:

- Does the `videoFramePublisher.listen { ... }` callback keep firing while backgrounded? If yes, frames keep flowing into the `BufferCapturer` and LiveKit publishes them as normal. If no, we need to find an SDK hook to keep the session warm.
- Does `AutoDeviceSelector`'s reconnection loop survive backgrounding? If the user toggles glasses on/off while phone is backgrounded, do we still get the device-change events?

Likely both work fine with the background mode enabled — Bluetooth + network are both background-allowed APIs, and the DAT SDK doesn't gate on UIApplication state. But this is the most likely place for a surprise, and is what the testing in §Done criteria is structured to expose.

Possible mitigation if frames stall: capture-side keepalive (publish a transparent 1×1 frame every N seconds when no glasses frame has arrived), watchdog-restart the DAT session if `videoFramePublisher` goes silent for >5s.

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
- **`UIBackgroundModes = ["audio"]` is the simplest hypothesis.** Try it first. If WebRTC doesn't survive, escalate to `voip` + CallKit. Don't add CallKit speculatively — the surface area (PushKit, providers, call updates) is large and meaningful to test.
- **No silent-audio-track upfront.** Try without it. If `["audio"]` is rejected by review or fails to keep the connection alive without an actual audio track, add one — but the cost (an unused upstream track on every viewer) is real, so prove it's needed first.
- **Don't change the `BufferCapturer` or `GlassesSource` lifecycle.** The bet is that backgrounding just works with the right plist flag + DAT SDK behavior. Refactors come only if the bet loses.

## Open questions

- Which of `audio` / `voip` actually keeps the LiveKit WebRTC PeerConnection from being suspended? Need to test or find authoritative docs (the LiveKit Swift SDK README/docs likely cover this).
- Does the DAT SDK keep delivering frames in the background, or is there a Wearables session that suspends? Worth grep-ing the SDK or asking the wearables-dat MCP.
- What's the right UX when source=frontCamera and user backgrounds the app? Three options: (a) pause publishing silently and resume on foreground; (b) show a notification "front camera paused — return to app or switch to glasses"; (c) leave a placeholder frame ("camera paused" graphic) so viewers know it's intentional. Default to (a) unless testing reveals viewer confusion.
- Does screen lock count as backgrounding for the camera-access restriction? Glasses-source shouldn't care (it's not using the phone camera), but worth testing explicitly since lock-screen is the common case ("user puts phone in pocket while wearing glasses").
- Battery / thermals: how much hotter does the phone run while backgrounded-publishing for 10+ minutes? Could be a tech-debt item if it's bad enough to throttle.
- Does the LiveKit JWT in `Secrets.swift` (6h TTL) need a refresh path before we trust long backgrounded sessions? Today the publisher JWT is regenerated manually via `refresh-secrets.sh` — fine for demos, but a backgrounded stream that runs for 6+ hours hits expiry. Out of scope, but flag for tech debt.

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
