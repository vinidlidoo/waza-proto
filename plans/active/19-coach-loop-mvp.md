# 19 — Coaching loop MVP (thin vertical slice)

First feature of epic [Shu — AI coach v0](shu-ai-coach-v0.md). The thinnest end-to-end wiring that produces a *coaching experience*: an AI that watches the glasses POV live and talks to the wearer.

## Goal

An AI agent joins the existing `waza-proto` LiveKit room, subscribes to the glasses video track, runs a realtime video model (Gemini Live), and **speaks running commentary on what the wearer is doing** — audible **through the glasses (A2DP)** and **in the viewer browser**. No task knowledge, no playbook, no proactivity logic yet. Just prove the loop closes.

## Why this slice first

It de-risks the three things we actually don't know, before we invest in the playbook pipeline (feature 2) or the proactivity engineering (feature 3):

1. **Does the glasses feed reach a cloud model at usable quality?** Our feed is H.265 @ 4 Mbps re-encode; frame sampling caps what the model sees.
2. **Is end-to-end voice latency tolerable at hand distance?** glasses → phone → LiveKit Cloud → agent → model → voice → back to glasses. Each hop is sub-second; they stack.
3. **Does coach audio actually play through the glasses over the shared BT link, while camera video is streaming?** This is the load-bearing unknown — see Open questions.

If all three are green, the rest of the epic is "make the coach smart." If #3 fails, the audio-out design needs rethinking (phone/earbuds only, or a different routing).

## Scope (sketch — settle when scoping)

- **Agent runtime — OPEN, decide first (separate dig, not baked in here).** Candidates noted, not chosen:
  - **Python `livekit-agents`** — first-class Gemini Live plugin, `RoomOptions(video_input=True)` auto-delivers frames, built-in `video_sampler`. Most batteries-included, but 3.1 Flash Live has documented compat limits in this SDK.
  - **Node `@livekit/agents`** — same framework, JS.
  - **Roll our own room participant** — a plain LiveKit server-SDK client that subscribes to the track and drives the Gemini Live socket directly. Most control, most code.
  - The choice gates almost everything below; settle it before writing code.
- **Model:** `gemini-3.1-flash-live-preview`, live video enabled. Keep the model id a one-line config so OpenAI Realtime can be swapped in for A/B.
- **Video sampling:** start conservative to bound cost (low fixed fps, low/medium `media_resolution`) — the default voice-activity sampler assumes a talking user, which we don't have yet. Tune in feature 3.
- **Coach behavior:** a generic system prompt — "describe what the wearer is doing, briefly, as it changes." Deliberately dumb; this slice tests plumbing, not coaching.
- **Audio out:**
  - Agent publishes its audio track to the room. Viewer browser already subscribes → just play it.
  - iPhone routes playback to **glasses via A2DP** by default, with a **settings toggle** for phone speaker/earbuds. Output-only for now (learner doesn't talk back until feature 4).
- **Agent identity / auth:** the agent needs its own LiveKit token (server-side). Reuse the Vercel token-mint path or a dedicated agent identity — decide with the runtime.

## Open questions (defer until scoping)

- **Agent runtime** (above) — the first decision.
- **Audio-session interplay on iPhone.** The app already runs an `AVAudioSession` for background streaming (plan 07) and publishes a mic track. Adding coach *playback* routed to BT glasses (A2DP) has to coexist with that session category (`.playAndRecord`) and the active DAT camera stream. The spec's "configure HFP fully *before* starting streaming" ordering caveat applies even though we're A2DP-first.
- **Shared-BT-link behavior (the big risk).** Does A2DP playback to the glasses degrade the camera video on the same BT link (the burstiness root-caused in plans 11/12, the PLI sensitivity in plan 17)? Must observe directly, not assume.
- **Track identification.** The glasses publisher uses track name `glasses-camera` (plan 05). Confirm the agent subscribes to the right track and ignores the front-camera track if present.
- **Latency measurement.** How do we quantify the round trip — a visible event (hand wave / finger count) and stopwatch to spoken response? Good enough for a qualitative gate.
- **Cost containment.** Gemini's default turn coverage includes *all* video frames; continuous watching can run up tokens. Bound fps + resolution from the start.
- **Where the agent runs.** Local dev machine vs a deployed worker (LiveKit Cloud agents / a small VM). Local is fine to start.

## Done criteria

1. Agent joins the `waza-proto` room and subscribes to the **glasses** video track (not the front camera).
2. The model demonstrably receives frames (verify via logs / input transcript).
3. The agent **speaks** running commentary that tracks what the glasses see — confirmed by changing the scene (wave a hand, hold up fingers) and hearing it described.
4. Coach audio is audible in the **viewer browser**.
5. Coach audio is audible **through the glasses** (A2DP), with a settings toggle that switches output to the **phone speaker/earbuds**.
6. End-to-end voice latency is measured qualitatively and recorded (the number that decides whether fast-twitch tasks are ever in scope).
7. **Shared-BT-link finding recorded:** does the glasses video visibly degrade while the coach is speaking? (Pass = usable; the answer shapes feature 4 and possibly the audio-out design.)
