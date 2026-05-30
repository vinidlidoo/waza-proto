# Plan 26: Viewer Talk-Back (audio publish, no video)

**Status:** ✅ Shipped (PR #12, plus post-merge UX refinements on `main`)

**Created:** 2026-05-29

**Goal:** Let browser viewers **talk** in the room — publish their microphone so
the glasses-wearer (and other viewers) hear them — while keeping viewers
strictly **audio-only** (never camera/screen). The wearer and viewers can hold a
two-way conversation during a demo; the AI coach is unaffected (it still hears
only the wearer).

## Problem

Viewers are subscribe-only. `/api/viewer-token` mints a grant with
`canPublish: false` (`viewer-token.js:40`), so a viewer's browser has no way to
put a mic track into the room. During a live demo the wearer can talk to the
audience (their mic is already published — see below) but the audience can't
talk back.

## Key findings (the holistic picture — what already exists vs. what's missing)

I traced every leg of the audio graph before scoping this. **Only one leg is
missing.**

- **Wearer → viewers already works.** The iOS publisher already publishes its
  microphone unconditionally on connect (`RoomConnection.swift:119`,
  `setMicrophone(enabled: true)` — added as a backgrounding keepalive, but it
  puts a real mic track in the room). Viewers have `canSubscribe: true`, the
  browser auto-subscribes, and `viewer/index.html`'s `TrackSubscribed` handler
  attaches **every** audio track and plays it (`index.html:347-356`). So viewers
  already hear the wearer (and the coach).

- **Viewer → room is the only gap.** Viewers can't publish anything
  (`canPublish: false`). Flipping that on — scoped to mic — is the whole feature.

- **Wearer hears viewers for free.** The publisher token already has
  `canSubscribe: true` (`publisher-token.js`), the iOS room connects with
  default `autoSubscribe`, and LiveKit's audio engine auto-renders remote audio
  tracks (the `didSubscribeTrack` delegate at `RoomConnection.swift:345` only
  *logs* — playout is automatic). So once a viewer publishes a mic track, the
  wearer hears it with **zero iOS change**.

- **The coach is already isolated, and that's the behaviour we want.** The coach
  session is pinned to `participant_identity = "ios-publisher"`
  (`coach_agent.py:226-228`), so `RoomIO` forwards **only the publisher's** audio
  to Gemini. Viewer voices never reach the model — no added Gemini cost, no
  "who's talking?" confusion. Viewers *do* hear the coach (they subscribe to the
  agent's audio track, same path as wearer audio). Net: the coach listens to the
  wearer; the room (wearer + viewers) is a side conversation around it. No
  coach-side change.

## Design

**One server switch + one small client control. No iOS change. No coach change.**

1. **Server grant (the switch).** In `viewer-token.js`, change the grant to:
   ```js
   canPublish: true,
   canPublishSources: [TrackSource.MICROPHONE],
   canSubscribe: true,
   ```
   `TrackSource` is re-exported from `livekit-server-sdk` (verified in
   `node_modules/livekit-server-sdk/dist/index.d.ts`; serializes to the string
   `"microphone"`). `canPublishSources` narrows publishing to exactly the mic —
   **the audio-not-video guarantee is enforced server-side**, so even a tampered
   client can't sneak a camera/screen track in. (The user's instinct — "flip a
   switch to allow audio but not video" — is exactly this field.)

2. **Viewer mic control (the client).** Add a single mic toggle button to the
   existing `#topbar`, alongside the current 🔊 *listen* button (which controls
   coach/remote-audio playback — distinct concern). The mic button:
   - **Defaults OFF** (no hot mic on page load; the page is shared by link).
   - On first tap: `room.localParticipant.setMicrophoneEnabled(true)` — the
     LiveKit client calls `getUserMedia` internally, which triggers the browser's
     mic-permission prompt from inside the user gesture (required).
   - On subsequent taps: toggle `setMicrophoneEnabled(false/true)` (mute, not
     unpublish — keeps the track so we don't re-prompt; mirrors the
     `setCamera mutes` behaviour noted in iOS memory).
   - Icon reflects state: 🎙️ on (publishing) / 🎤-slash off (muted). If
     permission is denied, surface a short status and leave the button in the
     off state.

That's it. The wearer hears viewers automatically; viewers hear each other
automatically (same `TrackSubscribed` audio path already attaches any audio
track); the coach is untouched.

## Decisions logged

- **Restrict at the grant, not the client.** `canPublishSources:
  [MICROPHONE]` is defense-in-depth: the audio-only constraint holds regardless
  of what the browser does. Relying on the client to "just not publish video"
  would be a client-trust assumption on a public, invite-shared page. Cost: one
  extra import + array. Worth it.

- **Mute, don't unpublish, on toggle-off.** Re-prompting `getUserMedia` on every
  un-mute is jarring and some browsers re-show the permission UI. Muting keeps
  the published track silent and instantly re-enables. (Same rationale as the
  iOS `livekit-setcamera-mutes` finding.)

- **Default mic OFF.** The viewer link is shared; a mic that's hot on load would
  leak audio from anyone who opens it. Opt-in via a deliberate tap is the safe
  default for a broadcast-style page.

- **No iOS change.** The wearer's subscribe + auto-playout path already exists;
  adding viewer→wearer audio needs nothing on device. (A future "mute the
  audience" control for the wearer is a separate, optional plan — noted, not
  built.)

- **No coach change; the pin already does the right thing.** Pinning the coach
  to `ios-publisher` (shipped in plan 19) means this feature can't bleed viewer
  audio into Gemini. This is a *benefit* of that earlier decision surfacing here,
  not a new constraint.

- **Keep the listen (🔊) and talk (🎤) controls separate.** They're orthogonal:
  one gates remote-audio *playout* (browser autoplay policy), the other gates
  local-mic *capture*. Folding them into one button would conflate "I can't hear"
  with "they can't hear me."

## Costs / limitations

- **Acoustic echo / feedback.** If a viewer and the wearer are in the same
  physical space, or a viewer runs speakers + mic without headphones, expect
  feedback. `getUserMedia` defaults (`echoCancellation`, `noiseSuppression`,
  `autoGainControl` all on) mitigate the common case; **recommend headphones**
  for in-person multi-party demos. Not solvable purely in software.
- **Audio mesh scale.** Every participant subscribes to every other's audio
  (SFU-forwarded, so it's N subscriptions per client, not N²). Trivial at demo
  scale (a handful of viewers). If audience size ever grows, revisit with
  speaker-permission gating or push-to-talk.
- **Abuse surface.** A rogue invite-holder could publish noise. Bounded by: the
  link is invite-gated (signed, short LiveKit TTL), and publishing is capped to
  mic. The lever if needed is server-side `removeParticipant` / mute
  (`RoomServiceClient`) — out of scope for the MVP, noted as the escape hatch.
- **No per-viewer mute UI for the wearer** in this plan (see decision).

## Coordination with Plan 23 (active — both edit `viewer-token.js`)

Plan 23 ("Close room on publisher disconnect") also modifies `viewer-token.js`:
it reads a signed `room` claim from the invite and adds a `listRooms` gate before
minting. **These changes are orthogonal** — plan 23 touches the *room* + the
pre-mint check; this plan touches the *grant fields* (`canPublish` /
`canPublishSources`). They edit different parts of the same `addGrant({...})` /
handler. Whichever lands second should fold the other's lines in rather than
overwrite. The `viewer-token.test.js` updates (below) likewise stack: 23 adds
room/`session_ended` cases, 26 adds grant-shape cases.

## Implementation steps

**Viewer API (`viewer/api/viewer-token.js`):**
- Import `TrackSource` from `livekit-server-sdk` (extend the existing
  `import { AccessToken } …`).
- In `addGrant`, set `canPublish: true` and
  `canPublishSources: [TrackSource.MICROPHONE]` (keep `canSubscribe: true`).
- Update the comment that currently says viewers don't publish.

**Viewer UI (`viewer/index.html`):**
- Add a mic-toggle button to `#topbar` (next to `#enable-audio`), styled like the
  existing round button; hidden until the room is connected.
- Wire it: default off; first tap → `room.localParticipant.setMicrophoneEnabled(true)`
  inside the click handler (user gesture for `getUserMedia`); toggle thereafter;
  reflect publishing/muted/denied in the icon + `aria-label`. Catch the
  permission-denied rejection and show a brief status (reuse `setStatus`/a pill).
- No change to the `TrackSubscribed` audio path — it already attaches and plays
  any audio track, which now includes other viewers.

**iOS / coach:** none (see findings + decisions).

**Ops:** none — no new env vars; no LiveKit project setting.

## Testing

**Viewer — `viewer/api/viewer-token.test.js` (update):**
- Valid invite → decoded `claims.video.canPublish === true`.
- `claims.video.canPublishSources` equals `['microphone']` (or the
  serialized equivalent the SDK emits) — and **does not include** `'camera'` /
  `'screen_share'`. This is the load-bearing assertion (audio-not-video).
- Existing cases (identity shape, 10m TTL, bad/expired/missing invite, missing
  env, distinct identities) still pass.
- Stack cleanly with plan 23's room/`session_ended` cases if that lands first.

**E2E (`viewer/e2e/viewer.spec.js`) — optional, stretch:** publishing a mic in
headless Chrome needs `--use-fake-device-for-media-stream` +
`--use-fake-ui-for-media-stream` launch flags (auto-grants mic, feeds a
synthetic track). If added: assert the mic button appears on connect, click it,
and assert `room.localParticipant` has a microphone track published. Consistent
with plan 08's scoping, the **wearer-hears-viewer** leg stays a **manual demo
check** (needs a live iOS publisher + real audio path): open viewer → tap mic →
allow → speak → confirm audible on the glasses/phone side.

**iOS:** no new tests (no iOS change).

## Docs

- README note (if it documents the viewer's subscribe-only nature) → viewers can
  now talk (mic only).
- No change to `scripts/mint-viewer-invite-url.js` (invite payload unchanged by
  this plan; plan 23 owns the `room` claim).

## Decisions logged during implementation (post-merge refinements)

The grant + mic-toggle landed as planned (PR #12). On-device testing on the Mac
mini (Brave + Safari iOS) then surfaced UX issues that drove four follow-up
commits on `main` — the design notes that changed:

- **Disable UNPUBLISHES the mic, not just mute (reverses the plan's "mute, don't
  unpublish" decision).** Muting (even with `stopMicTrackOnMute`, which stops the
  capture track) leaves the RTP sender attached to the peer connection, and
  iOS/macOS keep the OS "recording" indicator lit while any capture track is
  attached. Only `unpublishTrack(track, /*stopOnUnpublish*/ true)` — removing the
  sender — actually releases the device. Re-enabling re-acquires via
  `setMicrophoneEnabled(true)`; the origin's granted permission persists, so no
  second prompt. The plan's re-prompt concern didn't materialize. Trade-off:
  unpublish renegotiates (~1–2 s), so the toggle is **optimistic** — the icon
  flips immediately and the button disables (dimmed) until the op resolves,
  reverting only on failure.

- **Own `micOn` boolean, not the `isMicrophoneEnabled` getter.** The getter didn't
  reliably flip after a mute, leaving the second tap re-enabling instead of
  disabling. `micOn` flips only when the publish/unpublish resolves, and is reset
  on `Disconnected` so a TOKEN_EXPIRED reconnect can't show "on" with nothing
  published.

- **Icon coding mirrors the speaker button:** mic ON = 🎤, mic OFF = 🎤 with a red
  backslash (CSS `::after` overlay — there's no reliable "muted mic" emoji).

- **Speaker audio is gated on `el.muted`, not play/pause, and elements start
  MUTED.** A paused WebRTC `MediaStream` element can still render sound in Chrome,
  so `.paused` was an unreliable signal and `pause()` didn't reliably silence it —
  which made the speaker icon lie and the mic-enable gesture incidentally start
  audio. Remote audio now starts muted + playing (muted autoplay is always
  allowed) and unmutes on the speaker tap. This makes the speaker **fully
  orthogonal to the mic** and the icon honest. Minor behavior change: the viewer
  now needs one speaker tap to start hearing (Chrome blocked unmuted autoplay on a
  shared link anyway). Bonus: driving `el.muted` is also what lets Safari's
  per-tab audio pill follow the in-page control.

- **Safari per-tab mute can't be synced two-way** (researched against WebKit
  source): tab mute runs `pageMutedStateDidChange` at the player/output level —
  it doesn't change `el.muted` and fires no `volumechange`, so JS can't read or
  toggle it. The only available coupling is one-way (in-page `el.muted` → tab
  stops emitting → pill hides), which the `el.muted` rework gives for free.
