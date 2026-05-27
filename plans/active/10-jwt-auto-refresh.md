# 10 — Long-session JWT auto-refresh on the publisher

Make the iOS publisher's LiveKit token rotate itself so a single connect call holds the publish track across the underlying JWT TTL — phone in pocket, glasses on, hours-long backgrounded session.

## Goal

After this plan ships:

- The iPhone app holds the publish track indefinitely across forced LiveKit JWT expiries (verified with a short-TTL probe).
- `Secrets.swift` no longer carries a time-limited LiveKit token. It carries only static signing material.
- A new Vercel endpoint mints publisher JWTs on demand, gated by a secret distinct from `INVITE_SIGNING_SECRET`.
- Refresh failures surface in `RoomConnection.Status` rather than fail silent.

## Why this slice

Plan 07 unlocked backgrounded glasses sessions that can run for hours. The current 6h JWT (baked into `Secrets.swift` by `scripts/refresh-secrets.sh`) is the only thing left that puts a hard ceiling on session length. Recovery today is: re-run the script, rebuild via Xcode, redeploy to the phone — not a recovery, a reinstall.

There's also a workflow asymmetry. Viewers already auto-refresh on `DisconnectReason.TOKEN_EXPIRED` (see `viewer/index.html` lines 75–95). The publisher is the only participant whose token death is fatal.

## Design decisions (committed up front)

These are the choices the backlog stub left open. Settled before staging so the ladder below is concrete.

### Where the new token comes from

**New Vercel endpoint `viewer/api/publisher-token.js`**, sibling of `token.js`, gated by a new secret `PUBLISHER_SIGNING_SECRET`. Returns the same `{token, url}` shape.

Not the existing `/api/token`. Mixing publisher capability into the viewer-mint surface widens the blast radius of a viewer-side compromise — every viewer JWT decision starts having to think about whether it could accidentally grant publish. Separate endpoint, separate secret, separate audit. ~30 lines of code; the isolation is worth it.

### How the publisher proves it's the publisher

