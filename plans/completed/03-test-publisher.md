# 03 — Test publisher via LiveKit CLI

Build ladder step #3 (see `README.md`). Confirms the publisher half of the pipeline using a synthetic source, before any native code exists.

## Goal

A moving test pattern is visible in the step #2 browser viewer, sourced from `lk` on the same Mac — no iOS, no glasses, no real camera.

## Why this slice

If step #2 (subscriber) and step #3 (publisher) both work in isolation, every piece of LiveKit configuration (URL, JWT signing, room name, SFU routing, codec negotiation) is validated before we add the real complications: iOS signing, WDAT frame conversion, Bluetooth Classic flakiness. When step #4 (iOS shell) inevitably fails, the failure is localized to the native side.

## Approach

Two pieces:

1. **Parameterize `scripts/mint-token.sh`** to accept a role argument:
   - `./scripts/mint-token.sh viewer` → subscribe-only, identity `browser-viewer` (current behavior, becomes the default).
   - `./scripts/mint-token.sh publisher` → publish-only, identity `test-publisher`.
   - Role determines grants and identity; everything else (room, TTL, .env sourcing) stays shared.

2. **Add `scripts/publish-test-pattern.sh`** that mints a publisher token and launches `lk`'s built-in synthetic publisher in one shot. Eliminates the copy-paste loop during dev.

```
scripts/
  mint-token.sh            ← now takes a role arg
  publish-test-pattern.sh  ← new: token + publish command in one
```

## Key decisions (upfront)

- **Wrap the publisher in a script, not a manual one-liner.** This validation will be re-run as a sanity check during steps #4 and #5 ("is the SFU side still fine?"); the script keeps it a single command.
- **Single mint script, role-parameterized.** Two scripts that share 90% of the body would drift. One script + a `case` statement is cleaner.
- **Test publisher identity is `test-publisher`.** Distinct from the eventual iPhone publisher (`ios-publisher`) so logs make sense in LiveKit Cloud's session view.

## Open questions

- **Exact `lk` subcommand for the test pattern.** `lk` ships a synthetic-source publisher but the precise invocation (`lk room join --publish-demo`? `lk publish`?) needs to be confirmed from `lk room --help` before scripting. First task of the implementation.
- **Codec defaults.** `lk` will negotiate something (likely H.264 or VP8). Worth noting which it picks, since the iOS publisher will need to agree. Not a blocker — LiveKit handles renegotiation — but useful data point.
- **Multiple publishers in one room.** If a stale test-publisher session is still connected when we start the iOS one, what happens? Probably both tracks appear. Worth knowing whether the viewer's "first video wins" logic does something sensible.

## Done criteria

1. `./scripts/mint-token.sh publisher` and `./scripts/mint-token.sh viewer` both print valid JWTs with the correct grants (`canPublish` only / `canSubscribe` only).
2. `./scripts/publish-test-pattern.sh` connects to `waza-proto` and publishes synthetic video.
3. Step #2's viewer, opened with a fresh `viewer` token, shows a moving test pattern within a few seconds of the publisher script starting.
4. Stopping the publisher (Ctrl+C) cleanly disconnects; the viewer's status reverts to "waiting for video…" or similar.

## Decisions logged during implementation

- **`mint-token.sh` left alone (no role parameterization).** `lk room join` does not accept a `--token` flag — it mints its own JWT internally from `--api-key`/`--api-secret` (read from `.env` via env vars). So a publisher-side mint script would be dead code: the only consumer of a hand-minted JWT in the project is the browser viewer, which is a subscriber. If a future step needs to inspect a publisher token (e.g., to verify grants), `lk token create` can be run ad hoc. Revised done criterion #1: only `./scripts/mint-token.sh` (viewer) needs to produce a valid JWT — the publisher path no longer involves a separate token step.
- **Region failover is automatic.** `lk room join` tried `ophoenix1b → ochicago1b → oashburn1b → otokyo1b → ...` (us, then asia-pac) when the initial signal websocket timed out. The Cloud SFU has an anycast-like layer in front: clients get pointed at the nearest healthy region, falling back globally. Useful to know when iOS publisher debugging starts — a "connect timeout" log isn't necessarily one bad region.

## Vincent's learnings

