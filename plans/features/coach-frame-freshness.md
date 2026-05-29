# Shrink coach frame-staleness

**Surfaced during plan 19 (Conversational coaching MVP), live test #2, 2026-05-29.** Not in scope for plan 19 — tracked here for a future rung. Vincent flagged this as the single make-or-break UX lever for the coaching epic.

## Problem

When the learner asks "what do you see now?", the coach often answers about what the camera saw **1–2 seconds before** the question finished. For a hands-on coach reacting to what you're doing *right now*, that lag is the difference between useful and frustrating — and it gets worse for any fast-twitch task.

## Suspected causes (stacked)

1. **Pipeline video latency** — glasses → DAT Bluetooth → iPhone (HEVC decode + plan-12 smoothing buffer, ~66 ms at depth 2) → LiveKit re-encode (H.265 @ 4 Mbps) → LiveKit Cloud → agent subscribes. Each leg adds delay before the agent even has the frame.
2. **Gemini Live's hard 1 fps video cap.** The freshest frame the model holds can already be ~1 s old purely from the sampling cadence (`VoiceActivityVideoSampler` at `speaking_fps=1.0`), and the API won't accept faster.
3. **Turn-start frame selection.** The model appears to ground its answer on frames from when the learner *began* the turn (1–2 s before they finish), not the latest frame. 3.1's `TURN_INCLUDES_AUDIO_ACTIVITY_AND_ALL_VIDEO` coverage may interact here.

## Directions to explore

- Measure end-to-end glass→model freshness directly (timestamp a visible event, see when the coach reacts).
- Trim pipeline latency: revisit the plan-12 smoothing depth, re-encode settings, sampler cadence.
- Investigate whether a different turn-coverage / sampling config makes the model key off the *latest* frame.
- Compare models head-to-head on freshness (3.1 felt fresher than 2.5 in test #2 — understand why).

## Prereq

Plan 19 shipped (the working coach loop this builds on).
