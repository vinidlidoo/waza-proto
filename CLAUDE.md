# Waza Proto

Prototype of a sub-second POV video pipeline: Ray-Ban Meta glasses → iPhone (Swift + LiveKit SDK) → LiveKit Cloud → browser viewer. The v0.05 rung on the Waza experiment ladder.

The project overview, architecture rationale, and build ladder live in `README.md`. Read it before making architectural suggestions.

## Plans and decisions

Architectural decisions are logged in plan files under `plans/active/` (in-flight) and `plans/completed/` (shipped). `plans/index.md` is the progressive-disclosure summary. Before making non-trivial changes, consult the relevant plan's **"Decisions logged during implementation"** section — it captures the *why* behind choices that aren't obvious from the code. Tech debt is tracked separately in `plans/tech-debt-tracker.md`.

## Meta DAT (Wearables) SDK docs

For Meta Wearables DAT SDK questions (session lifecycle, permissions, streaming, errors), query the official spec at `https://wearables.developer.meta.com/llms.txt` (append `?full=true` for the inlined full text). This is the source of truth — the `wearables-dat` MCP server is unreliable. The vendored SDK also ships `CHANGELOG.md` + `README.md` under `.build/xcode-derived/SourcePackages/checkouts/meta-wearables-dat-ios/`, and the obfuscated-but-readable API surface lives in that package's `MWDATCore.xcframework/.../MWDATCore.swiftinterface`.

## Secrets

LiveKit credentials live in `.env` (gitignored): `LIVEKIT_URL`, `LIVEKIT_API_KEY`, `LIVEKIT_API_SECRET`. Never commit them and never paste them into chat output that might be shared.
