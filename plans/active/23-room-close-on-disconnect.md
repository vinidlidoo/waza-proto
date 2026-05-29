# Plan 23: Close Room on Publisher Disconnect

**Status:** 🚧 In progress

**Created:** 2026-05-29

**Goal:** When the publisher (the iOS app) voluntarily disconnects, the room is
*closed*: every connected viewer is kicked immediately, and no one holding an
invite can rejoin that session. Each Connect tap starts a fresh, isolated
session; old invites never grant access to a new one.

## Problem

Today the room is a single hardcoded name, `waza-proto`, and viewer access is
gated only by a 3-hour signed **invite** (`InviteToken.swift`) that the Vercel
`/api/viewer-token` endpoint exchanges for a short-lived LiveKit token. When the
publisher taps Disconnect, `RoomConnection.disconnect()` calls
`room.disconnect()` — but that only removes the publisher. Viewers stay
connected (watching a frozen last frame until their 10-min token lapses), and
anyone with the still-valid invite can re-open the viewer page and rejoin. There
is no notion of a session ending.

## Research findings (the *why* behind the design)

LiveKit gives us exactly one primitive for the kick and **nothing** for the
re-entry block — that asymmetry drives the whole design.

- **Kicking is one call.** `RoomService.deleteRoom(name)` "forcibly disconnects
  all participants currently in the room." Each viewer's browser fires a
  `Disconnected` event with reason `ROOM_DELETED`, which `viewer/index.html`
  already handles. Server-side, `livekit-server-sdk` is already a dependency.