The Swift app holds `PUBLISHER_SIGNING_SECRET` in `Secrets.swift` (same shape as today's `inviteSigningSecret`). To mint, it signs a short auth envelope (HS256, `sub: "ios-publisher"`, `exp: now+2min`) via `CryptoKit` and sends it as `?auth=<jwt>`. Vercel verifies the envelope and mints a LiveKit publisher JWT.

This re-uses the invite-token shape exactly (verify-then-mint), so `viewer/api/token.js` is the working reference. CryptoKit is in the stdlib — no new Swift dependency.

The seed itself is the long-lived secret. That's the same trust model `inviteSigningSecret` already lives under: if the phone leaks, both secrets need rotating. The change vs today is that the *LiveKit token* becomes short-lived; the trust seed is what gets the longer leash.

### LiveKit publisher JWT TTL

**2 hours**, refresh scheduled at **T - 15 min**.

- Long enough that a 24h session takes ~12 refreshes — not a hot path.
- Short enough to bound exposure of a leaked LiveKit JWT.
- The 15-minute safety window leaves room for 3–4 retry attempts (30s / 2m / 5m backoff) before the token actually expires.

### Swift-side rotation mechanism

`Room.localParticipant` exposes an in-band token update in recent SDK versions (`updateToken(_:)` or equivalent — verified in Stage 3, not assumed). When it works, refresh is invisible to viewers. Fallback: full disconnect + reconnect on `RoomEvent.tokenExpired`, which costs viewers a ~1s blip but recovers state.

## Approach — staged, slow

Same shape as plan 08. Each stage independently shippable; verify each end-to-end (including a deliberate-break check on the test surface) before moving on.

### Stage 1 — Vercel publisher-token endpoint (+ rename viewer endpoint)

Pure server-side work, completely testable without iOS. Includes the `/api/token` → `/api/viewer-token` rename so both endpoints land in the same deploy with consistent naming.

**Rename tasks (do first, in their own commit):**

- `git mv viewer/api/token.js viewer/api/viewer-token.js`. Also rename the test file: `git mv viewer/api/token.test.js viewer/api/viewer-token.test.js`.
- Update the fetch URL in `viewer/index.html` line 41 from `/api/token` to `/api/viewer-token`.
- Update the route check in `viewer/e2e/local-server.js` line 40.
- Update the relative import in the renamed test file.
- Run `npm test` and `npm run test:e2e`, both green. Deploy to Vercel preview, hit `?invite=...` to confirm.

**New endpoint tasks:**

- Add `viewer/api/publisher-token.js`. Verify the auth envelope (HS256 via `jose`), then mint a LiveKit JWT with `identity: "ios-publisher"`, `roomJoin + canPublish`, `ttl: '2h'`. Mirror `viewer-token.js`'s `REQUIRED_ENV` check shape, adding `PUBLISHER_SIGNING_SECRET`.
- Vitest coverage matching `viewer-token.test.js`: missing auth → 401, tampered → 401, expired → 401, valid → 200 with `ios-publisher` identity + 2h TTL, missing env → 500 listing missing keys.
- Add `PUBLISHER_SIGNING_SECRET` to README env-vars section and to `.env.example`.
- Generate the secret (`openssl rand -hex 32`), add to local `.env` and to Vercel project env (preview + production).
- Smoke test against Vercel preview with a hand-signed envelope via `curl`.

**Done criteria:**

1. `cd viewer && npm test` passes the new endpoint's tests.
2. Deliberately break one assertion → red. Revert; green.
3. Deliberately break the auth verify path in `publisher-token.js` (e.g. skip the `jwtVerify` call) → tests catch it.
4. `curl` against the Vercel preview with a valid envelope returns a parseable LiveKit JWT whose decoded `sub` is `ios-publisher`.

### Stage 2 — Swift mint client + initial connect

Wire the mint into the existing connect flow without touching refresh yet. Goal: prove the loop end-to-end on a fresh token.

**Tasks:**

- Add `PublisherTokenClient.swift` in `ios/WazaProto/WazaProto/`. One method `mint() async throws -> (token: String, url: String)`: build the auth envelope via CryptoKit's `HMAC<SHA256>`, POST to `Config.publisherHost + "/api/publisher-token?auth=..."`, decode `{token, url}`.
- Add `publisherSigningSecret` to `Secrets.swift` (regenerated from `.env` by `refresh-secrets.sh`).
- Add `publisherHost` to `Config.swift` — same Vercel host as `viewerHost`, distinct constant for clarity.
- `RoomConnection.connect()` swaps `Secrets.token` → `await client.mint().token` and uses `mint().url` instead of `Secrets.wsURL` (the URL comes from the same response, source of truth).
- XCTest coverage for the envelope builder (pure function over secret + clock): verifies header alg, claims (`sub`, `exp`), and HMAC byte-equality against a known vector.
- Smoke test on device: app connects, viewer sees the publish track.

**Done criteria:**

1. App connects and publishes via the minted token end-to-end.
2. `xcodebuild test` covers the envelope builder.
3. Disable the endpoint (e.g. rename it) and confirm `RoomConnection.Status` transitions to `.failed` with a clear error string rather than hanging.

### Stage 3 — Refresh loop

Now the actual feature. `RoomConnection` (or a new `TokenRefresher` it owns) schedules and performs in-band updates.

**Tasks:**

- Verify the LiveKit Swift 2.14.1 API for in-band token replacement. Confirm the method name, its async/throws signature, and what happens on failure (does the room disconnect, or does it just no-op the new token?). Log the finding in **Decisions logged** below.
- On `connect()`: decode the minted JWT's `exp`, schedule a refresh `Task` at `exp - 15min`.
- On fire: `await client.mint()`, then in-band update. Reschedule from the new `exp`.
- Retry policy: 3 attempts with 30s / 2m / 5m backoff. If all three fail and we cross `exp - 1min`, surface `Status.failed("token refresh failed — connection will drop")` so the UI shows it.
- Reactive fallback on `RoomEvent.tokenExpired` (if a scheduled refresh slipped past `exp`): full reconnect via the same mint path. Viewers see ~1s blip.
- Cancel the refresh `Task` in `disconnect()` and on `switchSource` if it tears down the room.

**Probe / verification:**

- Add a debug-build-only override: env var `LIVEKIT_PUBLISHER_TTL_OVERRIDE` on the Vercel endpoint that, when set, swaps `2h` for `5m`. Don't ship this to production env.
- Run a 20-minute glasses session in debug mode with the override set. Expect ≥3 in-band refreshes visible in the iOS console, no viewer disconnect, no track drop.
- Run a 20-minute session with the endpoint deliberately returning 500 to one refresh attempt. Expect retry, then success. Log captures the retry.

**Done criteria:**

1. The 20-minute short-TTL probe completes with ≥3 successful in-band refreshes and zero viewer-visible drops.
2. A simulated single-refresh failure recovers via backoff inside the safety window.
3. A simulated total endpoint outage surfaces as `Status.failed` before the room actually drops.
4. XCTest covers the scheduler math (next-refresh delay, backoff sequence) on a pure-logic seam.

### Stage 4 — Cleanup

Once the loop is load-bearing, retire the old surfaces.

**Tasks:**

- Remove `token` from `Secrets.swift`.
- Rewrite `scripts/refresh-secrets.sh`: drop the `mint-token.sh` call, no longer mint a LiveKit JWT, just write `wsURL` (still useful as a fallback constant if needed, or drop entirely now that mint() returns it), `inviteSigningSecret`, `publisherSigningSecret`. File no longer has an expiry.
- `scripts/mint-token.sh` stays for ad-hoc CLI mints (e.g. `lk room join --publish` during dev) but the README stops pointing iOS users at it.
- README: update the iOS first-run setup, add the `PUBLISHER_SIGNING_SECRET` to the env-vars block, remove the "JWT expires every 6h, re-run refresh-secrets.sh" note that's no longer true.
- Run a 4h+ unattended glasses session to confirm the real-world target. Capture the iOS console log under `plans/active/10-jwt-auto-refresh-soak.log` (or attach a summary in the **Decisions logged** section).

**Done criteria:**

1. A 4h+ session completes with no manual intervention and no app reinstall.
2. Fresh-checkout setup with the new `refresh-secrets.sh` produces a working build.
3. Plan moves to `plans/completed/`.

## Non-goals

- Viewer-side mint stays untouched. Viewer JWTs are already short-lived and auto-refresh.
- No denylist / revocation infrastructure. The shortest safe leash is the TTL.
- No per-session JWT minting. One publisher, one identity (`ios-publisher`). Multi-publisher is a separate plan.
- No rotation of the long-lived signing secret in this plan. If `PUBLISHER_SIGNING_SECRET` leaks, rotate manually (regenerate, update Vercel + `.env`, re-run `refresh-secrets.sh`).

## Open questions

- Should the endpoint accept a `device_id` claim so multiple physical phones can use distinct LiveKit identities under one room? Today's `ios-publisher` identity is unique-by-design; LiveKit rejects duplicate-identity joins. Defer to the multi-publisher plan.
- Two HS256 secrets (`INVITE_*` + `PUBLISHER_*`) vs one with `aud:` discrimination? Two is more boring; one is easier to rotate. Lean two unless rotation actually becomes a chore.
- Should `RoomConnection` expose the upcoming-refresh time in `Status` so the debug UI can show "next refresh in 1h 47m"? Probably useful during stage 3 probing, optional after. Add only if it falls out naturally.

## Decisions logged during implementation

- **Stage 1 README/env-vars task deferred to Stage 4.** The plan's Stage 1 bullet "Add `PUBLISHER_SIGNING_SECRET` to README env-vars section and to `.env.example`" couldn't land cleanly: there is no `.env.example` in the repo today, and the only README env-vars mention is on the Playwright line (which doesn't need the publisher secret — Vitest stubs it in its own setup). Adding it there would mislead. Stage 4 already plans a comprehensive README env-vars rewrite — the publisher secret will land there alongside the iOS first-run rewrite.
