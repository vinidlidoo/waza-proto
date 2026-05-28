# Audio-session-free backgrounding

**Goal.** Let the user stream POV from the glasses while simultaneously taking a Phone, FaceTime, WhatsApp, or other CallKit-managed VoIP call.

## Why this isn't possible today

Plan 07 made backgrounded glasses publishing work by activating an `AVAudioSession` (`playAndRecord` category) and publishing the iPhone mic to LiveKit. The mic-track itself is incidental; what's load-bearing is that an *active audio session* tells iOS "this app is doing audio work, don't suspend it." That keep-alive is what lets DAT frame delivery, LiveKit publishing (plan 07), and the TCP listener (plan 15) keep running while the app is in the background.

Phone calls and CallKit-managed VoIP apps grab a higher-priority, non-mixable audio session. iOS audio priority rules mean ours gets interrupted (`AVAudioSession.interruptionNotification(.began)`), the session deactivates, and the "audio is keeping me alive" thread snaps. About 30s later the app is suspended; the publish dies. Per Apple DTS (forum 774784): *"ANY incoming call will immediately interrupt your playAndRecord session. Since that active audio session is how your app is staying awake, the practical effect is that any incoming call will immediately terminate your call."*

This blocks the "wearer on a WhatsApp call, streaming POV to the other side" experience.

## The lightest plausible fix — BT/EA modes alone

`Info.plist` already declares `bluetooth-central` and `external-accessory` background modes (plan 07's stack). WDAT actively delivers frames over BT/EA the entire time the glasses are streaming — that's *active work* under those background modes. iOS may keep the app un-suspended on the strength of that traffic alone, without needing the audio session at all.

Plan 07 never tested this in isolation because the audio-session keep-alive definitely worked and shipping was the priority. If BT/EA traffic is sufficient on its own:

- Drop the `AVAudioSession` activation
- Drop the mic-publish (LiveKit audio track goes away — we don't use it)
- App stays alive on BT/EA work; the TCP listener (plan 15) keeps serving
- Phone calls and VoIP apps own the audio session uncontested
- Glasses streaming continues alongside the call

If BT/EA traffic *isn't* sufficient (iOS suspends despite the active BT link), we fall back to one of:

## Fallbacks

- **Silent mixable-playback `AVAudioEngine` loop.** `setCategory(.playback, options: [.mixWithOthers])` with a silent buffer. Keeps the audio background mode satisfied without contesting the mic. App Store review risk: the "audio mode with no real audio" pattern is on Apple's radar (Apple DTS, forum 822012, flagged it as "feels like an abuse").
- **CallKit integration.** Cleanest from iOS's perspective — CallKit sessions interoperate with other CallKit sessions by design. But CallKit is intended for VoIP calls, not video streaming; using it for "I'm publishing video" stretches its mandate and adds nontrivial integration work (CXProvider, call lifecycle UI, system-level interruption coordination).

## Validation steps (when we pick this up)

1. With glasses actively streaming via plan 15 pass-through, comment out the `AVAudioSession.setActive(true)` + the LiveKit mic publish. Background the app from the Home screen (not Xcode — debugger suppresses suspension).
2. Verify TCP listener keeps serving Annex-B HEVC to the LAN `lk` relay for ≥5 minutes backgrounded.
3. If yes: trigger a real Phone call mid-stream, confirm publish continues during and after the call.
4. If no: move to silent mixable-playback fallback; repeat tests.

## When to do this

When phone-call-while-streaming becomes a real product use case — not v0.x prototyping. Pairs naturally with whatever rung introduces "always-on POV" or "shared-experience calls."
