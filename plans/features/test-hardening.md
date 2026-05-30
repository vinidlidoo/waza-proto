# Test hardening

Forward-looking feature doc (backlog — not scheduled). Surfaced 2026-05-30.

Build a more robust, systematic test strategy — picking up from [18 — test suite gaps](../completed/18-test-suite-gaps.md)
— so that building features with Claude Code no longer ends in a long manual on-device check.

## Problem / motivation

Every feature currently ends in a manual glasses → phone → browser smoke test. That manual loop is
the bottleneck: slow, easy to skip, and the thing most likely to let a regression through. The
local suite from [08 — automated test suite](../completed/08-test-suite.md) (Vitest, XCTest, MDK,
Playwright) plus plan 18's pure-logic additions cover the *unit* layer well, but the parts that
still force hand-verification are exactly the ones both plans deferred:

- **No on-device / glasses-path automation.** `videoFramePublisher` doesn't fire under MockDeviceKit
  on the simulator (meta-wearables-dat-ios#197), and fold→session-termination doesn't propagate
  (plan 08 stage 3) — so the whole capture path is hand-verified. (See the
  `wdat-frame-delivery-sim-issue` memory.)
- **No coverage of the LiveKit *publish* / connect path** — `RoomConnection.connect/switchSource`,
  the `GlassesSource` pipeline, and `EncodedFrameTCPServer` need a live `Room` / real frames and are
  left to e2e + on-device (plan 18 "out of scope").
- **e2e is happy-path only.** Newer flows — close-room on disconnect (plan 23), session-ended,
  the coach loop (plan 19), viewer talk-back (plan 26) — aren't exercised end-to-end.

Goal: drive manual verification toward *zero* for the common case, so a Claude Code build can be
trusted on green tests alone.

## First step (explicit): research the landscape

Before designing anything, **research the landscape of testing tools for agent-assisted coding as
of May 2026.** This is a deliberate scouting phase, not implementation. Questions to answer:

- What does agent-driven / self-healing / AI-assisted testing look like now — frameworks,
  MCP-based test runners, agent-authored test generation, flaky-test triage?
- iOS on-device automation an agent can drive headlessly (XCUITest in CI, Maestro, device farms,
  SwiftUI snapshot / visual-regression tooling).
- Web e2e + visual-regression that pairs well with an agent loop (Playwright traces/visual diffs,
  hosted snapshot diffing).
- Tools that let an agent **close its own loop** — run, read failures, iterate without a human in
  the middle — and how they fit our existing Vitest / XCTest / Playwright stack and `just test`.

Output of this step: a short comparison + recommended toolchain, written back into this doc, that
the rest of the plan builds on.

## Sketch (post-research, to be refined)

- A tiered, single-command test story an agent runs end-to-end and reads the results of.
- Close the deferred plan-08/18 gaps in priority order, informed by the research.
- Some automated coverage of the glasses → phone → browser path (even partial — e.g. recorded-frame
  injection / a fake source as a substitute for #197), reducing the manual smoke test to an
  exception, not a ritual.

## Open questions

- How much of the glasses path is automatable at all given #197 (no sim frames)? Is recorded-frame
  injection / a fake capture source the pragmatic substitute?
- Where's the line between "worth automating" and "cheaper to hand-check" for a solo prototype?
- CI vs. local-only — do we want a hosted runner (the existing [CI integration](ci-integration.md)
  idea), or is `just test` on the Mac enough?

## Dependencies / related

- Direct continuation of [18 — test suite gaps](../completed/18-test-suite-gaps.md) and
  [08 — automated test suite](../completed/08-test-suite.md).
- Overlaps with the [CI integration](ci-integration.md) backlog item.
- Constrained by meta-wearables-dat-ios#197 (`wdat-frame-delivery-sim-issue` memory).
- e2e room setup assumes LiveKit auto-create is OFF (`livekit-auto-create-off-dependency` memory;
  shipped in [23 — room close on disconnect](../completed/23-room-close-on-disconnect.md)).
