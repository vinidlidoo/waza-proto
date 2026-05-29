# Shu — AI coach v0

**Epic.** First rung of turning the one-way POV stream into a *two-way coaching* experience — without a second human. An AI watches an expert demonstrate a manual task once, then coaches a learner wearing the glasses through the same task in real time, by voice.

Named for **Shu** (守) of *Shu-Ha-Ri* (守破離), the Japanese model of skill mastery: *follow the master's form* → *break from it* → *transcend it*. v0 is the Shu stage — the coach teaches you to follow an expert's form. Epics use the Shu-Ha-Ri scheme; the features under them keep the numeric plan numbering (this epic's first feature is plan 19).

## Why this epic

The original Waza concept is a remote expert seeing what you're doing and guiding your hands. Demoing that needs two people and two pairs of glasses. Substituting an AI coach lets us demonstrate the *core value* — real-time, hands-level feedback on a manual task — solo, and it gestures at the larger bet: training a coach from expert demonstrations so it can guide learners to the same outcome.

## The task

**Origami** (primary; e.g. a crane or a simpler box/boat), **specialised knot-tying** as the fallback (notoriously hard for the uninitiated). Chosen because the task must be:

- **Hand-/visually-driven and not reliably text-describable** — the whole point is conveying tacit knowledge text can't.
- **Error-compounding** — a wrong early fold cascades, so catching it *in the moment* is visibly more valuable than a post-hoc verdict. This is what sells "real-time."
- **Short, repeatable, mess-free, with a clear binary success state** the AI can verify.

## Decisions locked during planning (May 2026)

- **Coach model: Gemini Live (currently `gemini-3.1-flash-live-preview`, the newest realtime/Live model).** OpenAI Realtime (`gpt-realtime-2`) is the documented swap-in fallback; the model should be a one-line change so we can A/B on our own footage. Rationale and the honest caveats:
  - **Cost:** Gemini is ~5–10× cheaper on exactly the modalities we hammer continuously — video in ~$1/1M tok and audio in/out $3/$12 per 1M, vs OpenAI's image in ~$5/1M and audio $32/$64.
  - **Representation (documented, verifiable):** Gemini ingests video as a first-class modality with a dialable frame rate (1 fps default, up to ~10 fps), a `media_resolution` cost dial (~70 / 258 / 280 tok per frame), and **timestamp tokens** that anchor frames to `MM:SS`. OpenAI Realtime (per LiveKit's integration docs) injects each sampled frame as a discrete **image message into the conversation context**, which accumulates in and consumes the 128k window.
  - **Caveats (not asserted as fact):** "Gemini reasons about *motion* better" is a **hypothesis**, not a verified claim — training data is undisclosed for both. The legitimate support is published video benchmarks + the timestamp mechanism, and ultimately an **A/B on our origami footage** (feature 2 hands us a ready-made eval clip). 3.1 Flash Live is also a *Flash*-tier, *preview* model with documented LiveKit-Agents compatibility limits.
- **Two model surfaces, two jobs.** The realtime *coach* uses a **Live** model (3.1 Flash Live). The **offline** playbook extraction (feature 2) is not latency-bound and should use a heavyweight **batch** video-understanding model (Gemini 3 Pro / 3.5 Flash / Claude). 3.5 Flash and 3 Pro do video — via the File API, not the realtime Live socket.
- **Proactivity is engineered, not native.** No realtime model gives a turnkey "watch silently, interject the instant a fold goes wrong" mode. Gemini's `proactivity` flag (2.5 only; errors on 3.1) merely lets the model *decline* to respond to irrelevant input — it does not *generate* unprompted coaching. We build the cadence ourselves: drive a periodic/triggered silent eval turn ("reply only if there's a correction or a step just completed, else `<silent>`") and suppress no-op turns. Lives in feature 3.
- **Prior knowledge = a structured playbook extracted from one expert demo.** Watch a perfect run offline → emit ordered steps · "what good looks like" · common error per step · the distinguishing visual cue → inject as the coach's system prompt. Supplement with text steps. Raw-video-in-context is a later enhancement. This is the form that embodies "train a coach from expert demonstrations."
- **Coach audio reaches the wearer via the platform Bluetooth stack — NOT a DAT API.** The DAT SDK exposes *no* audio output (its `Permission` enum is `.camera` + `.microphone` only; the only "playback" is video-on-HUD for Display devices). But the glasses are a standard BT audio device, so we route `AVAudioSession` to them. The official spec confirms "play audio to the user through the device's speakers" and documents two profiles:
  - **A2DP** — high-quality, **output-only**. Best voice fidelity; start here.
  - **HFP** — bidirectional but **8 kHz mono**; needed when the learner talks *back* (feature 4).
  - **Settings toggle:** glasses (BT) vs phone speaker/earbuds. The **viewer browser also plays** the coach (it already subscribes to the room — just play the agent's audio track).
  - **Risk to validate:** the spec warns DAT sessions *share* mic/speaker with the system BT stack ("configure HFP fully before starting streaming"). Camera video + coach audio share one BT link — adjacent to the burstiness/PLI work in plans 11/12/17.

## Features

- [ ] **19 — Coaching loop MVP (thin vertical slice)** → [`19-coach-loop-mvp.md`](19-coach-loop-mvp.md) — agent joins the existing room, subscribes to the glasses track, runs Gemini Live with live video, and speaks running commentary; audio out to glasses (A2DP) + viewer browser. No task knowledge yet. De-risks video-reaches-model, voice latency, and the audio-out path before any playbook work.
- [ ] **Expert playbook** *(doc TBD when picked up)* — record a perfect origami run from glasses POV; offline batch-model pipeline → structured playbook; inject as the coach's system prompt.
- [ ] **Proactive coaching behavior** *(doc TBD)* — the engineered silent-unless-correction eval loop + step tracking (tool calls) + frame-sampling / token-budget tuning. Where the "must engineer" work lives.
- [ ] **Two-way: learner asks the coach** *(doc TBD)* — switch to HFP so the glasses mic feeds the agent; learner can ask questions mid-task.

Knot-tying as a second task and demo-presentation polish are candidate `features.md` one-liners, not checklist items, until we want them tracked.

## Success criterion for the epic

A solo demo: don the glasses, and an AI coach — primed on one expert origami demo — talks you through completing the same model, catching mistakes as you make them, with its voice in your ears and an audience watching the same view (and hearing the same coaching) in a browser.
