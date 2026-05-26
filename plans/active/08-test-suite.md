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

### Stage 4 follow-up — frame-delivery deep-dive (2026-05-26)

After stage 4's spike hit the same wall as stage 3, did a focused investigation into whether `stream.videoFramePublisher` can fire on iOS 26.5 simulator under `xcodebuild test`. Cloned `facebook/meta-wearables-dat-ios` 0.7.0 and diffed `samples/CameraAccess` against our code.

- **Bug fixed: `Wearables.configure()` was being skipped under `--ui-testing`.** Meta's `CameraAccessApp.init()` calls `Wearables.configure()` *unconditionally first*, then conditionally `MockDeviceKit.shared.enable(...)`. Our stage-4 init had them in the opposite order and `return`'d before configure(), to avoid the `WearablesError(rawValue: 1)` crash that happens when configure() runs *after* enable(). Right fix: configure() first, MDK enable second.
- **Bug fixed: test setUp also missed `Wearables.configure()`.** Meta's `CameraAccessTests.setUp` does `try? Wearables.configure()` *before* `MockDeviceKit.shared.enable()`. Our `MockDeviceKitTestCase` skipped configure() entirely. Adopted Meta's pattern (also dropped `MockDeviceKitConfig(initiallyRegistered: true, initialPermissionsGranted: true)` in favor of `enable()` no-args, matching the asserting test).
- **Despite both fixes, frames still don't arrive on simulator.** Wrote a `testRawStreamDeliversFirstFrame` that mirrors Meta's `testVideoStreamingFlow` line-by-line — `Wearables.shared.createSession(deviceSelector:)` → `start()` → wait for `.started` → `addStream(.raw / .low / 24)` → listener registered with retained token → `await stream.start()` → 10s timeout waiting for the listener. Times out every time. (Test deleted; would just be perma-red.)
- **Meta's own reference test doesn't run on our simulator either.** Ran their `CameraAccessTests/ViewModelIntegrationTests/testVideoStreamingFlow` directly via `xcodebuild test -project /tmp/.../samples/CameraAccess/CameraAccess.xcodeproj` against iOS 26.5 sim. Result: app crashes at launch with `MWDATCore/Wearables.swift:242: Fatal error: Call configure() before attempting to access Wearables!` — their `try Wearables.configure()` in the app's init() throws silently (caught by `do/catch`), then SwiftUI body accesses `Wearables.shared` and fatals. So in our environment, even their reference test can't bootstrap. Likely an Info.plist or DAT-app-registration prerequisite that the sample doesn't carry, or an iOS-26.5-specific bug in `configure()` under `xcodebuild test`. Either way: not something we can patch from our side.
- **Conclusion: frame-delivery test coverage on simulator is blocked, not just deferred.** Three independent attempts (in-process MDK, out-of-process test server, raw SDK call mirroring Meta's reference) all hit the same wall on iOS 26.5 sim. Meta's own test can't even launch in our environment. There is no documented config flag we haven't tried, no version newer than 0.7.0 to upgrade to (current SDK is the latest release), and the CHANGELOG has no entry about simulator frame delivery. Real-glasses runs continue to cover the frame path. If this becomes blocking later, the move is to file an upstream issue with the test-app-crash repro.
- **What we kept from the investigation, even though frames still don't flow:**
  - `WazaProtoApp.init` now calls `Wearables.configure()` first and `MockDeviceKit.shared.enable(...)` second, matching Meta's pattern. Less brittle than the prior `return`-before-configure path.
  - `MockDeviceKitTestCase` now calls `try? Wearables.configure()` before `MockDeviceKit.shared.enable()` (no config). Matches Meta's reference test setup. `testWearablesDiscoversMockDevice` still green.

### Stage 4

- **Frame-delivery wall is the same out-of-process as in-process — same MDK internals.** Spike: wired the `--ui-testing` app-init gate, brought up `MockDeviceKit.shared.startTestServer(...)` in-process, drove it from XCUITest via `MockDeviceTestClient(portFilePath:)` (`pairDevice` + `setCameraFeed(resourceName:"mock-camera", ext:"mp4")`), tapped Connect with Glasses selected. `GlassesGateway` flipped `isReady → true`, the publish flow ran, but `stream.videoFramePublisher` never fired — the test timed out waiting for `"Publishing as ios-publisher"`. Hits exactly the stage-3 wall, as the pre-stage research called: "the server runs the same `MockDeviceKit.shared` internals … if the failure was a deeper sim-vs-SDK frame-pipeline incompatibility in 26.5, the server won't help."
- **Stage 4 re-scoped to a single Connect-enabled smoke test.** What still surfaces real regressions through the test-server transport: the `--ui-testing` launch-argument gate, `MWDATMockDevice` linkage to the main app, the `MockDeviceTestClient` port-file handshake (`waitForServer`), and the SwiftUI `canConnect` logic gating the Connect button on `glasses.isReady`. Test: pair via HTTP → wait for `Connect.isEnabled == true` within 10s. Runs in ~6s. Drops the `Publishing` assertion, the hinge-fold scenario, the source-toggle scenario, and the watcher-count badge scenario — all of which depend on frame delivery or fold propagation, neither of which the simulator's MDK provides (in- or out-of-process).
- **`Wearables.configure()` must NOT be called when MDK is enabled — it throws `WearablesError(rawValue: 1)` and `assertionFailure`s the app at launch.** `MockDeviceKit.shared.enable(config:)` configures the Wearables backend itself. The `--ui-testing` branch in `WazaProtoApp.init()` returns early to skip `Wearables.configure()`.
- **`MWDATMockDevice` is linked into the main app target unconditionally.** Stage 4 needs it at runtime (the test server runs in-process under `--ui-testing`). The framework ships in every build — fine for a prototype, would want a DEBUG-only or separate-config gate before this goes to TestFlight. Linkage is dead-stripped if `--ui-testing` is never set, so the surface bloat is small in practice.
- **Fixture lives on both the test bundle and the main app bundle.** `setCameraFeed(deviceId:resourceName:ext:)` over HTTP loads the resource from the **host app's** bundle (the test server runs in-process there). The stage-3 unit test still loads it from the test bundle. Same file, dual Target Membership on the `fixtures/` folder reference.
- **Stage 4 done-criteria #2 (deliberately break the watchdog) is not verifiable** with the re-scoped test — no hinge-fold path exercised. Done-criteria #3 (deliberately break `connect()`) is partially verifiable: a break that prevents `isReady` from going true would fail the new test. The stricter "deliberate break of the publish path" check has no test that covers it on simulator; falls back to on-device manual verification.

### Stage 3

- **Open question resolved: MDK frame delivery doesn't work on the iOS Simulator (in-process API).** Empirical: after `pairRaybanMeta()` + `powerOn()` + `unfold()` + 1s settle + `setCameraFeed(fileURL:)`, the real `Wearables.shared` sees the mock and `AutoDeviceSelector.activeDevice` fires. We can `createSession() → start() → addStream() → stream.start()` without error. But `stream.videoFramePublisher.listen` is **never** called — `recv fps: 0` forever on the WARP transport. Tried both `.hvc1` (our production codec) and `.raw / .low / 24fps` (the codec Meta's own `CameraAccessTests.testVideoStreamingFlow()` uses). Neither produces frames. `FigCaptureSourceSimulator err=-12784` bursts in the log are unrelated AVFoundation-on-simulator noise.
- **Open question resolved: `mockDevice.fold()` doesn't propagate to session termination on the simulator either.** With an active stream attached, fold() leaves session state at `.started` and the watchdog never fires `onTerminated`. Confirmed up to a 10s wait. So the watchdog-wiring test is not exercisable through the in-process API on simulator.
- **Stage 3 re-scoped to smoke only.** Ship `testWearablesDiscoversMockDevice` (MDK setup → real SDK sees the mock). Drop the `prepareTrack`/`unpublish`/hinge-fold/source-swap assertions — they all require either frame delivery or fold-propagation, neither of which the simulator's in-process MDK provides. The plan explicitly anticipated this re-scope ("If no, simulator-side tests stop at LocalVideoTrack creation + first-frame delivery into BufferCapturer"); we're stopping one notch earlier than that.
- **GlassesSource left untouched.** Initially extracted `prepareTrack()` from `publish(to:)` thinking we'd drive it in tests; reverted once we re-scoped — the extraction served no shipped test, so minimum diff wins.
- **Setup recipe from Meta's CameraAccessTests is load-bearing.** `MockDeviceKit.shared.enable(config:)` + `pairRaybanMeta()` + `powerOn()` + **`unfold()`** (not `don()`) + 1s sleep, before any session work. Without `unfold()` the device shows up but streams are gated off; without the sleep, `createSession` can race the registration stream.
- **Hinge-fold + source-swap coverage deferred to stage 4 (MDK test server, out-of-process).** Different transport — may behave differently. Real-device manual verification covers it in the meantime.

