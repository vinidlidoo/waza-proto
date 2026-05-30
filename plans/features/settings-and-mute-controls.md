# Settings menu, mute controls & pause

Forward-looking feature doc (backlog — not scheduled). Surfaced 2026-05-30.

A top-left **settings button** on the iOS publisher that collects audio mute toggles (viewer
talk-back and the wearer's own mic) alongside the relocated "Copy viewer link" action — plus a
**pause** control that suspends the broadcast without leaving the room.

## Problem / motivation

The publisher's corner controls (laid out in [24 — full-bleed streaming UI](../completed/24-full-bleed-streaming-ui.md))
are filling up. Today the **top-left** corner is just a hidden long-press debug hot corner, the
**top-right** `audienceCluster` carries both "N watching" and the copy-link button, and the bottom
corners hold the source switcher, play/stop, and coach buttons. There's no in-app control over
audio in either direction even though both directions now carry it:

- The publisher **publishes a mic track** — load-bearing for backgrounding ([07 — background streaming](../completed/07-background-streaming.md))
  and for the learner talking to the coach ([19 — conversational coaching MVP](../completed/19-coach-loop-mvp.md)).
- The publisher **subscribes to remote audio** — the coach's voice (plan 19, routed to the glasses
  over A2DP) and viewer talk-back ([26 — viewer talk-back](../completed/26-viewer-talkback-audio.md)).

And there's no way to step away mid-session: the only "stop sending" today is Stop, which *closes
the room* ([23 — room close on disconnect](../completed/23-room-close-on-disconnect.md)) and kicks
everyone. A pause that holds the room open fills that gap.

## Sketch

### Settings menu (top-left)

- **Settings button** (gear) pinned top-leading; tap → menu / sheet. (Reuses the corner the debug
  hot corner occupies — decide how the two coexist.)
- Menu contents:
  - **Mute viewers** — mute *only* viewer talk-back (plan 26). The coach (plan 19) **and** the
    wearer's own mic stay audible. (Resolved 2026-05-30.)
  - **Mute my mic** — **mute, not unpublish** the wearer's outgoing mic so viewers/coach stop
    hearing the wearer. Muting (not dropping the track) keeps the coach interaction and plan-07
    backgrounding intact. (Resolved 2026-05-30 — note this is the *inverse* of plan 26's viewer
    side, where the mic must be *unpublished* to clear the OS recording indicator.)
  - **Copy viewer link** — relocated here from the top-right `audienceCluster`.
- Clear on/off iconography; state survives the preview ↔ broadcasting transition.

### Pause (suspend without leaving the room)

A broadcast state *between* live and stopped: the publisher stops sending video but **stays
connected** — the room is not deleted, viewers and the coach stay in it, and resume is instant.

- **Mechanism:** mute (not unpublish) the video track, so the room/track/coach stay alive and the
  plan-23 close-room path is **not** triggered. Resume re-enables the same track. (Aligns with
  LiveKit Swift's `setCamera(enabled:false)` = mute, per the `livekit-setcamera-mutes` memory —
  here that mute behavior is exactly what we want.)
- **Viewer-side:** viewers stay in the room but see a "paused" / "host stepped away" state instead
  of a frozen last frame — reuse the messaging patterns from plan 25's "tap to resume" card and
  plan 13's status labels.
- **Placement:** likely a dedicated control near the bottom-center play/stop (a pause button beside
  Stop) rather than buried in the settings menu — pause is a primary action. Settle placement when
  scoping.
- **Distinct from:** Stop (closes the room, plan 23) and a network blip (auto-reconnect, no state
  change).

## Open questions (for Vincent)

- **Audio during pause.** When video is paused, does the mic / coach link stay live (you can keep
  talking to the coach while the view is paused), or does pause also mute the mic? Leaning
  video-only pause; confirm.
- **Pause placement.** Dedicated pause button next to Stop (recommended), or a menu item? And what
  glyph / color separates "paused" from "live" and "stopped" in the corner grammar?
- **Auto-resume vs. manual.** Does pause ever auto-resume (e.g. on app foreground), or always
  require an explicit tap?
- **Copy-link availability.** Today it's connected-only (lives in `audienceCluster`). Should the
  settings menu expose it pre-broadcast too, or stay connected-only?
- **Menu vs. sheet vs. popover** over a full-bleed viewfinder — which reads best without occluding
  the feed?

## Dependencies / related

- Control layout & corner grammar: [24 — full-bleed streaming UI](../completed/24-full-bleed-streaming-ui.md).
- Incoming audio sources: [19 — conversational coaching MVP](../completed/19-coach-loop-mvp.md) (coach)
  and [26 — viewer talk-back](../completed/26-viewer-talkback-audio.md) (viewers).
- Mic is load-bearing for [07 — background streaming](../completed/07-background-streaming.md).
- Pause must **not** trip the close-room path: [23 — room close on disconnect](../completed/23-room-close-on-disconnect.md).
- Viewer "paused" messaging can reuse the resume-card pattern from [25 — screen source](../completed/25-screen-source.md).
- Copy-link / invite flow: [06 — shareable viewer link](../completed/06-shareable-viewer.md).
- Mute mechanics: the `livekit-setcamera-mutes` memory (mute vs. unpublish) and the
  `livekit-swift-a2dp-audio-route` memory (audio route to glasses).
- Shares the pre-broadcast surface with [animated logo](animated-logo.md).
