# 08 — Automated test suite (local)

Cross-cutting infra (not a build-ladder rung). Stand up a locally-runnable test suite covering the parts of this repo that don't need glasses + phone in hand. CI integration is deliberately out of scope — see [features/ci-integration.md](../features/ci-integration.md), which depends on this plan landing first.

## Goal

Five tiers of tests, each runnable locally with one command, each verified to catch a deliberately-introduced regression: Vercel token-mint logic, iOS pure-logic units, iOS code paths exercising Meta's Mock Device Kit, iOS UI flows driven via the MockDevice test server, and the browser viewer rendering against a synthetic publisher. Reduces — does not replace — on-device validation.

## Why this slice

The branching workflow we're about to start using assumes some baseline of automated signal on each change. Today there is none: the only gate is Vincent on his phone, which doesn't scale to multi-branch work. The Mock Device Kit docs (read 2026-05-26) confirm Meta ships a proper simulator path for the DAT side, which materially raises what we can test without hardware.

Why local-only: getting the tests *written* and *passing* is the meaty problem. Wiring them into GitHub Actions adds an entirely separate surface (workflow YAML, runner cost management, secrets, reporters, branch protection) that's easier to scope as its own follow-up once the local suite exists.

## Approach — staged, slow

Each stage is independently shippable. We verify each stage works end-to-end (including a deliberate-break sanity check) before moving on. If a stage reveals the next is harder than expected, we re-scope rather than push through.

### Stage 1 — Vercel token-mint (Node + Vitest)

The easiest, highest-leverage starting point. Pure JS, fast feedback. Validates the testing toolchain itself before we layer the iOS surface on top.

**Tasks:**