- **Deletion does NOT prevent rejoin.** Confirmed by a LiveKit maintainer
  ([livekit#2307](https://github.com/livekit/livekit/issues/2307)):
  *"you cannot revoke existing tokens"*, *"To close the room and disconnect
  everyone, see DeleteRoom"*, and crucially *"Closing the room does not prevent
  people from joining again"* — because **rooms auto-create the instant any
  participant joins**. A deleted room springs back as an empty ghost room on the
  next join. The maintainer's documented lever to actually block rejoin is to
  *"turn off `auto_create` from config (or Project settings in Cloud)."*

- **The invite is invisible to LiveKit.** Our invite is an app-level HS256 blob
  signed with `INVITE_SIGNING_SECRET`; LiveKit knows nothing about it.
  `deleteRoom` therefore does nothing to outstanding invites — they stay valid
  for their 3h TTL. **So the re-entry block must live at our `/api/viewer-token`
  mint layer, not inside LiveKit.**

- **Unredeemed tokens at close time:** unredeemed *invites* are unaffected by
  `deleteRoom` (still redeemable — the hole we plug); already-minted 10-min
  *LiveKit viewer tokens* are not revoked for holders who never connected, only
  bounded by their short TTL.

## Design

Make **"the room exists"** the open/closed flag, scoped per session, with the
guarantee enforced by LiveKit itself (auto-create off). No external state store
of any kind.

1. **Per-session room name.** On each Connect, the iOS app generates a random
   nonce (`UUID().uuidString`) and uses room `waza-proto-{nonce}`. How the room
   travels to each endpoint follows the **existing `coach-dispatch.js`
   convention** (already shipped): for *publisher-authed* calls
   (publisher-token, close-room) the room is a separate `?room=` query param and
   the signed envelope only proves "I'm the publisher"; for the *viewer* path the
   room is a **signed claim inside the invite**, because the viewer has no other
   credential and the endpoint must trust the invite for the room name. → Old
   invites carry an old, deleted room name, so they can never bleed into a future
   session (session isolation falls out for free).

2. **Explicit room creation.** With auto-create off (see step 5), the publisher's
   join no longer implicitly creates the room. `publisher-token.js` calls
   `createRoom(room, { emptyTimeout })` right before minting the publisher token
   — it's already on the connect path, so no extra round-trip from the app.

3. **Kick on voluntary disconnect.** A new signed endpoint
   `/api/close-room` (authed with the same envelope scheme as publisher-token)
   calls `deleteRoom(room)`. `RoomConnection.disconnect()` invokes it. Connected
   viewers receive `ROOM_DELETED`.

4. **Can't come back.** Because auto-create is off, a deleted room genuinely
   cannot be rejoined — a redeemed invite mints a token whose join hits
   `JOIN_FAILURE`. `/api/viewer-token` additionally does a `listRooms([room])`
   check and returns `403 session_ended` *before* minting, so normal viewers get
   a clean "stream ended" message at the HTTP layer instead of a raw WebRTC
   failure. (The `listRooms` check is UX polish; auto-create-off is what makes it
   *correct*.)

5. **Project setting:** LiveKit Cloud → auto-create **off**.

### Lifecycle

```
Connect tap → nonce = UUID() → POST /api/publisher-token?room=waza-proto-{nonce} (envelope = publisher auth)
            → createRoom(waza-proto-{nonce}, emptyTimeout) → mint publisher token
            → room.connect()  → share button mints invites with room claim
Viewer opens invite → GET /api/viewer-token → listRooms([room])
            → active?  mint viewer token, join
            → gone?    403 session_ended
Disconnect tap → POST /api/close-room → deleteRoom(waza-proto-{nonce})
            → viewers get ROOM_DELETED; room no longer exists; invites dead
```

## Decisions logged

- **Random nonce, not a counter.** A monotonic incrementer would need persistent
  shared state (DB/KV) — the exact thing we're avoiding. A client-side
  `UUID().uuidString` needs zero storage and zero coordination. The nonce is a
  session discriminator, **not a secret** — access is still gated by the signed
  token bound to that exact room, so a guessed/known room name grants nothing.

- **Auto-create OFF (project-global).** Accepted over keeping auto-create on +
  relying solely on the `listRooms` gate. With auto-create on, a holder of a
  still-valid 10-min token could bypass the viewer page and join LiveKit
  directly, resurrecting the empty room. Auto-create off closes that hole *and*
  simplifies the server (the `listRooms` check becomes optional polish rather
  than a correctness requirement). Cost: every room must be explicitly created
  (folded into `publisher-token.js`), and it's a project-wide setting — fine
  given this project has exactly one room family.

- **Single host, "ends for all."** The app user is the sole host; their
  Disconnect closes the session for everyone. Publisher identity stays
  `ios-publisher`. Multi-publisher / co-presenter support is explicitly out of
  scope (see below).

- **Token grants are exact-match per room** (no wildcards) — this is *why*
  `publisher-token.js` and `viewer-token.js` must take the room dynamically
  rather than hardcoding `waza-proto`.

- **Room-passing follows `coach-dispatch.js`, not the envelope.** The just-shipped
  `coach-dispatch.js` already established the pattern: `room` as an unsigned
  `?room=` query param, envelope proves only publisher identity, `missing_room` →
  401. `close-room.js` and `publisher-token.js` follow it for consistency and
  minimal change. Threat is bounded: only the app holds `PUBLISHER_SIGNING_SECRET`,
  rooms are free/ephemeral, and the worst an unsigned room param buys a holder of
  a valid envelope is deleting/creating a `waza-proto-`-prefixed room they already
  control. The **invite** is the one place room must be a *signed* claim — the
  viewer endpoint has nothing else to trust for the room name. (If we later want
  the publisher's room cryptographically bound, moving it into the envelope is a
  small, isolated change — noted, not done.)

- **`close-room.js` ≈ `coach-dispatch.js`.** Both are "verify publisher envelope +
  room, construct a LiveKit server client, make one call, map failure to 5xx." The
  only diffs are the client (`RoomServiceClient` vs `AgentDispatchClient`), the
  method (`deleteRoom` vs `createDispatch`), and the env set (no `COACH_AGENT_NAME`).
  Copy it as the template — handler *and* test.

## Rejected alternatives

- **`deleteRoom` alone.** Kicks current viewers but does not block rejoin
  (auto-create + durable invite). Insufficient.

- **External "closed sessions" KV / Edge Config.** Robust, but adds a storage
  dependency for a prototype. Per-session room names + auto-create-off achieve
  the same guarantee using LiveKit's own room state as the flag. Revisit only if
  we ever need to close a session while the publisher keeps streaming, or revoke
  individual invites.

- **`RemoveParticipant` per viewer.** O(n) calls, racy against new joins, and on
  Cloud only revokes that participant's current token (rejoin still possible with
  a fresh one). `deleteRoom` is atomic.

- **Presence-gating viewer-token on publisher-present.** Would block the
  pre-stream waiting room (viewers joining before the publisher connects), which
  we want to keep working, and conflates a network blip with an intentional
  close.

## Costs / limitations

- **No LiveKit cost** for many room names — Cloud bills participant-minutes +
  bandwidth, never room count. Rooms are free and ephemeral.
- **Invites become single-session by construction** — you can't pre-share a
  durable "always works" link. Matches the current flow (invite minted from the
  connected app), so no regression.
- **Orphan rooms** from abnormal exits (crash, not the Disconnect button) linger
  until `emptyTimeout`/`departureTimeout`; set them small on `createRoom`. The
  Disconnect path cleans up immediately via `deleteRoom`.
- **Project-global auto-create setting** — remember it if another room-based flow
  is added later.

## Implementation steps

**iOS (`ios/WazaProto/WazaProto/`):**
- `RoomConnection.swift`: generate `nonce` on `connect()`; derive
  `room = "waza-proto-\(nonce)"` (via a pure `sessionRoom(nonce:)` helper); hold
  it for the session; pass to the token client and invite mint; call the close
  endpoint in `disconnect()`.
- `PublisherTokenClient.swift`: pass `room` as a `?room=` query param (envelope
  unchanged); thread to `Config.publisherTokenURL`. Add a `closeRoom(room:)` call
  (new `Config.closeRoomURL(auth:room:)`).
- `InviteToken.swift`: add a signed `room` claim to the invite payload (mint takes
  the session room).
- `Config.swift`: add the close-room + room-param URL builders.

**Viewer API (`viewer/api/`):**
- `publisher-token.js`: read `room` from `?room=`, require it (`missing_room`) and
  validate the `waza-proto-` prefix (`invalid_room`), `createRoom(room, { emptyTimeout })`,
  mint publisher token for `room`.
- `viewer-token.js`: read `room` from the signed invite claim; `listRooms([room])`
  → `403 session_ended` if not active; otherwise mint for `room`.
- `close-room.js` (new): clone `coach-dispatch.js` — verify envelope + `?room=`,
  `RoomServiceClient.deleteRoom(room)`, map failure to 5xx.
- `coach-dispatch.js` (**cross-cutting — coordinate with the active Shu epic**):
  it currently hardcodes `const ROOM = 'waza-proto'` (line 5). Once rooms are
  per-session, summon/dismiss would target the dead static room, so it must take
  the same `?room=` param and pass it to `createDispatch(room, …)` /
  `listParticipants(room)` / `removeParticipant(room, …)`. The iOS coach-summon
  caller must send the live session room too. Small change, but it *will* break
  the coach loop if landed without it — call it out in plan 19 as well.

**Viewer UI (`viewer/index.html`):** friendlier "stream ended" copy on
`ROOM_DELETED` and on `403 session_ended`.

**Ops:** turn off auto-create in LiveKit Cloud project settings.

## Testing

Tests are **co-located** with handlers (`viewer/api/*.test.js`, Vitest) and in
the XCTest target (`ios/WazaProto/WazaProtoTests/`). Yes — this feature adds and
changes several.

**Precedent to copy: `coach-dispatch.test.js`.** It already does exactly the new
thing this feature needs — a handler that constructs a LiveKit *server* client
and makes a network call, tested by **`vi.mock`-ing `livekit-server-sdk`** (with
`afterEach` → `vi.restoreAllMocks()` + `vi.resetModules()`). The existing
publisher/viewer-token tests don't mock anything because today those handlers
only do pure `new AccessToken(...)` crypto; once they call
`createRoom`/`listRooms`, they adopt the coach-dispatch mock pattern. Lift the
shared `makeRes()` / `makeEnvelope()` helpers (currently duplicated across all
three test files) rather than copy a fourth time.

**Viewer — `viewer/api/publisher-token.test.js` (update):**
- `?room=waza-proto-…` valid → mint succeeds **and** the mocked `RoomServiceClient.createRoom`
  is called with that room + an `emptyTimeout`.
- Missing `room` param → `401 missing_room` (matches coach-dispatch).
- Room not starting with `waza-proto-` → `400 invalid_room` (guards against an
  envelope-holder creating arbitrary rooms).
- `createRoom` rejects → mapped 5xx (mirror coach-dispatch's `502 dispatch_failed`).
- Existing auth cases (bad sig, missing/wrong subject, expired, missing env) still pass.

**Viewer — `viewer/api/viewer-token.test.js` (update):**
- Invite carries a signed `room` claim; with `listRooms([room])` mocked **active**
  → mint succeeds for that room.
- `listRooms` mocked **empty** (closed / never created) → `403 session_ended`,
  and assert **no token minted**.
- Missing `room` claim on the invite → rejected.
- Existing invite cases (bad sig, expired, missing env) still pass.

**Viewer — `viewer/api/close-room.test.js` (new):** clone `coach-dispatch.test.js`.
Valid envelope + `?room=` → mocked `RoomServiceClient.deleteRoom(room)` called;
bad sig / missing auth / non-`ios-publisher` subject / `missing_room` rejected;
`deleteRoom` rejects → 5xx; missing env → 500.

**Viewer — `viewer/api/coach-dispatch.test.js` (update, if coach-dispatch is
made room-dynamic here):** its existing assertions hardcode `'waza-proto'`
(`createDispatch`/`removeParticipant` called with it). If this plan touches
coach-dispatch, those expectations move to the passed `?room=` value and a
`missing_room` case is added. Sequence with plan 19 to avoid a double-edit.

**iOS — `PublisherTokenClientTests.swift`:** the envelope is unchanged (room rides
as a query param, not a claim — see decision), so the existing five cases stand.
Add coverage for the new `closeRoom`/room-param plumbing only at the pure level
(URL/param construction) — no envelope-shape change.

**iOS — `InviteTokenTests.swift` (update — already exists, plan 18's tests landed):**
`InviteToken` gains a signed `room` claim. Extend `buildEnvelope` to take the
room, and assert the decoded payload carries it (deterministic fixed-clock case,
alongside the existing window/signature cases). This supersedes the earlier
"coordinate with plan 18" note — the file is present now.

**iOS — nonce/room derivation:** factor session-room derivation into a pure helper
(e.g. `static func sessionRoom(nonce:) -> String`) so it's testable without the
`@MainActor` `RoomConnection`; assert the `waza-proto-{nonce}` shape. The `UUID()`
call itself stays untested (platform RNG).

**E2E (`viewer/e2e/`) — manual/smoke only:** the `ROOM_DELETED` kick and the
post-close `session_ended` block need a live publisher + real LiveKit room, which
the Playwright tier doesn't drive (consistent with plan 08's smoke-only scoping
for anything needing live media). Verify by hand: open viewer → publisher
Disconnect → viewer flips to "stream ended"; re-open the same invite → blocked.

## Docs

Update `scripts/mint-viewer-invite-url.js` (invite now needs a `room`) and any
README note on the single hardcoded room.
