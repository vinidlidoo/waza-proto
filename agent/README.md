# Coach agent — plan 19 (Conversational coaching MVP)

A Python [`livekit-agents`](https://docs.livekit.io/agents/) worker that joins
the `waza-proto` room, watches the glasses POV video, and holds a **reactive
voice conversation** via the Gemini Live API. The learner drives every turn;
the coach answers grounded in the live view. See
[`plans/active/19-coach-loop-mvp.md`](../plans/active/19-coach-loop-mvp.md).

This is **Stage 1** (plumbing + latency spike). It runs end-to-end the moment
two things are in place: a `GOOGLE_API_KEY` and the glasses publishing video.

## Setup

```bash
cd agent
uv sync
```

Add your Gemini API key to the **repo-root** `.env` (the agent loads it from
there — one secrets file for the whole project):

```
GOOGLE_API_KEY=...   # https://aistudio.google.com/apikey
```

`LIVEKIT_URL` / `LIVEKIT_API_KEY` / `LIVEKIT_API_SECRET` are already in `.env`.

## Run

```bash
uv run coach_agent.py console   # local mic + speaker, no LiveKit room — fastest smoke test
uv run coach_agent.py dev       # joins the LiveKit Cloud room; watches the published video
```

In `dev` mode the agent auto-dispatches to every new room (the demo uses one
fixed room). Bring up the iPhone publisher with the **glasses** source
selected, then speak a question.

## What to look for in the logs

- `video track subscribed: name='glasses-camera' ...` — proves the coach is
  watching the glasses, not the phone camera. A `WARNING` here means the wrong
  track was picked (select the glasses source on the phone).
- `learner asked: '...'` — the transcribed question.
- `[latency] learner_turn_end -> coach_speaking = X.XXs` — the conversational
  round trip (Gemini think + TTS + network). This is the Stage-1 gate number.

## Config (env overrides, all optional)

| Var | Default | Notes |
| --- | --- | --- |
| `COACH_MODEL` | `gemini-3.1-flash-live-preview` | One-line swap. `gemini-2.5-flash-native-audio-preview-12-2025` for the programmatic levers (plan 21); an OpenAI Realtime model for A/B. |
| `COACH_VOICE` | `Puck` | [Gemini Live voices](https://ai.google.dev/gemini-api/docs/live#change-voices). |
| `COACH_SPEAKING_FPS` | `1.0` | Frames/sec sampled while the learner speaks. |
| `COACH_SILENT_FPS` | `0.3` | Frames/sec while silent. Keep low — 3.1 bills every buffered frame per turn. |

## Notes / gotchas

- **Gemini 3.1 limits** (plugin warns on startup): `generate_reply()`,
  `update_instructions()`, `update_chat_ctx()` are ignored mid-session, and
  proactive/affective audio are unsupported. The design works *because* every
  turn is learner-triggered. The proactive rung (plan 21) likely needs 2.5.
- **No greeting on connect** — intentional (3.1 would ignore it; the learner
  speaks first).
- **Track selection** relies on the iOS app publishing one video track at a
  time. If we ever publish front + glasses simultaneously, swap to a custom
  `RoomIO` that filters by track name `glasses-camera`.
