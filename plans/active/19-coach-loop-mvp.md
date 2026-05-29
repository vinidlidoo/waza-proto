# 19 — Conversational coaching MVP

First feature of epic [Shu — AI coach v0](shu-ai-coach-v0.md). The thinnest end-to-end loop that produces a real coaching *conversation*: the learner asks, and the AI answers grounded in the live glasses view.

## Goal

An AI agent (Python `livekit-agents`) joins the existing `waza-proto` LiveKit room, subscribes to the glasses video track, and holds a **reactive voice conversation** with the wearer: the learner speaks ("show me how to make a crane", "what do I do here?", "did I get that right?"), and Gemini 3.1 Flash Live answers using the current view of their hands. The coach's voice is audible **through the glasses** and **in the viewer browser**. No expert playbook yet (generic model knowledge); no proactive interjections (the learner drives every turn — that's feature 21).

## Why this slice

It closes the loop end-to-end and de-risks the unknowns that gate everything after it:

1. **Does the glasses feed reach a cloud model at usable quality?** (H.265 @ 4 Mbps re-encode; the sampler caps how much motion the model sees.)
2. **Is the round-trip latency tolerable for natural conversation?** glasses → phone → LiveKit Cloud → agent → model → voice → back.
3. **Does coach audio play through the glasses, and does the learner's voice reach the agent, over Bluetooth — without starving the video link?**

The conversational framing is deliberate: reactive Q&A is the realtime models' native mode, needs no proactivity engineering, and works on 3.1 (whose programmatic levers are limited) precisely because every model turn is triggered by a learner utterance.

## Scope (sketch — settle when scoping)

- **Runtime:** Python `livekit-agents` (decided — native live video is Python-only). Runs locally in dev (`uv run agent.py dev` / `console`); deploy to LiveKit Cloud via `lk agent create` when needed.
- **Model:** `gemini-3.1-flash-live-preview` with `video_input=True`. Model id kept a one-line swap (OpenAI Realtime for A/B; 2.5 if we later need the programmatic levers).
- **Video sampling:** start conservative (low fps, low/medium `media_resolution`) to bound cost; tune later. Default sampler is 1 fps while the user speaks / 1 per 3 s otherwise.
- **Audio:**
  - **Out:** coach audio track → viewer browser (already subscribes) + iPhone routes to glasses via **A2DP** (hi-fi), with a settings toggle to phone speaker/earbuds.
  - **In:** learner's questions captured by the **iPhone mic** (hybrid path — keeps glasses on A2DP and mic off the BT link) and published to the room. Full-glasses HFP (8 kHz mono, bidirectional) is the alternative to test if the phone-mic path feels wrong.
- **Behavior:** a generic coaching prompt ("You are a hands-on coach watching the user's POV; answer their questions about the task they're doing, using what you see"). The learner's first utterance triggers the first turn.

### Stages

1. **Plumbing + latency spike.** Confirm frames reach the model, coach audio reaches the glasses (A2DP) + browser, and measure the round trip — with a minimal harness before wiring full turn-taking. (On 3.1 the model needs a spoken turn to talk, so this stage can use a single canned utterance.)
2. **Conversational loop.** Wire the learner mic → agent, turn detection, and the full ask/answer flow.

## Open questions (defer until scoping)

- **Audio-session interplay on iPhone.** The app already runs an `AVAudioSession` for background streaming (plan 07) and publishes a mic track. Routing coach playback to glasses A2DP while capturing the learner's voice on the phone mic, alongside the active DAT camera stream, needs its session category settled. (A2DP-out + phone-mic-in should avoid the HFP 8 kHz downgrade — verify.)
- **Shared-BT-link behavior.** Even with the mic off the BT link, does A2DP playback to the glasses degrade the camera video? (plans 11/12/17 contention.) Observe directly.
- **Which mic actually sounds right.** Phone mic (hybrid, hi-fi coach out) vs glasses HFP (hands-free + beamformed, but 8 kHz mono both ways).
- **Track identification.** The agent must subscribe to the `glasses-camera` track (plan 05), not the front camera.
- **Turn-taking feel.** Gemini Live's built-in VAD turn detection vs LiveKit's turn-detector model. Start with built-in.
- **Latency measurement.** A visible event (hand wave / hold up a fold) → spoken response, stopwatched. Good enough for the gate.
- **Cost containment.** Bound fps + `media_resolution` from the start; conversational turns are sparse so total cost is low, but 3.1's `ALL_VIDEO` turn coverage includes every buffered frame per turn.
- **Agent identity / auth.** The agent needs its own LiveKit token (reuse the Vercel mint path or a dedicated agent identity) — settle with deployment.

## Done criteria

1. Agent joins the `waza-proto` room and subscribes to the **glasses** video track (not the front camera).
2. The model demonstrably receives frames (logs / input transcript).
3. The learner can **speak a question** and get a **spoken answer that reflects the live view** — confirmed by holding up an object / partial fold and asking "what is this / what's next?".
4. Coach audio is audible in the **viewer browser**.
5. Coach audio is audible **through the glasses** (A2DP), with a settings toggle to phone speaker/earbuds.
6. End-to-end conversational latency is measured and recorded (decides whether the feel is natural — and whether fast-twitch tasks are ever in scope).
7. **Shared-BT-link finding recorded:** does glasses video visibly degrade while the coach speaks? (Pass = usable; the answer shapes the audio-path design.)
