# 06 — Shareable viewer link (hosted viewer + serverless token mint)

Build ladder step #6. Promotes the local `viewer/index.html` from "static file + a JWT you mint with a shell script" to a public URL anyone can open on a phone or desktop browser, with a token minted on demand by a serverless function. v0.06.

## Goal

Send someone a single URL. They open it on iOS Safari, Android Chrome, or any desktop browser. They see whatever the iPhone (running WazaProto from step #5) is currently publishing — front camera or glasses POV — with the same sub-second latency the local viewer has today. No login, no token paste, no app install.

## Why this slice

Step #5 closed the "can we get glasses POV through LiveKit at all" question. The pipeline works end-to-end on Vincent's two machines. v0.06 is the smallest change that turns the prototype into something *demoable*: the value of a POV stream is in showing it to someone who isn't sitting at your desk. Without this step, every demo is a screen-share of the local browser viewer, which is friction-heavy and undermines the whole point.

It's also the cheapest possible vehicle for learning Vercel + LiveKit's server SDK in the token-mint path — both of which we'll need anyway for v0.07+ if back-channels (chat, talkback) ever land.

## Approach

Four pieces.

### 1. Vercel project hosting the viewer + token mint

Create a new Vercel project rooted at `viewer/` (or a sibling `web/` directory if we want to keep `viewer/` as the local-dev shape — settled in §5). The project has:

- `index.html` — the existing viewer HTML, moved/copied and modified per §3.
- `api/token.js` — Vercel Node serverless function that mints a viewer-role JWT for the `waza-proto` room.
- `vercel.json` — minimal config if needed (probably none — Vercel auto-routes `api/*`).
- Environment variables on the Vercel project: `LIVEKIT_URL`, `LIVEKIT_API_KEY`, `LIVEKIT_API_SECRET`. Mirrors the local `.env`.

Deploy via `vercel` CLI or git integration. The free tier is more than enough — token mint is ~100 bytes in, ~500 bytes out, called once per viewer page load.

### 2. Serverless token-mint function

`api/token.js` — single endpoint that validates a per-invite signed JWT (`?invite=…`) before minting a LiveKit JWT. No invite, expired invite, or bad signature → 401.

```javascript
import { AccessToken } from 'livekit-server-sdk';
import { jwtVerify } from 'jose';

const inviteKey = new TextEncoder().encode(process.env.INVITE_SIGNING_SECRET);

export default async function handler(req, res) {
  const invite = req.query.invite;
  if (!invite) return res.status(401).json({ error: 'missing_invite' });

  try {
    await jwtVerify(invite, inviteKey, { algorithms: ['HS256'] });
  } catch (e) {
    return res.status(401).json({ error: e.code === 'ERR_JWT_EXPIRED' ? 'invite_expired' : 'invalid_invite' });
  }

  const at = new AccessToken(
    process.env.LIVEKIT_API_KEY,
    process.env.LIVEKIT_API_SECRET,
    { identity: `viewer-${crypto.randomUUID().slice(0, 8)}`, ttl: '10m' }
  );
  at.addGrant({ roomJoin: true, room: 'waza-proto', canPublish: false, canSubscribe: true });
  res.setHeader('Cache-Control', 'no-store');
  res.status(200).json({ token: await at.toJwt(), url: process.env.LIVEKIT_URL });
}
```

~25 lines. Two layers of TTL: the **invite** lasts 3 hours (set by iOS at copy-link time, validated here), the **LiveKit JWT** lasts 10 minutes (auto-refreshed by the viewer page via re-fetch as long as the invite is still valid). Once the invite expires, the page can't re-mint — viewer needs a fresh link from the publisher. That's the revocation mechanism: no denylist, you just wait out the 3h window.

`INVITE_SIGNING_SECRET` is a shared HS256 secret between Vercel and the iOS app (random 32 bytes, base64-encoded, generated once with `openssl rand -base64 32`). Rotating it invalidates every outstanding invite globally — the nuclear option, but no LiveKit credential rotation needed and no iOS rebuild (the iPhone publisher uses a separate long-lived dev JWT in `Secrets.swift`, untouched by invite rotation).

### 3. Viewer page changes

Currently `viewer/index.html` reads `?token=…` from the URL. New behaviour:

- On page load, parse `?invite=<jwt>` from the URL; if missing, show "this link is missing an invite — ask the publisher for a fresh URL".
- Fetch `/api/token?invite=<jwt>`; on 401 with `invite_expired`, show "this link has expired (links last 3 hours) — ask for a new one"; on 401 with `invalid_invite`/`missing_invite`, same UX; on 200, `{token, url}` → `room.connect(url, token)`.
- On LiveKit `unauthorized` (10-min JWT expired mid-session), re-fetch `/api/token?invite=<jwt>` once and reconnect. If the invite has expired during the session, surface the same "expired" UX.
- Drop the `LIVEKIT_URL` constant from the page — it now comes from the mint endpoint, single source of truth on the Vercel side.
- Keep the existing `TrackSubscribed` / `TrackUnsubscribed` / `Disconnected` handlers; they're already correct for "viewer-only and stream may come and go" use case.

Net page complexity is roughly flat: `?invite=` parsing replaces `?token=` parsing; a new expired-link state replaces nothing. The mint endpoint absorbs the validation logic.

### 4. iOS additions

Three pieces:

- **Invite minting (on-device)**: a small `InviteToken` helper signs an HS256 JWT `{iat, exp: now + 3h}` using a shared secret from `Secrets.swift` (`INVITE_SIGNING_SECRET`, the same value as the Vercel env var). ~30 lines using `CryptoKit` (`HMAC<SHA256>.authenticationCode`) and `Data.base64URLEncodedString`. No third-party JWT dep needed — HS256 is small enough to hand-roll for one use case.
- **Copy viewer link button** in `ContentView`: tapping it mints a fresh invite, builds `https://<vercel-host>/?invite=<jwt>`, and puts that on the pasteboard with a brief "Copied" toast. Each tap = a new 3h invite. No network call required (minting is offline).
- **Watcher count badge**: subscribe to `room.remoteParticipantsDidUpdate` (or whatever the LiveKit Swift SDK calls it — verify exact name) and display a `Text("\(n) watching")` when `n > 0` and we're connected. Hidden when zero. ~20 lines including the publisher count logic on `RoomConnection`.

The Vercel host string lives in a new `Config.swift` (committed — knowing the URL doesn't grant access without a valid invite). The `INVITE_SIGNING_SECRET` lives in `Secrets.swift` (already gitignored, same shape as the LiveKit dev JWT).

## File layout (delta from step #5)

```code
viewer/                           ← either becomes the Vercel project root,
                                    or stays as the local-dev viewer
                                    (decision in §5 below)
  index.html                      ← parse ?invite=, fetch /api/token?invite=, expired-link UX
  api/
    token.js                      ← NEW — validates invite JWT, mints viewer LiveKit JWT
  package.json                    ← NEW — declares `livekit-server-sdk` + `jose` deps
  .vercelignore                   ← NEW (maybe) — excludes local-dev tooling from deploy

ios/WazaProto/WazaProto/
  Config.swift                    ← NEW — viewer host string (committed; not a secret)
  InviteToken.swift               ← NEW — HS256 JWT minting via CryptoKit
  Secrets.swift                   ← + INVITE_SIGNING_SECRET (gitignored, mirrors Vercel env)
  ContentView.swift               ← + Copy link button; + "N watching" badge
  RoomConnection.swift            ← + @Published watcherCount; observes participant changes
```

Out of scope: changing the `Secrets.swift` flow on iOS (the publisher still uses a long-lived dev JWT), updating `scripts/mint-token.sh` (it stays as a local-dev tool — see §5).

## Key decisions (upfront)

- **Vercel over Cloudflare Workers or Netlify.** Vercel's Node functions run `livekit-server-sdk` with no polyfills; LiveKit's own sample apps deploy there; first-time setup is the smoothest of the three. Cold-start (~1–2s on free tier for the first viewer in a ~15min idle window) is acceptable for a "share a link with one person" use case. If v0.07+ ever needs every token mint to feel snappy at scale, revisit with Cloudflare Workers + `jose`.
- **Single shared room `waza-proto`, view-only, gated by per-invite signed tokens (HS256, 3h TTL, no denylist).** Each "Copy viewer link" tap on iOS mints a fresh invite locally; the Vercel mint endpoint validates the invite before issuing a LiveKit JWT. Revocation = wait out the 3h window (or rotate `INVITE_SIGNING_SECRET` to nuke everything outstanding). No server-side state, no KV, no denylist — keeping it stateless was a hard requirement.
- **Two-layer TTL: 3h invite envelope, 10-min LiveKit JWT inside.** The 10-min JWT auto-refreshes on `unauthorized` as long as the invite is still valid; once the invite expires, the page surfaces "this link has expired — ask for a new one" and stops re-fetching. Short LiveKit TTL keeps individual session tokens cheap to leak; longer invite TTL keeps the demo UX from interrupting itself.
- **Invite minting happens on-device, not via a Vercel endpoint.** Means iOS holds the signing secret in `Secrets.swift` (already gitignored), same threat model as the LiveKit dev JWT it already stores. Trade-off: extracting the IPA lets you mint infinite invites — but you'd also get the LiveKit dev JWT, which is strictly more dangerous, so this doesn't widen the attack surface. Upside: "Copy link" is offline, instant, and adds zero serverless calls.
- **Keep `scripts/mint-token.sh` for local dev.** The script stays useful for testing the iOS publisher against `viewer/index.html` opened as `file://` without a Vercel round-trip. The hosted path is for shareable demos; the local path is for dev iteration.
- **Watcher count uses LiveKit's remote-participant signal directly.** No custom data channel, no server-side participant tracking. The Swift SDK already exposes participant change events on `Room`; we just count them. Doesn't distinguish "human viewer" from "another publisher" but in our model there's only ever one publisher anyway.
- **Don't put the Vercel URL behind a config-fetch on app launch.** Hardcode it in `Config.swift`. The URL changes at most once (when we eventually attach a custom domain), and a runtime config endpoint is one more thing to fail. If we ever need to rotate it, a rebuild of the iPhone app is fine.

## Open questions

- **Where does the Vercel project live: `viewer/` (replacing the current local-dev viewer) or a new `web/` (sibling)?** Pros of in-place: one viewer, no drift. Pros of sibling: `viewer/index.html` stays as the file-URL local-dev path; `web/` is the deployable artifact. Lean in-place — the simplifications in §3 mean the deployed viewer is also fine for local dev (just point it at a `vercel dev` instance). Confirm during implementation.
- **Vercel URL form factor for v0.06.** `<project>.vercel.app` works immediately, costs nothing, and is fine for "send to a friend". A custom domain (e.g. `viewer.waza-proto.dev`) is a one-time DNS dance — worth doing only if we want a real-looking URL on the demo. Defer the custom domain to v0.07+ unless it's clearly worth it now.
- **`LIVEKIT_URL` in two places.** Today the iOS app has it in `Secrets.swift`; the Vercel function will have it in env vars; the viewer page used to have it inline. After §3, the viewer no longer needs it (mint endpoint returns it). The iPhone and Vercel are independent deployments so duplication is unavoidable — file the awkwardness, don't try to eliminate it.
- **iOS pasteboard requires no extra entitlement on iOS 18+, but worth verifying** that copying from a non-foreground action doesn't trip the new "pasteboard access" prompt. If it does, fall back to a `ShareLink` (SwiftUI's share sheet) which is friction-free.
- **JWT-in-URL form factor.** Base64URL-encoded HS256 JWTs are ~150 chars, which makes the shareable URL ugly (`waza-proto.vercel.app/?invite=eyJhbGc…`). Works fine in iMessage/email/SMS, but worth eyeballing once on a real device. If it bothers us we can shorten the secret payload, but stateless = JWT, period; the only way to get a shorter URL is to add KV-backed invite IDs (out of scope per "no denylist").
- **Watcher count: does `room.remoteParticipantsDidUpdate` fire on every viewer connect/disconnect, or only on the initial sync?** Probably the former — verify against the LiveKit Swift SDK source. If it's only the initial sync, switch to `ParticipantConnected` / `ParticipantDisconnected` events.
- **Should the viewer page surface "publisher is offline" distinctly from "loading"?** Today, between `room.connect` succeeding and `TrackSubscribed` firing, the status reads "waiting for video". That's fine when the publisher is mid-handshake but ambiguous when nobody's publishing at all. Could improve with `RemoteParticipant` count check on connect — out of scope unless the ambiguity bites in actual demos.

## Done criteria

1. Tap "Copy viewer link" on iPhone → paste into Notes → URL is `https://<vercel-host>/?invite=<jwt>` form.
2. Open that URL from a phone or laptop that has never run any project code. Page loads, status says "connected to waza-proto — waiting for video".
3. Start publishing from the iPhone (either source). Within ~1 second the viewer's status flips to "receiving video from ios-publisher" and the stream renders.
4. The "N watching" badge on the iPhone shows the correct count when one, two, and zero viewers are connected.
5. Mobile viewer (iOS Safari) works as well as desktop: autoplay succeeds, no manual unmute step, layout doesn't break.
6. Inspect the Vercel function logs after a viewer load — confirms `LIVEKIT_API_SECRET` and `INVITE_SIGNING_SECRET` are never sent to the client; only the minted LiveKit JWT is.
7. Leave a viewer page open for 11 minutes; LiveKit JWT auto-refresh succeeds without a page reload (invite is still valid).
8. Open the Vercel URL with `?invite=` stripped — page shows "this link is missing an invite". Open with a tampered `?invite=garbage` — page shows "invalid link". Open with an invite generated 3+ hours ago (test by setting iOS device clock forward, or by hand-crafting one with a past `exp`) — page shows "this link has expired".
9. Disconnect from the iPhone. Viewer status returns to "waiting for video" within ~1 second (existing `TrackUnsubscribed` handler).
10. Hand the URL to someone outside the project (or open it in an incognito window on a fresh device) — they see the stream with no further setup.

## Decisions logged during implementation

- **`viewer/` becomes the Vercel project root** (in-place, not a new `web/` sibling) — settled open question §5. The simplifications in §3 mean the deployed viewer is fine for local dev too; no drift.
- **No `vercel.json` needed.** Vercel auto-detects `viewer/api/token.js` as a Node serverless function and serves `viewer/index.html` as the static root. Zero config.
- **Both sides treat `INVITE_SIGNING_SECRET` as a UTF-8 string for HMAC key bytes.** Vercel: `new TextEncoder().encode(process.env.INVITE_SIGNING_SECRET)`. iOS: `SymmetricKey(data: Data(Secrets.inviteSigningSecret.utf8))`. Verified byte-identical JWT output against `jose` for a fixed iat/exp pair — Vercel accepts iOS-minted invites and vice versa. No base64-decode step on either side.
- **Xcode 16 synchronized folder references (`PBXFileSystemSynchronizedRootGroup`)** in the existing `.pbxproj` mean new `.swift` files under `WazaProto/` are auto-included in the build target. No pbxproj edits needed for `Config.swift` or `InviteToken.swift`.
- **`RoomConnection` inherits from `NSObject`** to conform to `RoomDelegate` (whose methods are `@objc optional`). Trivial change; `ObservableObject` composes fine with `NSObject` subclasses.
- **Watcher count filters by identity prefix `viewer-`** (matching what `api/token.js` mints) rather than counting all `remoteParticipants`. Caught an off-by-one during testing where a stale or system participant was inflating the count to 1 with no real viewers connected. Identity-prefix filter is cleaner than permission-based filtering and robust against future agent/system participants in the room.
- **`copyToast` is a transient state that swaps the status row text** (green for 2s) rather than a separate toast component. Keeps the UI surface minimal and reuses the existing status row's visual real estate.
- **"N watching" badge is an overlay** on the LocalPreview (top-trailing, red capsule, white text) rather than a status-row chip. Mimics the standard "LIVE" indicator pattern; visually loud enough to register but doesn't crowd the controls.
- **iOS pasteboard "Copy link" did not trip the iOS 18+ permission prompt** (open question resolved). `UIPasteboard.general.string = ...` from a button tap is treated as a foreground user action and skipped the system pasteboard alert.
- **`scripts/mint-token.sh viewer` role removed** (revising the earlier "keep `mint-token.sh` for local dev" decision). Once `index.html` started fetching from `/api/token`, the `file://` static viewer path stopped working — the deployed page can't be opened locally without a server. The replacement local-dev path is `vercel dev` (runs the same `api/token.js` on `http://localhost:3000`), which doesn't need `mint-token.sh viewer`. Stripped the role parameter and hardcoded `publisher` since `refresh-secrets.sh` is now the only caller. Codex flagged the original viewer-path regression as P2; this is the cleanup.

## Vincent's learnings

*(Fill in as we go.)*

## Tech debt opened

*(Likely: cold-start UX, the Config.swift / Secrets.swift split, no real auth. Log to `plans/tech-debt-tracker.md` as it surfaces.)*
