"""Plan 19 — Conversational coaching MVP (Stage 1: plumbing + latency spike).

A LiveKit Agents worker that joins the waza-proto room, subscribes to the
glasses POV video track, and holds a *reactive* voice conversation via the
Gemini Live API. The learner drives every turn ("show me how", "what now?",
"did I get that right?"); Gemini answers grounded in the live view of their
hands. No proactive interjection — that's plan 21.

Run locally:
    uv run coach_agent.py console     # local mic/speaker, no LiveKit room
    uv run coach_agent.py dev         # joins the LiveKit Cloud room

Needs GOOGLE_API_KEY in the repo-root .env (see .env.example). LIVEKIT_URL /
LIVEKIT_API_KEY / LIVEKIT_API_SECRET are already there.
"""

from __future__ import annotations

import logging
import os
import time
from pathlib import Path

from dotenv import load_dotenv
from google.genai import types as genai_types
from livekit import rtc
from livekit.agents import (
    Agent,
    AgentServer,
    AgentSession,
    AgentStateChangedEvent,
    JobContext,
    UserInputTranscribedEvent,
    UserStateChangedEvent,
    cli,
    room_io,
)
from livekit.agents.voice import VoiceActivityVideoSampler
from livekit.plugins import google

# One secrets file for the whole project: load the repo-root .env (symlinked
# into each worktree). GOOGLE_API_KEY must be added there before running.
load_dotenv(dotenv_path=Path(__file__).resolve().parent.parent / ".env")

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("waza-coach")
logger.setLevel(logging.INFO)

# --- Config (env-overridable) ------------------------------------------------
# Model id is a deliberate one-line swap: gemini-2.5-flash-native-audio-* if we
# need the programmatic levers (plan 21), or an OpenAI Realtime model for A/B.
COACH_MODEL = os.getenv("COACH_MODEL", "gemini-3.1-flash-live-preview")
COACH_VOICE = os.getenv("COACH_VOICE", "Puck")
# Conservative sampling to bound token cost. 3.1's TURN_INCLUDES_ALL_VIDEO
# means every buffered frame counts toward the turn, so keep these low.
SPEAKING_FPS = float(os.getenv("COACH_SPEAKING_FPS", "1.0"))
SILENT_FPS = float(os.getenv("COACH_SILENT_FPS", "0.3"))

# Contract with the iOS publisher: GlassesSource.swift names the buffer track
# "glasses-camera". The front camera publishes under a different (default)
# name, so this lets us assert we're watching the glasses, not the phone.
GLASSES_TRACK_NAME = "glasses-camera"

COACH_INSTRUCTIONS = """\
You are a hands-on coach watching the user's point of view through smart \
glasses. You can see their hands and what they are working on in real time. \
The user is learning a manual task and will ask you questions out loud, such \
as "show me how to start", "what do I do next?", or "did I get that right?". \
Answer concisely and conversationally, grounded in what you can currently \
see — refer to what is actually in view. Keep replies short, a sentence or \
two, since the user is acting on them with their hands. Do not volunteer \
corrections unless asked; wait for the user to speak."""


class CoachAgent(Agent):
    def __init__(self) -> None:
        super().__init__(instructions=COACH_INSTRUCTIONS)


server = AgentServer()


def _wire_track_logging(room: rtc.Room) -> None:
    """Log every subscribed track so we can PROVE the agent is watching the
    glasses feed (done-criteria #1/#2), and warn loudly if it isn't."""

    @room.on("track_subscribed")
    def _on_track_subscribed(
        track: rtc.Track,
        publication: rtc.RemoteTrackPublication,
        participant: rtc.RemoteParticipant,
    ) -> None:
        if track.kind == rtc.TrackKind.KIND_VIDEO:
            name = publication.name or "(unnamed)"
            logger.info(
                "video track subscribed: name=%r source=%s from=%s",
                name,
                publication.source,
                participant.identity,
            )
            if name != GLASSES_TRACK_NAME:
                logger.warning(
                    "expected the %r track but got %r — the coach may be "
                    "watching the wrong camera. (The iOS app publishes one "
                    "video track at a time; select the glasses source.)",
                    GLASSES_TRACK_NAME,
                    name,
                )
        else:
            logger.info(
                "audio track subscribed from=%s", participant.identity
            )


def _wire_latency_logging(session: AgentSession) -> None:
    """Stopwatch the conversational round trip: from when the learner stops
    speaking to when the coach starts speaking (done-criterion #6). This is a
    coarse but honest proxy — it includes Gemini's think+TTS time and the
    network legs, which is exactly what 'does it feel natural?' depends on."""

    state = {"user_stopped_at": None}

    @session.on("user_input_transcribed")
    def _on_transcript(ev: UserInputTranscribedEvent) -> None:
        if ev.is_final and ev.transcript.strip():
            logger.info("learner asked: %r", ev.transcript.strip())

    @session.on("user_state_changed")
    def _on_user_state(ev: UserStateChangedEvent) -> None:
        # Learner just finished their turn → start the clock.
        if ev.new_state == "listening" and ev.old_state == "speaking":
            state["user_stopped_at"] = time.monotonic()

    @session.on("agent_state_changed")
    def _on_agent_state(ev: AgentStateChangedEvent) -> None:
        if ev.new_state == "speaking" and state["user_stopped_at"] is not None:
            dt = time.monotonic() - state["user_stopped_at"]
            state["user_stopped_at"] = None
            logger.info(
                "[latency] learner_turn_end -> coach_speaking = %.2fs", dt
            )


# Omitting agent_name => automatic dispatch: the worker joins every new room
# (the demo uses a single fixed room). Set agent_name + a dispatch rule later
# if we need to gate which rooms the coach joins.
@server.rtc_session()
async def entrypoint(ctx: JobContext) -> None:
    ctx.log_context_fields = {"room": ctx.room.name}

    video_sampler = VoiceActivityVideoSampler(
        speaking_fps=SPEAKING_FPS, silent_fps=SILENT_FPS
    )

    session = AgentSession(
        llm=google.realtime.RealtimeModel(
            model=COACH_MODEL,
            voice=COACH_VOICE,
            # Low token budget per frame — we need scene understanding, not
            # fine print. Bump to MEDIUM/HIGH if the coach misreads detail.
            media_resolution=genai_types.MediaResolution.MEDIA_RESOLUTION_LOW,
        ),
        video_sampler=video_sampler,
    )

    _wire_track_logging(ctx.room)
    _wire_latency_logging(session)

    await session.start(
        agent=CoachAgent(),
        room=ctx.room,
        # video_input=True streams the single published video track natively to
        # Gemini. The iOS app publishes exactly ONE video track at a time
        # (RoomConnection.switchSource fully unpublishes the old source), so
        # when the glasses source is selected this is unambiguously the
        # "glasses-camera" track — asserted by _wire_track_logging.
        room_options=room_io.RoomOptions(video_input=True),
    )
    await ctx.connect()

    # Deliberately NO session.generate_reply() greeting: on 3.1 it's ignored,
    # and the design is learner-driven — the first model turn is triggered by
    # the learner's first spoken question.
    logger.info(
        "coach ready (model=%s, voice=%s) — waiting for the learner to speak",
        COACH_MODEL,
        COACH_VOICE,
    )


if __name__ == "__main__":
    cli.run_app(server)
