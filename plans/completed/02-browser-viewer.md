# 02 — Browser viewer with hardcoded JWT

Build ladder step #2 (see `README.md`). Validates the subscriber half of the LiveKit pipeline before any iOS code exists.

## Goal

A static HTML page that, given a LiveKit JWT, connects to a room and renders any incoming video track in a `<video>` element. No server, no build step, no framework.

## Why this slice

If the viewer works against the LiveKit CLI's test publisher (step #3), we know the LiveKit Cloud project, our JWT minting, and the JS SDK wiring are all sound. When the iOS publisher (step #4) later fails to show up, the failure is isolated to the publish side.

## Approach

```code
viewer/
  index.html      ← LiveKit JS SDK via CDN, ~50 lines of inline JS
scripts/
  mint-token.sh   ← wraps `lk token create`, reads creds from .env
```

- **Serving:** `python3 -m http.server 8000` from repo root. `file://` would work for the JS SDK but breaks the moment we want anything fetch-based.
- **Token delivery:** pass via URL query param (`viewer/index.html?token=…`). Hardcoding into HTML means re-editing every time the JWT expires; a query param means `./scripts/mint-token.sh | pbcopy` and paste.
- **Room name:** hardcoded `waza-proto` in both the mint script and the HTML.
- **Viewer identity:** hardcoded `browser-viewer`.

## Key decisions (upfront)

- **No token server.** The whole point of step #2 is the subscriber path; a real `/token` endpoint is a step #4+ concern (iOS app will need it). Until then, mint out-of-band via CLI.
- **LiveKit CLI for minting.** The `lk` (or `livekit-cli`) binary already needs to be installed for step #3's test publisher, so we reuse it. No Node/Python JWT lib dependency.
- **Vanilla JS + CDN.** No bundler, no npm, no TypeScript. The viewer is ~50 lines and we'll throw it out or rewrite it as soon as we have real needs.
- **Subscribe to all video tracks indiscriminately.** First incoming track wins the `<video>` element. Multi-track UI is a step #5+ concern.

## Open questions

- **Autoplay policy.** Chrome blocks autoplay with sound. Video-only tracks should be fine but worth verifying — fallback is a click-to-play button.

## Done criteria

1. `./scripts/mint-token.sh` prints a valid JWT.
2. Opening `http://localhost:8000/viewer/index.html?token=<jwt>` in Chrome shows "Connected to room waza-proto" in the page or console.
3. Step #3 (LiveKit CLI test publisher) will produce a moving test pattern in the `<video>` element. (Validation deferred to that step's plan, but the viewer must be ready for it.)

## Decisions logged during implementation

- **`lk` 2.16.3 installed via `brew install livekit-cli`.** Binary is `lk`; brew formula still uses the old name.
- **JWT TTL set to 6h via `--valid-for 6h`.** CLI default is 5m, which is too short for a dev loop.
- **Use `--token-only`** so the script's stdout is just the JWT, suitable for `pbcopy` / URL building.
- **Viewer token is subscribe-only.** `--grant '{"canSubscribe":true,"canPublish":false}'` — LiveKit defaults both to true when only `roomJoin` is set, which would let the viewer also publish into the room. Tightened to least-privilege.

## Vincent's learnings

Concepts picked up while building this step. Captured for future reference — none of it is project-specific.

- **SPM (Swift Package Manager).** Apple's built-in dependency manager for Swift. Add a GitHub URL in Xcode → File → Add Package Dependencies. Equivalent to npm/pip but with no CLI workflow — it's a GUI flow in Xcode.
- **Xcode toolchains.** macOS ships a slim "Command Line Tools" install (`/Library/Developer/CommandLineTools`) with `git`/`clang`/etc., separate from the full Xcode app. `xcode-select -s` chooses which one `xcodebuild`/`xcrun` point at. Apple allows multiple Xcodes side-by-side, hence the manual switch.
- **Xcode mental model.** Project (`.xcodeproj`) contains Targets (buildable things). A Scheme says *how* to build a target (debug/release, which simulator). Info.plist holds app metadata (permissions strings, custom config like the MWDAT block). Signing & Capabilities tab is where Team ID/Bundle ID live.
- **API key vs API secret.** Key = public identifier (which credential), secret = password (proves it's really you). Split lets servers do cheap lookup-by-key before expensive crypto verification, and lets signature-based flows (like LiveKit JWTs) embed the key in the token while keeping the secret server-side.
- **LiveKit JWT grants.** A token with only `roomJoin: true` *also* gets `canPublish: true` and `canSubscribe: true` by default. Tighten with `--grant '{"canPublish":false,...}'` on `lk token create` for least-privilege.
- **ESM (ECMAScript Modules).** JS's native module system, browser-supported since ~2017. `<script type="module">` enables native `import`/`export`. Replaces the old "everything on window" / UMD / bundler-required world. Most npm packages still ship CommonJS, so CDNs like jsDelivr offer `/+esm` to convert on the fly.
- **CDN-served npm via jsDelivr/unpkg.** URL shape: `cdn.jsdelivr.net/npm/<pkg>/+esm`. Lets a static HTML file pull dependencies with no build step. Fine for prototypes, not production (runtime dependency on a third party).
- **WebRTC is event-driven, not pollable.** Tracks arrive, participants come and go, connections drop and reconnect — all asynchronously. LiveKit's `Room` exposes events (`trackSubscribed`, `disconnected`, …) rather than getters. `track.attach()` returns a ready-to-append HTMLMediaElement.
- **Repo layout: `src/` vs component dirs.** `src/` is a per-package idiom (single language, build step). Polyglot repos (web + native + scripts) use component-named top-level dirs (`viewer/`, `ios/`, `scripts/`). Don't add `src/` as a repo-root layer with one child.
- **`python3 -m http.server 8000`.** Built-in Python stdlib one-liner that serves the current working directory over HTTP on port 8000. `-m` runs a module as a script. URL paths map directly to filesystem paths. Needed because browsers restrict modern JS APIs (fetch, WebSocket auth flows) under `file://`. Single-threaded, no HTTPS, no auth — fine for local dev, never expose on a network.