- Add Vitest to `viewer/package.json` as a devDependency. Pin to a recent stable.
- Factor any non-trivial logic in `viewer/api/token.js` into pure helpers if needed for testability (don't restructure aggressively — just enough that we can call the verify/mint pieces directly from tests).
- Write tests for: valid invite signature → token minted with expected identity prefix + TTL; tampered invite → rejection; expired invite → rejection; missing env vars → clear error; identity collision-resistance (different invites → different identities).
- Add a `npm test` script in `viewer/package.json`.
- Test-only fake values for `LIVEKIT_API_SECRET` + `INVITE_SIGNING_SECRET` (e.g. `viewer/test.env` or inline constants in the test file). Mark clearly as test-only.

**Done criteria for stage 1:**

1. `cd viewer && npm test` passes locally.
2. Deliberately break one assertion → tests red locally.
3. Deliberately break `token.js` (e.g. flip a comparison operator) → existing tests catch it.
4. Revert; green again.

### Stage 2 — iOS pure-logic XCTest (no MDK yet)

Validates that we can add an Xcode test target at all and get it building reliably *before* layering MDK on top. Pure helpers only — no `Wearables`, no LiveKit room.

**Tasks:**

- Add a `WazaProtoTests` XCTest target to the Xcode project.
- Write unit tests for: `Secrets` env-loading + missing-key behavior, `RoomConnection.currentWatcherCount` viewer-identity filter (using injected fake `RemoteParticipant`s or extracting the filter into a pure helper), `RoomConnection.Status` equality.
- Document local run command in README (`xcodebuild test -scheme WazaProto -destination 'platform=iOS Simulator,...'`).

**Done criteria for stage 2:**

1. `xcodebuild test` runs locally and passes.
2. Deliberately break one assertion → tests red locally.
3. Deliberately break a pure helper → existing tests catch it.
4. Revert; green again.

### Stage 3 — iOS XCTest with MockDeviceKit

The first non-trivial stage. Adds Meta's MDK in-process mock so we can exercise `GlassesSource`'s session lifecycle without real glasses. This is where the iOS test surface jumps from "pure helpers" to "the code that has actually had bugs."

**Tasks:**

- Add `MWDATMockDevice` to the test target (SPM wiring — verify it ships with the same `meta-wearables-dat-ios` package or needs separate vendoring).
- Create `MockDeviceKitTestCase` base class per [Meta's iOS testing docs](https://wearables.developer.meta.com/docs/develop/dat/testing-mdk-ios/): pair Ray-Ban Meta mock, get CameraKit, unpair in teardown.
- Vendor a small MP4 fixture into the test bundle (a few seconds of a moving test pattern is enough).
- Write tests:
  - `GlassesSource.publish(to:)` happy path against a real local `Room` connection: mock paired & donned → call `publish()` → assert track published, first frame delivered.
  - `unpublish(from:)` cleanly tears down the watchdog, frame token, decompression session, and `LocalTrackPublication`.
  - Hinge fold → `handleGlassesTerminated()` fires → `RoomConnection.status` transitions to `.failed("Glasses session ended …")`.
  - Source swap (Front → Glasses → Front) via `RoomConnection.switchSource` doesn't drop the room connection or leak the previous publisher.

**Done criteria for stage 3:**

1. Tests pass locally via `xcodebuild test`.
2. Deliberately break the hinge-fold teardown (e.g. comment out `onTerminated()` call) → corresponding test red.
3. Deliberately break MDK setup (e.g. comment out the `pairRaybanMeta` call) → all MDK-dependent tests red, with a clear failure mode (not silent skips).
4. Revert; green again.

### Stage 4 — iOS XCUITest with MockDevice test server

Drives the full UI flow on the simulator: tap Connect → "Publishing" appears → simulate hinge fold → "Glasses session ended" surfaces → tap Connect again → recovers. The closest thing we can get to "Vincent watching the phone screen" without Vincent or the phone.

**Tasks:**

- Add a `WazaProtoUITests` XCUITest target if not already present.
- In the app: gate `MockDeviceKit.shared.enable(...)` + `startTestServer(portFilePath: ...)` behind `ProcessInfo.processInfo.arguments.contains("--ui-testing")` in a DEBUG-only init path. Read the port file path from env var per Meta's pattern.
- Add `MWDATMockDeviceTestClient` to the UI test target.
- Write tests:
  - Connect (source=Glasses) → status label shows "Publishing as ios-publisher" within timeout.
  - Hinge fold mid-stream → status flips to "Glasses session ended — unfold and reconnect".
  - Source toggle (Front ↔ Glasses) via the UI segmented control behaves as expected with mock devices.
  - Watcher-count badge updates when a (faked) remote participant is added — likely needs an extra mock-injection hook; defer if too gnarly.

**Done criteria for stage 4:**

1. UI tests pass locally on a clean simulator.
2. Deliberately break the watchdog → "Glasses session ended" never appears → UI test red.
3. Deliberately break the connect path (e.g. throw early in `RoomConnection.connect`) → UI test red.
4. Revert; green again.

### Stage 5 — Browser viewer Playwright tests

Last because it pulls in a separate stack (Playwright, headless Chromium) and requires a real LiveKit room to publish into. Useful but the lowest-leverage stage — the viewer code is small and changes rarely compared to the iOS surface.

**Tasks:**

- Add Playwright to `viewer/` as a devDep, pinned.
- Decide on the local-side LiveKit room: probably reuse the existing demo `waza-proto` room with a dedicated test invite, or stand up a local-dev `waza-proto-local-test` room. Document the choice.
- Add a `npm run test:e2e` script that: starts `lk room join --publish` with a known test pattern in the background, serves `viewer/` locally (`npx serve` or `vite preview`), runs Playwright against `http://localhost:PORT`, tears down the publisher.
- Tests:
  - Viewer loads, fetches a token from the local mint (probably a Node helper that imports `viewer/api/token.js` directly to avoid drift with the deployed endpoint), connects to the room.
  - `<video>` element receives frames (assert non-zero `videoWidth` + `videoHeight` after timeout).
  - Watcher-count overlay reflects the test viewer's presence.
- Optional final touch: `make test` (or root `npm test`) umbrella that runs all of stages 1, 2, 3, 4, 5 in sequence locally. Small enough to fit here rather than a 6th stage.

**Done criteria for stage 5:**

1. Tests pass locally.
2. Deliberately break the viewer (e.g. wrong `wsURL`) → tests red.
3. Deliberately break the token-mint endpoint → tests red with a clear error.
4. Revert; green again.
5. (If we added the umbrella) `make test` or `npm test` from repo root runs all five tiers and reports a single pass/fail.

## File layout (delta)

```code
viewer/
  package.json                                  ← + vitest / + @playwright/test
  api/
    token.test.js                               ← new (stage 1)
  e2e/                                          ← new (stage 5)
    viewer.spec.ts
ios/WazaProto/
  WazaProto/
    WazaProtoApp.swift                          ← + --ui-testing branch (stage 4)
  WazaProtoTests/                               ← new (stages 2+)
    SecretsTests.swift
    RoomConnectionTests.swift
    GlassesSourceMDKTests.swift
    fixtures/
      mock-camera.mp4
  WazaProtoUITests/                             ← new (stage 4)
    ConnectFlowUITests.swift
README.md                                       ← + how to run each suite
plans/active/08-test-suite.md                   ← this file
```

No `.github/workflows/` here — that's the CI feature's job.

## Key decisions (upfront)

- **Local-only, CI explicitly out of scope.** Wiring tests into GitHub Actions is a separable surface (workflow YAML, macOS runner cost, secrets, reporters, branch protection). Tracked as [features/ci-integration.md](../features/ci-integration.md), prereq = this plan landing.
- **Stages are sequential, not parallel.** Even if stage 1 and stage 5 are technically independent, doing them serially keeps the testing-toolchain surface debugged in one stack at a time.
- **MDK over hand-rolled mocks.** We do not roll our own DAT mocks. MDK is vendor-supported, mirrors the real SDK surface, and Meta's docs treat it as a first-class API. Hand-rolling mocks would be a maintenance trap.
- **Deliberate-break verification at every stage.** "Tests pass" is necessary but not sufficient — every stage's done criteria includes deliberately breaking the code under test and confirming the tests catch it. This is the bar for "the tests actually do something."
- **No coverage gates.** We are not optimizing for line coverage; we're optimizing for catching specific classes of regression.
- **Do not chase the LiveKit-side WebRTC path in iOS tests.** Whether the mock camera feed flows all the way through `BufferCapturer` and produces a real WebRTC track on the simulator is an open question (below). If it doesn't, the iOS tier and viewer tier stay independent. Real-glasses runs cover the integration.

## Open questions

- **Does `MWDATMockDevice` ship in the same SPM package we already depend on**, or does it need separate vendoring? Settle by inspecting `Package.resolved` and trying to add the product before stage 3 starts.
- **Does MDK's mock camera feed produce a real WebRTC publish from the simulator?** If yes, stages 3-4 can assert against a LiveKit room. If no, simulator-side tests stop at `LocalVideoTrack` creation + first-frame delivery into `BufferCapturer`. Settle empirically in stage 3.
- **Stage 5 publisher mechanics.** Background `lk` process spawned by `npm run test:e2e` and torn down on exit, or a separate `make test:publisher` for the dev to start manually? Lean toward auto-spawn for ergonomics; revisit if it makes failures hard to debug.
- **Stage 5 LiveKit room reuse.** Use the existing `waza-proto` room with a test-specific invite, or a separate local-dev room? Separate room is cleaner (no risk of CI test pattern landing in a demo viewer) but requires another set of credentials.
- **Where do fixture MP4s live?** Vendored into `ios/WazaProto/WazaProtoTests/fixtures/` is simplest. If they grow past a few MB, move to Git LFS or fetch on first run. Defer until it matters.

## Done criteria

Stage-level done criteria are listed per stage above. Plan-level done = stages 1-5 each shipped and passing locally, README updated with how to run each.

## Decisions logged during implementation

*(filled in as we go)*

## Vincent's learnings

*(filled in as we go)*

## Tech debt opened

*(filled in as we go)*
