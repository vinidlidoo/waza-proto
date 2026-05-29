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
- **TLS gotcha fixed in-code.** uv's standalone CPython ships with no system CA bundle (`ssl.get_default_verify_paths()` is empty), so the worker's TLS handshake to LiveKit Cloud failed with `CERTIFICATE_VERIFY_FAILED`. Fix: `os.environ.setdefault("SSL_CERT_FILE", certifi.where())` at startup (certifi is now an explicit dep). With it, the worker **registers against the real LiveKit Cloud project** — no shell setup needed.

### Status (2026-05-28)

**Validated without a Gemini key or glasses** (all green): deps resolve + install; `coach_agent` imports; the `AgentServer` CLI bootstraps (`console`/`dev`/`start`); `RealtimeModel` constructs with the exact 3.1 kwargs + `MediaResolution` enum (emitting the documented mid-session-update warning); the sampler constructs; and — the meaningful one — **`coach_agent.py dev` connects to our LiveKit Cloud and logs `registered worker`.** So the entire LiveKit leg (creds, URL, network, TLS, worker registration, plugin load) is proven end-to-end. The agent is **run-ready**.

**Blocked on two things only I can't self-provision:**

1. **`GOOGLE_API_KEY`** in the repo-root `.env` (get one at <https://aistudio.google.com/apikey>). Nothing else is needed — LiveKit creds are already there.
2. **Glasses publishing video** — needs the iPhone app running with the glasses source selected.

Once both are in place: `just coach`, don the glasses, speak a question. Done-criteria 1–3 + 6 are then directly observable from the logs. Criteria **4, 5, 7 (audio routing through the glasses A2DP + browser, and the shared-BT-link finding)** are inherently hardware-in-the-loop and untouched by this code drop — they're the live-test agenda, and the audio-out-to-glasses path is an iOS-app concern (`AVAudioSession` routing) not an agent concern.

### Live test #1 (2026-05-29, glasses + iPhone + browser)

First end-to-end run with the physical glasses. **The hard half works; the gap is audio playback, and it's now fully diagnosed.**

**Proven against real hardware:**

- ✅ Agent auto-dispatched to `waza-proto`, subscribed to the glasses track **by name** (`video track subscribed: name='glasses-camera'`, no wrong-track warning) — done-criterion #1.
- ✅ Gemini Live connected (`coach ready`), model received frames — #2.
- ✅ Learner mic reached the agent and was transcribed (`learner asked: 'Hello.'`) — half of #3.
- ✅ The coach generated a reply **and published its voice to the room** — confirmed via the LiveKit room API: participant `agent-…` (kind=AGENT) publishing an unmuted audio track `roomio_audio`.

**The gap — no client *plays* the coach audio (criteria #3 reply / #4 / #5):** the agent's voice is in the room; neither client renders it, because until the coach existed this was a *one-way video* system (the phone's mic track was published only to keep iOS's `AVAudioSession` alive — nobody ever listened). Root-caused on both sides:

- **Browser viewer:** `viewer/index.html` `RoomEvent.TrackSubscribed` handler early-returns on any non-video track (`if (track.kind !== Track.Kind.Video) return;`) — it never attaches audio. Definitive, small fix.
- **iOS app:** no remote-audio handling at all in `RoomConnection.swift` (publish-only) and no explicit `AVAudioSession` output routing. The Swift SDK may auto-render remote audio, but with no output routing it's inaudible — and getting it to the glasses over **A2DP** is the real work.

**Other observations:**

- **Latency is not yet trustworthy.** Readings were 11.45 s then 66.5 s — but contaminated: with no audible reply the learner kept talking, restarting the coach's turn. Re-measure once playback works. (First-turn 11 s likely includes session/model cold-start; watch whether steady-state turns are acceptable.)
- **API errors seen in AI Studio** (1× 400, 2× 409) were testing artifacts: the 400 was a `TEXT`-modality probe (audio-only model → 1007), the 409s were Live-session churn from talking over the silent coach. Not defects.
- **Auto-dispatch is a cost footgun.** The coach shares the `waza-proto` room with the e2e test suite, so *any* participant (a test publisher, a stray viewer) wakes it and opens a **billed** Gemini Live session. An idle registered worker costs ~nothing; an unintended session does. Gate it.

### Revised plan after live test #1 (2026-05-29, Vincent's direction)

**Priority order changed.** Build **iOS glasses audio first**, then make the coach reliable — and test reliability **through the glasses, not the browser viewer**. Rationale (Vincent):

- **Viewer audio is deprioritized**, not abandoned. When you're in front of the viewer *and* speaking through the glasses, the viewer's playback creates reverb/echo — so it's not the channel he'd actually use. (The viewer fix is done + committed; we'll revisit when it's useful.)
- **iOS work is self-contained in this worktree.** App changes build/deploy to the device locally (`devicectl`), with no Vercel involvement — so we iterate on the branch without tripping the `waza-proto` project's git-integration deploys (and without the two-project deploy mess hit during test #1).
- **Keep Gemini 3.1 Flash Live.** Too early to drop to 2.5. Fix the reliability cause directly first; treat a 2.5 swap as a last resort, not a first move.

**Ordered work:**

1. **iOS coach-audio playback + glasses routing** *(do first — task #6).* The substantive feature. Delivers #5; sets up testing the coach via the glasses.
2. **Coach response reliability** *(task #9)*, validated by hearing the coach **in the glasses** (no viewer → no reverb). Root-cause the ~30s input-track churn first; keep 3.1.
3. **Gate the coach's dispatch** *(task #7)* — explicit `agent_name` + dispatch, or a dedicated room, so it only runs when summoned (closes the auto-billing footgun; also stops e2e test runs from waking it).
4. **Re-measure latency** *(task #8)* once we can hear steady-state turns.
5. **Viewer audio** — already fixed/committed; finish the deploy story (it lives in the `viewer` Vercel project / git-integration previews, *not* a CLI deploy) when it becomes useful.

### Live test #2 (2026-05-29) — coach loop works end-to-end ✅

The full conversational loop runs on real hardware: **learner speaks → glasses POV → Gemini → spoken coach reply, audible in the glasses.** Done-criteria #1–#5, #7 met. What actually happened, vs. what we assumed:

- **The one real bug was the publisher token, not the model.** `viewer/api/publisher-token.js` granted `canPublish: true, canSubscribe: false` — the app was provisioned publish-only (it only ever published; viewers subscribed to *it*). With `canSubscribe: false` the LiveKit server delivered the app *nothing*, so the coach's `roomio_audio` never arrived. Symptom (transcribed-but-silent) looked identical to a model failure. Fix: `canSubscribe: true`.
- **3.1 was never broken at generation.** Earlier "3.1 doesn't generate" was confounded by the publish-only token (agent generated audio the app couldn't receive) — and we never captured a clean 3.1 debug turn before switching. With `canSubscribe: true`, **3.1 generates fine and is the snappier, fresher model** in practice (~3–5 s turns after a slower cold first turn; Vincent's direct read: noticeably fresher frames than 2.5). 3.1 is the committed default; 2.5-native-audio stays selectable via `COACH_MODEL`. (My earlier latency claim that 3.1 had a ~9 s floor was a bad generalization from one cold-start turn — disregard it; the research agent's secondhand "3.1 VAD bug" claims did not hold up against the hardware.)
- **Audio routes to the glasses over HFP (8 kHz) — and that's fine.** Voice was clear; HFP uses the glasses' own well-placed mic and is lighter on the shared BT link. The A2DP "hybrid" path was dropped: LiveKit's default engine observer hardcodes `.playAndRecordSpeaker` and **ignores `AudioManager.shared.sessionConfiguration`**, so forcing A2DP would need a custom `AudioEngineObserver` *and* would move capture to the phone mic — not worth it. The inert A2DP config was deleted; iOS keeps only audio-route diagnostic logging.
- **Local-dev token path (no production deploy):** the branch is behind main, so we served the `canSubscribe` fix via a local `vercel dev` (`viewer/`, `:3000`) and launched the app with `WAZA_VIEWER_HOST=http://<LocalHostName>.local:3000` (the DEBUG-only `Config.swift` override, ported from main; `.local` is ATS-exempt). The token change is **committed but NOT yet deployed to prod** — production still serves `canSubscribe: false`, so the coach only works against local dev until this ships.

**Revised next priorities (post-#2):**

1. **Frame freshness — THE headline UX problem (Vincent).** The coach often answers about a frame from **1–2 s before** the question finished. That's video staleness: glass→DAT-BT→iPhone→LiveKit→agent pipeline delay stacked on the Live API's hard **1 fps** video cap (and the model keying off turn-start frames). Shrinking this is the most important optimization for the app.
2. **Conversational latency** (task #8) — measured ~3–5 s typical on 3.1 (range ~3–10 s). Better than feared but still above natural; tune after / alongside freshness.
3. **Gate coach dispatch** (task #7) — still open; auto-dispatch bills a Gemini session for any room participant.
4. **Ship the `canSubscribe` token fix to production** when ready (currently local-dev only).

**Done-criteria closeout (2026-05-29):**

- **#7 shared-BT-link finding — RECORDED: no perceptible video degradation** while the coach speaks over HFP (Vincent, test #2). The shared BT link carries glasses video + HFP coach audio + HFP learner mic without a visible hit. This is the answer the criterion was waiting on — the HFP audio path is BT-link-safe.
- **#5 met with a deviation:** coach audio is audible through the glasses, but over **HFP (8 kHz), not A2DP**, and there is **no speaker/earbud toggle**. Rationale: HFP was clear for speech, uses the glasses' own well-placed mic, is lighter on the shared BT link, and (per #7) doesn't degrade video — while A2DP would've needed a custom `AudioEngineObserver` and moved capture to the phone mic. The A2DP + toggle scope is dropped, not deferred; revisit only if music-grade coach audio is ever wanted.
- **#4 (viewer audio):** code committed (`viewer/index.html` + the `canSubscribe` grant) but **not deployed to prod and not freshly re-verified with coach audio** — closes when the branch lands (ships the viewer-audio fix + token grant together).
- **#1, #2, #3, #6:** met (see test #2 above).

**To close the plan:** (a) land the branch via merge-worktree → deploys the viewer-audio fix, the `canSubscribe` token grant, AND the new `coach-dispatch` endpoint to prod; (b) ~~gating dispatch~~ **done** — pulled into this PR as a user-facing feature (see below). Then move this file to `plans/completed/` and update `plans/index.md`.

### Coach summon/dismiss + named agent (task #7, 2026-05-29)

Vincent pulled the auto-dispatch footgun into this PR as a real feature: a button to **summon** the AI coach and **dismiss** it. Shipped:

- **Named agent:** the worker now sets `agent_name="waza-coach"` → no longer auto-dispatched to every room, so the e2e suite / stray viewers can't wake a billed Gemini session. It joins **only when summoned**.
- **`viewer/api/coach-dispatch`** (authed with the same `ios-publisher` envelope): `summon` → `AgentDispatchClient.createDispatch`; `dismiss` → `RoomServiceClient.removeParticipant` on the `agent-` participant (ends the job, closes the Gemini session). Unit-tested.
- **iOS:** `CoachDispatchClient` + a single toggle button in `ContentView` (**Summon coach ⇄ Dismiss coach**) shown while connected, driven by coach presence (`agent-` identity in the room).
- **Verified** end-to-end against real LiveKit (summon dispatched the worker → `coach ready`; dismiss → `session closed`). Only the on-device button *tap* is still unexercised.

### Implemented — iOS glasses audio (task #6, 2026-05-29) — SUPERSEDED by test #2 above (A2DP dropped; real fix was the token)

**Shipped** (`RoomConnection.swift`): a one-time `AudioManager.shared.sessionConfiguration` set in `init()` to a **fixed** `AudioSessionConfiguration(category: .playAndRecord, options: [.mixWithOthers, .allowBluetoothA2DP, .allowAirPlay], mode: .videoChat)`. Compiles clean (simulator Debug build SUCCEEDED).

**Why this exact config** (verified against vendored SDK v2.14.1, not GitHub HEAD):
- The SDK's stock dynamic config `playAndRecordSpeaker` allows **both** HFP *and* A2DP. With HFP allowed, iOS treats the glasses as an 8 kHz bidirectional headset and steals the mic. **Allowing A2DP only** keeps output on the glasses' hi-fi sink and forces input back to the built-in phone mic (A2DP has no input profile) → the hybrid path, for free.
- `AudioManager.shared.sessionConfiguration` is the public **fixed-config** hook; it takes precedence over the SDK's dynamic logic and over `isSpeakerOutputPreferred`. A fixed config is correct here because we *always* publish a mic (plan 07) and *always* receive coach audio — no need for the dynamic playback-only↔playAndRecord switching.
- **No subscribe/attach code needed:** remote audio auto-subscribes (default `autoSubscribe`) and the SDK auto-renders it through the audio engine on iOS (unlike video, which needs `attach`). So the inaudible-coach bug was purely the session route, not missing subscription.

**Still to verify on device (inherently hardware — needs Vincent + glasses + phone, one clean pass):**
- Does `.videoChat` mode actually route output to the A2DP glasses? Voice-processing modes *can* refuse A2DP output on some iOS versions. **Fallback if not:** drop mode to `.default` (loses hardware AEC, but WebRTC's software APM still does echo cancellation). Picked `.videoChat` first to keep hardware AEC since the glasses speaker sits near the phone mic.
- Echo: coach plays near the user's ear, phone mic ~arm's length — confirm AEC handles it without the coach interrupting itself.
- Shared-BT-link: does A2DP playback to the glasses degrade the camera video (the task-#7 shared-link finding)? Observe during this test.
- A phone-speaker/earbuds fallback toggle is **not** built yet — deferred until the A2DP path is confirmed working.

### Gathered thoughts — iOS glasses audio (task #6 starting point)

**Goal:** the iOS app subscribes to the agent's remote audio track (`roomio_audio`) and plays it out the **glasses over Bluetooth A2DP** (hi-fi), with the learner's mic still captured on the **phone** (hybrid path — avoids the HFP 8 kHz downgrade). Phone-speaker/earbuds as a fallback toggle.

**What's known (from the codebase + live test):**
- `RoomConnection.swift` is publish-only — no remote-audio handling, and **no explicit `AVAudioSession` config** (grep found none). The mic is published at `RoomConnection.swift:77` only to keep an audio session alive for background streaming (plan 07).
- The agent **does** publish `roomio_audio` (unmuted) to the room — confirmed via the LiveKit room API during the live test. So the source side is done.
- On the phone the coach was inaudible: the LiveKit Swift SDK may auto-render remote audio, but with no playback-oriented session category/route it goes nowhere audible — and nothing routes it to the glasses.

**Likely approach (verify against the LiveKit Swift SDK before coding):**
- The key is the **`AVAudioSession` category + options**: for A2DP *output* while capturing the *phone* mic, the hybrid recipe is `.playAndRecord` with **`.allowBluetoothA2DP`** (NOT `.allowBluetooth`, which forces HFP and downgrades both directions to 8 kHz mono). With only `.allowBluetoothA2DP`, input stays on the phone mic and output can route to the glasses' A2DP sink.
- Determine **who owns the session**: LiveKit Swift's `AudioManager` manages `AVAudioSession` by default. Use its configuration hook (e.g. a custom configure func / `AudioManager.shared`) rather than fighting it. Need to confirm the exact API + how it composes with plan-07's background-streaming requirements (`suspendLocalVideoTracksInBackground:false`, `UIBackgroundModes`).
- Confirm remote-audio **auto-subscribe/auto-play** is on (default), so the only real work is the session/route + a settings toggle for output device.

**Files in play:** `ios/WazaProto/WazaProto/RoomConnection.swift` (session config + ensure remote audio plays), maybe `Config.swift` (output-device toggle), and the settings UI.

**Open questions to resolve offline:** exact LiveKit Swift audio-session hook; A2DP-out + phone-mic-in actually achievable in one `.playAndRecord` session; interaction with the DAT camera stream + plan-07 session; whether A2DP playback to the glasses degrades the camera video over the shared BT link (#7's shared-link finding — observe during the eventual device test).

**Verification:** needs a device rebuild + the glasses (one clean pass), since this is inherently hardware. Build locally per the wireless-deploy memory; no Vercel/viewer involved.

### Reliability notes for task #9 (don't lose these)
- Test #1 transcribed + got a reply on the **first** utterance, then degraded. Logs show `ios-publisher` **re-publishing mic + glasses tracks** (repeated `track subscribed` events ~10–30 s apart), which churns the agent's Gemini input and breaks turns. Prime suspect: the glasses **adaptive-resolution ladder rebuilding the video track** (plan 07's runtime decoder-rebuild) — and the agent re-subscribing audio alongside it.
- Likely fix direction: decouple the agent's **audio** input from **video** re-subscription so a video-track rebuild doesn't tear down the audio turn; and/or stabilise the published video. Keep 3.1.
- Saw `received server content but no active generation` (Gemini plugin) during churn, and AI-Studio 409s = concurrent/recycled Live sessions. The 409s also came partly from my agent restarts overlapping; the dispatch gate (task #7) reduces this.
- Repro without hardware where possible: `console` mode exercises the agent+model loop with a local mic; a synthetic re-publish could mimic the churn.