- **`lk room join --publish-demo`** is the synthetic publisher invocation. The `--publish-demo` flag streams a built-in looping demo video (Big Buck Bunny-ish). No separate `lk publish` subcommand exists — publishing in `lk` is always done as a side effect of joining a room. We ended up not using `--publish-demo` because it stuttered badly; switched to a locally-generated H.264 file via `--publish`.
- **`--publish-demo` stutters; locally-encoded file is smoother.** The bundled demo clip's framerate/encoding parameters didn't match what `lk` paced it at, producing irregular delivery. Generating our own `assets/testsrc.h264` with explicit ffmpeg flags fixed it.
- **PLI (Picture Loss Indication) is the canary for "decoder lost sync".** Every time the browser's H.264 decoder can't keep up — usually because UDP packets got dropped — it sends an RTCP PLI back through the SFU asking the publisher for a fresh keyframe. A *real* encoder (iPhone camera, glasses) responds by generating an IDR frame immediately. A *file* source can't — it can only deliver the keyframes already baked into the file at encode time. So a PLI flood with a file publisher = video freezes until the next pre-encoded keyframe shows up. Mental model for step #4 debugging: PLI flood + real source = "what's eating packets on the network?", PLI flood + file source = "either lower the bitrate or generate IDRs more often".
- **`--publish` doesn't loop.** Unlike `--publish-demo`, `lk room join --publish file.h264` plays the file once and unpublishes the track. Worked around it by encoding 5 minutes of content — long enough for any smoke test. If a future step needs continuous file publishing, wrap the `lk` call in a shell `while true` loop (the viewer would see brief gaps at each cycle).
- **Bitrate matters more than resolution for residential upload.** First attempt: 1280×720 with no bitrate cap → ~10 Mbps stream → upstream packet loss → PLI flood → freeze. Fix: 640×360 with `-b:v 800k -maxrate 800k -bufsize 1600k` → fits comfortably under any cable/fiber upload cap → smooth. Lesson generalizes: WebRTC over residential is bandwidth-constrained, not resolution-constrained. LiveKit's adaptive bitrate (which kicks in with real encoders) handles this automatically; file sources can't.
- **The H.264 streaming-friendly encode incantation.** For any "publish a file as if it were a live stream" use case, the load-bearing ffmpeg flags are: `-g 30 -keyint_min 30 -sc_threshold 0` (predictable 1s keyframes), `-x264-params "repeat-headers=1"` (SPS/PPS inline at every keyframe, so late joiners can decode), `-profile:v baseline -pix_fmt yuv420p` (broadest decoder compatibility), and an explicit bitrate cap. Without `repeat-headers=1`, a subscriber that joins after the file's initial SPS/PPS gets no decoder config and renders nothing — a surprising failure mode I would not have guessed.
- **`exec` in a shell-script tail.** Used in `publish-test-pattern.sh`'s last line. Replaces the bash process with `lk` rather than spawning a child, which means Ctrl+C delivers `SIGINT` directly to `lk` (so it can clean up the WebRTC peer connection cleanly) instead of to a bash wrapper that might or might not forward signals. Tiny detail, but it's the difference between "viewer goes back to waiting…" and "viewer's still seeing the test pattern stuck on the last frame" on disconnect.
- **`lk` mints its own tokens when given api-key + api-secret.** This is *only* possible for CLI tools that own the secret — a browser app must never see `LIVEKIT_API_SECRET`, which is why the viewer side requires a pre-minted JWT but the CLI side doesn't. The threat model is "who is allowed to hold the secret": a Mac script with `.env` access → yes; anything that ships JS to a user → no.
- **`exec` in a shell-script tail.** Used in `publish-test-pattern.sh`'s last line. Replaces the bash process with `lk` rather than spawning a child, which means Ctrl+C delivers `SIGINT` directly to `lk` (so it can clean up the WebRTC peer connection cleanly) instead of to a bash wrapper that might or might not forward signals. Tiny detail, but it's the difference between "viewer goes back to waiting…" and "viewer's still seeing the test pattern stuck on the last frame" on disconnect.
- **LiveKit Cloud is multi-region with automatic failover.** When a signal websocket times out, the SDK tries other regions (Phoenix → Chicago → Ashburn → Tokyo → Osaka, in observed order). Operationally: if the *first* region times out repeatedly, the issue is probably client-side networking, not LiveKit. If *all* regions time out, it's almost certainly client-side or token-related.
