# Shu — AI coach v0

**Epic.** First rung of turning the one-way POV stream into a *two-way coaching* experience — without a second human. A learner wearing the glasses converses with an AI coach ("show me how to do this" → "what do I do here?"), and the coach answers grounded in the live view of the learner's hands. v0 lands the conversational coach, primes it on one expert demo, and then adds the first proactive corrections.

Named for **Shu** (守) of *Shu-Ha-Ri* (守破離), the Japanese model of skill mastery: *follow the master's form* → *break from it* → *transcend it*. v0 is the Shu stage — the coach teaches you to follow an expert's form. Epics use the Shu-Ha-Ri scheme; the features under them keep the numeric plan numbering (this epic's first feature is plan 19).

## Why this epic

The original Waza concept is a remote expert seeing what you're doing and guiding your hands. Demoing that needs two people and two pairs of glasses. Substituting an AI coach lets us demonstrate the *core value* — real-time, hands-level feedback on a manual task — solo, and it gestures at the larger bet: training a coach from expert demonstrations so it can guide learners to the same outcome.

## The task

**Origami** (primary; e.g. a crane or a simpler box/boat), **specialised knot-tying** as the fallback (notoriously hard for the uninitiated). Chosen because the task must be:

- **Hand-/visually-driven and not reliably text-describable** — the whole point is conveying tacit knowledge text can't.
- **Error-compounding** — a wrong early fold cascades, so catching it *in the moment* is visibly more valuable than a post-hoc verdict. (This is what the proactive rung, feature 21, ultimately sells.)
- **Short, repeatable, mess-free, with a clear binary success state** the AI can verify.

## Why conversational-first

Realtime models are reactive by design: they respond to a spoken turn. A learner-driven conversation ("show me how" / "what now?") plays to that grain instead of fighting it, and it has three payoffs: it needs no proactivity engineering, it's cheaper (turns are sparse, not continuous watching), and it works cleanly on Gemini 3.1 Flash Live — whose programmatic-control limits don't bite when every turn is triggered by the learner's voice. Proactive correction (the coach volunteering "that's wrong") is the harder capability and the differentiator, so it comes *last* in v0, on top of a working conversational base.

## Decisions locked during planning (May 2026)

- **Runtime: Python `livekit-agents`.** Native live video input (`RoomOptions(video_input=True)` + the built-in `video_sampler`) is **Python-only** in the LiveKit Agents SDK — Node supports voice but not native live video. An agent joins the existing `waza-proto` room and subscribes to the glasses track. (Rolling our own outside the framework rebuilds room plumbing, sampler, turn detection, and deploy tooling for no gain.)
- **Coach model: Gemini Live, default `gemini-3.1-flash-live-preview` for the conversational rungs (19–20).** Reactive voice conversation, tool calling, and audio I/O work normally on 3.1; its lower latency makes the back-and-forth feel natural, and its default `TURN_INCLUDES_ALL_VIDEO` turn coverage auto-grounds each answer in the current view. The **proactive-correction rung (21) likely switches to `gemini-2.5-flash-live`**, because 3.1 ignores the programmatic levers (`generate_reply()`, `update_chat_ctx()`, `update_instructions()`) that timer-driven, unprompted coaching needs. Keep the model id a one-line swap; OpenAI Realtime is the documented A/B fallback (~4.7× the audio cost, frames-as-images vs native video).
- **Two model surfaces, two jobs.** The realtime *coach* uses a **Live** model. The **offline** playbook extraction (feature 20) is not latency-bound → a heavyweight **batch** video model (Gemini 3 Pro / 3.5 Flash / Claude).
- **Video representation (documented) vs claims (hypothesis).** Gemini ingests video as a first-class, time-anchored, rate-/resolution-tunable stream (1 fps default → up to ~10 fps; `media_resolution` ≈ 70 / 258 / 280 tok per frame; `MM:SS` timestamp tokens). "Understands *motion* better than OpenAI's frames-as-images" is a **hypothesis to A/B on our own footage**, not an asserted fact — feature 20's demo clip is the ready-made eval set.
- **Coach audio reaches the wearer via the platform Bluetooth stack — NOT a DAT API** (DAT exposes no audio output; its `Permission` enum is camera + microphone only). Conversational mode needs audio *both ways*, and classic Bluetooth forces one profile:
  - **Hybrid (preferred for the demo):** coach voice out via glasses **A2DP** (hi-fi), learner's questions in via the **iPhone mic** — sidesteps the HFP downgrade and keeps mic audio off the glasses BT link entirely.
  - **Full-glasses HFP:** hands-free + beamformed, but **8 kHz mono both ways**, and mic + video share the BT link (the plans 11/12/17 contention zone).
  - The **viewer browser also plays** the coach (it already subscribes to the room).
- **Prior knowledge = a structured playbook from one expert demo** (feature 20): ordered steps · what-good-looks-like · common error per step · distinguishing visual cue → injected as the coach's system prompt. Embodies "train a coach from expert demonstrations."
- **Cost is not a constraint.** LiveKit's free **Build** tier (1,000 agent-minutes + 5,000 WebRTC-minutes + 50 GB) covers dev and demoing at $0; all-in ≈ **$0.03/min (~$1.80/hr)** with Gemini tokens billed direct by Google. **Ship** ($50/mo) is only worth it near demo time, purely for cold-start prevention.

## Features

- [ ] **19 — Conversational coaching MVP** → [`19-coach-loop-mvp.md`](19-coach-loop-mvp.md) — the full reactive loop: a Python `livekit-agents` agent joins the room, subscribes to the glasses video, the learner asks by voice, and Gemini 3.1 Flash Live answers grounded in the live view; coach voice to glasses (A2DP) + viewer browser. Includes the learner-mic-in path (it's the trigger) and the audio-routing call. Coaches from generic model knowledge at this stage. Internally staged: plumbing/latency spike → full conversation.
- [ ] **20 — Expert playbook** *(doc TBD when picked up)* — record a perfect origami run from glasses POV; offline batch-model pipeline → structured playbook; inject as the coach's system prompt so guidance is expert-grounded, not generic. Delivers the "trained from a demonstration" thesis.
- [ ] **21 — Proactive correction** *(doc TBD)* — the coach volunteers "stop, that's wrong" *without being asked*: timer-/change-triggered silent evaluation that speaks only on a detected mistake or step completion. Needs the programmatic levers 3.1 lacks → revisit the model here (likely 2.5 Flash Live). The "must-engineer" rung; gated on 19.

Knot-tying as a second task and demo-presentation polish are candidate `features.md` one-liners, not checklist items, until we want them tracked.

## Success criterion for the epic

A solo demo: don the glasses, say "show me how to make a crane," and an AI coach — primed on one expert origami demo — guides you through it as a back-and-forth conversation grounded in your hands, **and** catches at least some mistakes as you make them, with its voice in your ears and an audience watching the same view (and hearing the same coaching) in a browser.