### Stage 2

- **XCTest, not Swift Testing.** Xcode auto-generated a Swift Testing stub (`import Testing`, `@Test` macros) when the target was created. Replaced with XCTest for consistency with stages 3-4 — Meta's `MockDeviceKitTestCase` pattern (stage 3) and XCUITest (stage 4) are both XCTest-based, and mixing frameworks across stages would split the mental model. Swift Testing and XCTest can coexist in one target, so we can adopt Swift Testing later for individual files if it's clearly nicer.
- **`watcherCount` extracted as `nonisolated static func`.** `RoomConnection` is `@MainActor`, so any helper declared on it inherits MainActor isolation by default — and XCTest's test methods are synchronous and non-isolated, which made the helper uncallable from tests. Marking the static helper `nonisolated` is the right call because it's purely a function over `[String]` (no shared mutable state, no UI), and it lets tests stay non-isolated. The instance method `currentWatcherCount()` stays MainActor-scoped because it reads `room.remoteParticipants` (which is) and delegates to the pure helper.
- **`Secrets` tests are shape validation, not "env loading."** The plan called for env-loading + missing-key behavior, but `Secrets.swift` is just a compile-time `enum` of string literals (regenerated by `refresh-secrets.sh`) — there is no env-loading path to test. Tests instead assert `wsURL` is a valid `wss://` URL, `token` has 3 JWT segments with `alg: HS256`, and `inviteSigningSecret` is base64-decodable with ≥256 bits of key material. Guards against `refresh-secrets.sh` regressions, not env-var bugs.

## Vincent's learnings

*(filled in as we go)*

## Tech debt opened

*(filled in as we go)*
