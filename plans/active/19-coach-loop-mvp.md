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

## Decisions logged during implementation

The agent lives in [`agent/`](../../agent/) — a `uv`-managed Python project, separate from `ios/` and `viewer/`. `just coach` / `just coach-console` run it; full notes in [`agent/README.md`](../../agent/README.md).

- **SDK versions pinned by `uv.lock`:** `livekit-agents==1.5.14`, `livekit-plugins-google==1.5.14` (`livekit-agents[google,images]~=1.5`). The `images` extra is required — the live-video path resizes/JPEG-encodes sampled frames via Pillow.
- **v1.5 server idiom, not the older `WorkerOptions`.** The current API is `server = AgentServer()` + an `@server.rtc_session()`-decorated entrypoint + `cli.run_app(server)`. Confirmed against the installed package, not memory.
- **Auto-dispatch (no `agent_name`).** `rtc_session()`'s `agent_name` defaults to `""`, which means the worker joins *every* new room. The demo uses one fixed room, so this is the simplest correct choice; gate with an explicit `agent_name` + dispatch rule only if we later need to.
- **Track selection is solved app-side, for free.** `video_input=True` streams "the single most recently published video track" — there is **no built-in track-name filter**. But the iOS app publishes exactly one video track at a time: `RoomConnection.switchSource` *fully unpublishes* the old source before publishing the new one, and `FrontCameraSource` deliberately uses `unpublish(publication:)` rather than mute (its own comment explains mute broke live swaps). So when the glasses source is selected, `glasses-camera` is the only video track and `video_input=True` picks it unambiguously. The agent logs the subscribed track name and **warns** if it isn't `glasses-camera` (done-criterion #1 verification). If we ever publish both feeds at once, the fallback is a custom `RoomIO` filtering by track name.
- **Model = `gemini-3.1-flash-live-preview`, confirmed limits are real.** Constructing the plugin's `RealtimeModel` with this id emits the documented warning that `generate_reply()` / `update_instructions()` / `update_chat_ctx()` won't apply mid-session, and proactive/affective audio are unsupported. The conversational design sidesteps all of these (every turn is learner-triggered). **No `generate_reply()` greeting on connect** — it would be ignored, and the learner speaks first by design. Model id is a one-line env swap (`COACH_MODEL`).
- **Conservative video sampling from the start.** `VoiceActivityVideoSampler(speaking_fps=1.0, silent_fps=0.3)` (the framework defaults, set explicitly + env-overridable) plus `media_resolution=MEDIA_RESOLUTION_LOW`. 3.1's `TURN_INCLUDES_ALL_VIDEO` bills every buffered frame per turn, so low fps matters more here than on 2.5.
- **Built-in turn detection** (Gemini Live VAD) — no Silero/LiveKit turn-detector plugin in Stage 1, per the plan. Revisit if turn-taking feels wrong.
- **Latency harness = state-transition stopwatch.** The agent times `user_state: speaking→listening` (learner stops) to `agent_state: →speaking` (coach starts) and logs `[latency] learner_turn_end -> coach_speaking = X.XXs`. Coarse but honest: it includes Gemini think+TTS and both network legs — exactly what "does it feel natural?" depends on. Satisfies done-criterion #6.

### Status (2026-05-28)

**Validated without hardware** (all green): deps resolve + install; `coach_agent` imports; the `AgentServer` CLI bootstraps (`console`/`dev`/`start`); `RealtimeModel` constructs with the exact 3.1 kwargs + `MediaResolution` enum; the sampler constructs. The agent is **run-ready**.

**Blocked on two things only I can't self-provision:**
1. **`GOOGLE_API_KEY`** in the repo-root `.env` (get one at <https://aistudio.google.com/apikey>). Nothing else is needed — LiveKit creds are already there.
2. **Glasses publishing video** — needs the iPhone app running with the glasses source selected.

Once both are in place: `just coach`, don the glasses, speak a question. Done-criteria 1–3 + 6 are then directly observable from the logs. Criteria **4, 5, 7 (audio routing through the glasses A2DP + browser, and the shared-BT-link finding)** are inherently hardware-in-the-loop and untouched by this code drop — they're the live-test agenda, and the audio-out-to-glasses path is an iOS-app concern (`AVAudioSession` routing) not an agent concern.
