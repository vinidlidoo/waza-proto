# 18 — Test suite: close pure-logic gaps, prune compiler tests

Cross-cutting infra (not a build-ladder rung). Follow-up to [plan 08](../completed/08-test-suite.md), which stood up the five-tier local suite. An inventory of the suite against the current code (2026-05-28) found it spends assertions on things the Swift compiler already guarantees while leaving pure logic that's *on the default path* uncovered. This plan adds the missing units, prunes the no-signal tests, and adds one targeted MDK wiring check for the permission gate.

Most of this is fully-automated pure-logic XCTest (plain values in, values out) — **nothing here needs real glasses, and nothing depends on MDK delivering frames or propagating a hinge-fold**, both of which are broken on-simulator upstream ([meta-wearables-dat-ios#197](https://github.com/facebook/meta-wearables-dat-ios/issues/197); plan 08 stage 3). The one exception (stage 4) drives MDK **device/registration/permission state**, which *does* work on-simulator (verified against the SDK interface) — see "What MDK can and can't do" below.

## Goal

Four changes, each independently shippable, each verified by a deliberate break:

1. **Prune** the two `RoomConnection.Status` equality tests that only exercise auto-synthesized `Equatable`.
2. **Cover the two untested pure functions on the shipped default path:** `FrameSmoothingBuffer` (plan 12's smoothing contract; active at `Config.glassesSmoothingDepth = 2`) and `InviteToken.mint` (the iOS invite-mint, currently the only token path tested on just one side of the wire).
3. **Extract the glasses pre-connect gate decision into a pure function and pin it with an exhaustive truth table** — the primary, MDK-free guard for logic that has regressed twice (incl. the `nil`-permission race that MDK can't even express).
4. **Add one MDK *wiring* test for the permission gate:** mock with camera-denied → `GlassesGateway.cameraPermission` becomes `.denied` → gate yields `.grantCamera`. Preferably an in-process XCTest (runtime `permissions.set`); an XCUITest asserting the SwiftUI row renders is an optional top layer. Integration complement to #3, within MDK's working surface.

No new test *tiers*, no CI, no coverage gates — same philosophy as plan 08. Pure logic gets unit tests; anything needing a live `Room`, real frames, or the BT link stays on-device.

**Dropped from the first draft:** `HEVCAnnexBExtractor.containsIRAP`. It lives entirely behind `Config.glassesEncodedIngest` (hardwired `false`) — confirmed zero callers in the default path — so it's not exercised by the shipping app. Re-add coverage if/when the encoded pass-through path is taken off the flag (tracked in Out of scope).

## Why this slice

The suite's philosophy is sound, but its coverage map has holes that line up with where bugs ship and where logic actually runs:

- **`FrameSmoothingBuffer` has zero tests** (`GlassesSource.swift:402`) and is on the **default** path (`Config.glassesSmoothingDepth = 2`, used in the non-encoded branch). Plan 12's entire payoff (78% viewer-freeze reduction) rides on a specific contract — prime-before-pull, repeat-last on underrun, drop-oldest on overrun, `drain()` re-arms priming. Break any rule and you get back either the latency or the stutter the buffer exists to remove, with no test to catch it. The buffer never inspects pixel contents, so it's fully testable with throwaway `CVPixelBuffer`s on a single thread.
- **`InviteToken.mint` has zero tests** (`InviteToken.swift:9`) while its mirror twin `PublisherTokenClient.buildEnvelope` has five. The viewer's `viewer-token.test.js` proves the *server* validates invites, but nothing proves the *iOS app produces a valid one* — so a regression in the invite envelope silently breaks "Copy viewer link" (`ContentView.swift:87`). The publisher path is tested on both ends; the invite path is tested on one. That asymmetry is the gap.
- **The glasses gate decision** (`ContentView.swift:117-121` + `GlassesGateway.isReady` at `GlassesGateway.swift:122`) has already regressed **multiple times** — the comment at `ContentView.swift:98-110` documents the "Grant camera access" button wrongly reappearing on cold start and plan 13's bad self-prompt assumption. It's a pure function of three inputs and today has no direct test at all (only the indirect, all-clear `ConnectFlowUITests` path). It's the single most regression-prone piece of UI logic in the app.

Conversely, the two `Status` equality tests (`RoomConnectionTests.swift:6-19`) test compiler-synthesized `Equatable` — there is no custom `==` on `Status` (confirmed). They assert that `.disconnected == .disconnected`; that's testing Swift, not our code. The sibling label test (`:21-27`) is the opposite and stays — those strings are a real UI/viewer contract.

### What MDK can and can't do (the real ceiling)

The MDK ceiling is **narrower** than "no glasses tests." #197 is specifically a **frame-delivery** bug; plan 08 stage 3 separately found **fold→session-termination** doesn't propagate. Everything else works on-simulator — and we already prove it: `testWearablesDiscoversMockDevice` passes, so device discovery + `AutoDeviceSelector` active-state are live. The permission surface in particular is fully controllable — settled from the SDK's own `.swiftinterface` (2026-05-28), no run needed:

- **`PermissionStatus` has exactly two cases: `.granted`, `.denied`** (MWDATCore). No `.notDetermined`/`.unknown`. The `nil` our app stores in `cameraPermission` comes *only* from `try?` swallowing a thrown `PermissionError` (the typed-throw `checkPermissionStatus(_:) async throws(PermissionError) -> PermissionStatus`) when the link is down — it is never an enum case.
- **`MockDeviceKitConfig(initiallyRegistered: Bool = true, initialPermissionsGranted: Bool = true)`** — since the enum has only two cases, `initialPermissionsGranted: false` ⇒ `.denied`. A *connected* mock returns it (doesn't throw), so our gate sees `cameraPermission == .denied`. **Pre-check resolved.**
- **`MockDeviceKit.shared.permissions: MockPermissions`** (note: on the *kit*, not the device — the device's `services` is only `camera`/`captouch`) exposes `set(_:_:)` / `setRequestResult(_:result:)` — full runtime control of the mock's permission status. **But this is in-process only:** the test-server client surface (`pairDevice/powerOn/don/doff/fold/unfold/captouch*/setCameraFeed/setCapturedImage/getDeviceState/healthCheck`) has **no permission method.** So an XCUITest can only set permission at *launch* via the config; an in-process XCTest can flip it at *runtime* via `MockDeviceKit.shared.permissions.set`.

**Empirically confirmed (2026-05-28, throwaway probe on iPhone 17 / iOS 26.5 sim, since deleted):** with a paired+donned mock active, `Wearables.shared.checkPermissionStatus(.camera)` **RETURNED** `granted` by default, `denied` after `MockDeviceKit.shared.permissions.set(.camera, .denied)`, and `granted` after setting it back — three clean returns, zero throws. So a denied connected mock surfaces in our app as `cameraPermission == .denied` (not `nil`), and runtime `set` is honored by the global check. Stage 4 is viable exactly as written.

| MDK capability on simulator | Works? | How / source |
|---|---|---|
| Device discovery / `AutoDeviceSelector` active state | ✅ | our passing `testWearablesDiscoversMockDevice` |
| Camera permission granted/denied | ✅ | config at launch; `MockDeviceKit.shared.permissions.set(...)` in-process (not over test server); **probe-confirmed returns, never throws** |
| Registration state | ✅ | `MockDeviceKitConfig.initiallyRegistered` |
| `videoFramePublisher` frame delivery | ❌ | #197 (Meta-confirmed, open) |
| `fold()` → session termination | ❌ | plan 08 stage 3 |

So the **gate UI** (a function of registration × active-device × permission, none of which need a frame) *is* MDK-testable. But for the gate's **logic**, the pure function is still the primary guard:

- The regression that recurred was the **`nil`-permission** case: `checkPermissionStatus(.camera)` throws when the BT link is momentarily down (mid-fold / cold start), `try?` swallows it to `nil`, and the old code treated `nil` as "not granted" → button reappeared even though permission *was* granted. The fix gates on `== .denied` only (`ContentView.swift:119`).
- MDK's config/`set` express **granted vs denied** — neither produces the transient **`nil`-while-active** race directly. (An in-process test could *try* to induce the throw via `doff()`/off-link, but that's an empirical stretch, not a guarantee; the pure test already nails the `nil` logic.)

Hence the split: a pure truth table covers all three permission states (incl. `nil`) deterministically in milliseconds; an MDK test confirms the *wiring* (real `GlassesGateway` streams → published `cameraPermission` → gate) for the states MDK can express.

Why now: cheap. Items 1–3 touch no production behavior beyond two small pure refactors; the stage-4 wiring test is preferably an in-process XCTest (uses `permissions.set`, no production change), with the XCUITest as an optional top layer.

## Approach — staged, deliberate-break bar at each stage

Carries forward plan 08's bar: each stage deliberately breaks the code under test and confirms the suite goes red. Run via `xcodebuild test -scheme WazaProto -destination 'platform=iOS Simulator,…'`; if the `Wearables.configure()` bootstrap fatal appears, add `CODE_SIGN_IDENTITY="-"` (ad-hoc), per #197 — never `CODE_SIGNING_ALLOWED=NO`. New `.swift` files must be added to the right target's membership in `project.pbxproj` (via Xcode or a direct edit) — same wiring step as plan 08.

### Stage 1 — Prune (no new files)

Delete `testEqualityForCasesWithoutAssociatedValues` and `testEqualityRespectsFailedAssociatedValue` from `RoomConnectionStatusTests`. Keep `testLabelsMatchUIContract`.

**Done:** `xcodebuild test` green; the deleted tests are gone; `testLabelsMatchUIContract` still runs.

### Stage 2 — Pure logic on the default path

**`FrameSmoothingBufferTests.swift`** (`WazaProtoTests`) — single-threaded, throwaway frames via `CVPixelBufferCreate` (contents irrelevant; track identity by object reference). Pin the contract:

- `pull()` returns `nil` until `primeDepth` pushes have landed (not yet primed).
- After priming, `pull()` returns frames FIFO.
- Underrun (empty after primed) → `pull()` returns the *last* frame, not `nil` (repeat-last).
- Overrun (push past `maxDepth`) → oldest dropped, newest retained.
- `drain()` resets `primed` so the next fill re-primes.

**`InviteTokenTests.swift`** (`WazaProtoTests`) — mirror `PublisherTokenClientTests`. Extract a pure builder so `iat`/`exp` are deterministic and the test doesn't depend on generated `Secrets`:

```swift
static func buildEnvelope(secret: String, ttl: TimeInterval = 3*60*60, now: Date = Date()) -> String
static func mint() -> String { buildEnvelope(secret: Secrets.inviteSigningSecret) }
```

Test: three non-empty dot-separated segments; header `alg=HS256`/`typ=JWT`; payload `exp - iat == ttl`; signature verifies under the test secret and rejects a wrong one.

**Done:** both suites green. Break the smoother's underrun branch (return `nil` instead of `lastFrame`) → its test red. Break `buildEnvelope` (drop the base64url `+→-` swap) → the invite test red.

### Stage 3 — Gate predicate (pure, primary guard)

Extract the gate decision as a `nonisolated static` pure function — the same move plan 08 stage 2 made for `RoomConnection.watcherCount`. Inputs are plain values, not a live `Wearables` (`GlassesGateway`'s `@Published` props are `private(set)`, so the instance isn't drivable from a test):

```swift
// on GlassesGateway (or a small free enum)
static func gateAction(registrationState:, hasActiveDevice:, cameraPermission:) -> GateAction
static func isReady(registrationState:, hasActiveDevice:) -> Bool
```

`GlassesGateway.isReady` and `ContentView.glassesGateAction` delegate to these — behavior identical, logic now testable. **`GlassesGateTests.swift`** (`WazaProtoTests`) truth table:

- not-registered → `.register` regardless of the rest
- registered + no active device → `.none` (the "don glasses" path)
- registered + active + `.denied` → `.grantCamera`
- registered + active + `.granted` → `.none`
- **registered + active + `nil` → `.none`** (the cold-start regression that must stay fixed — the row MDK can't express)
- `isReady` true iff registered AND active device present

**Done:** suite green. Break the gate (gate on `!= .granted` instead of `== .denied`, the original plan-13 bug) → the `nil`-permission row goes red. This is the test that actually pins the recurring bug.

### Stage 4 — Permission-gate wiring (MDK, in-process XCTest preferred)

Proves the stage-3 pure function is actually wired to reality — that `GlassesGateway.refreshCameraPermission()` translates the SDK's permission answer into the published `cameraPermission` the gate reads. This is the layer where the bug actually lived. The pre-check is already resolved (see "What MDK can and can't do"): a denied connected mock returns `.denied`, not `nil`.

**Primary: in-process integration XCTest** (`GlassesGatewayMDKTests.swift`, extends `MockDeviceKitTestCase`). With the mock paired+active, flip permission at runtime via `MockDeviceKit.shared.permissions.set(.camera, .denied)` (probe-confirmed to be honored by `checkPermissionStatus`), instantiate `GlassesGateway`, `startObserving()` + `await refreshCameraPermission()`, then assert `gateway.cameraPermission == .denied` **and** the stage-3 predicate yields `.grantCamera`. Fast, runtime-controllable, no test-server, no #197 surface. Also flip to `.granted` and assert `.none`.

**Optional top layer: XCUITest** asserting the SwiftUI **"Grant camera access"** row actually renders. Only this layer needs the app to launch non-all-clear, so parameterize the `--ui-testing` init (`WazaProtoApp.swift:31-41`) — the test-server client can't set permissions, so it must come from launch config:

```swift
let registered = !args.contains("--mdk-unregistered")     // default true
let granted    = !args.contains("--mdk-camera-denied")    // default true
MockDeviceKit.shared.enable(config: MockDeviceKitConfig(
    initiallyRegistered: registered, initialPermissionsGranted: granted))
```

Then `ConnectFlowUITests` launches with `--mdk-camera-denied`, pairs via the test server, selects Glasses, asserts the row appears. Do this layer only if View-level rendering confidence is wanted on top of the in-process test; otherwise skip it (the granted/no-row case is already covered by `testPairingMockDeviceEnablesConnect`).

**Done:** the in-process test goes green; reverting the stage-3 gate fix (`!= .granted` instead of `== .denied`) turns it red. If the optional XCUITest is built, the denied-launch row test also goes red on that revert.

## File layout (delta)

```code
ios/WazaProto/
  WazaProto/
    InviteToken.swift                  ← extract pure buildEnvelope(secret:ttl:now:)        (stage 2)
    GlassesGateway.swift               ← extract nonisolated static gate predicate          (stage 3)
    ContentView.swift                  ← glassesGateAction delegates to the predicate        (stage 3)
    WazaProtoApp.swift                 ← --ui-testing reads --mdk-* launch args (stage 4, ONLY if XCUITest layer)
  WazaProtoTests/
    RoomConnectionTests.swift          ← drop 2 Status-equality tests                        (stage 1)
    FrameSmoothingBufferTests.swift    ← new (stage 2)
    InviteTokenTests.swift             ← new (stage 2)
    GlassesGateTests.swift             ← new (stage 3)
    GlassesGatewayMDKTests.swift       ← new — in-process permission-wiring test             (stage 4)
  WazaProtoUITests/
    ConnectFlowUITests.swift           ← + camera-denied gate-row test (stage 4, OPTIONAL top layer)
  WazaProto.xcodeproj/project.pbxproj  ← add the 4 new test files to their targets
plans/active/18-test-suite-gaps.md     ← this file
plans/index.md                         ← Active entry
```

No viewer changes — the JS/vitest/Playwright tiers are already well-covered.

## Key decisions (upfront)

- **Gate logic: pure function is primary, MDK is a wiring complement — not a replacement.** The pure truth table is the only thing that can cover the `nil`-permission race that actually regressed (MDK config/`set` can't express link-down-while-active). An MDK test then confirms the function is connected to the real `GlassesGateway` permission translation. Test-pyramid split: logic in the fast/exhaustive pure layer, wiring in the integration layer.
- **Stage-4 wiring test is in-process XCTest, not XCUITest.** Permission state is settable in-process at runtime (`MockDeviceKit.shared.permissions.set`) but **not** over the test server (no permission method on the client), so the in-process route is both cheaper and more capable — it tests the actual `GlassesGateway.refreshCameraPermission` translation where the bug lived, at unit speed, off the #197-adjacent infra. The XCUITest is optional and only adds View-render confidence.
- **Pre-check resolved from the SDK `.swiftinterface` and confirmed by a probe.** `PermissionStatus` = {granted, denied}; a connected mock with `set(.camera, .denied)` returns `.denied` (probe-verified, never throws). Stage 4 is viable as written; no speculative gating left.
- **Dropped `HEVCAnnexBExtractor.containsIRAP`.** Behind `Config.glassesEncodedIngest = false` with zero callers on the default path. Revisit only if the encoded pass-through path is un-flagged.
- **Delete the `Status` equality tests, don't rewrite them.** Auto-synthesized `Equatable` = testing the compiler. The label test stays (real UI/viewer contract).
- **Give `InviteToken` the same `buildEnvelope(secret:ttl:now:)` seam as `PublisherTokenClient`.** Makes the two token paths structurally identical and removes the test's dependency on generated `Secrets`. Consistency over the absolute-minimum diff.
- **Extract the gate predicate as a pure `static`, mirroring `watcherCount`** (plan 08 stage 2 precedent). Production behavior unchanged; `isReady` and `glassesGateAction` just delegate.
- **Keep the always-skipped `testVideoFramePublisherFiresOnSimulator`** (`GlassesSourceMDKTests.swift:70`) — a documented #197 re-probe switch, deliberate exception to the deliberate-break bar.
- **Keep `SecretsTests`.** Config guards against a malformed `refresh-secrets.sh`, not logic tests; not worth expanding or removing.
- **No coverage gate, no new tier.**

## Out of scope (deferred)

- **`HEVCAnnexBExtractor.containsIRAP` + the encoded-ingest path.** Flag-gated off. The scanner is pure and regression-prone (root-caused the plan-17 freeze), so cover it *if/when* that path ships — captured here so the gap is re-opened deliberately, not forgotten.
- **Anything needing MDK frame delivery or hinge-fold→session-termination** — blocked upstream by #197 / plan 08 stage 3; revisit if Meta lands a fix.
- **`VideoQualityProfiler.percentile`/`intPercentile`/`delta`** (`VideoQualityProfiler.swift:317,322,260`) — pure and off-by-one-prone, but diagnostics, not production behavior. Cover only if an A/B decision starts hinging on the profiler numbers.
- **`EncodedFrameTCPServer`, `RoomConnection.connect/switchSource`, the `GlassesSource` frame pipeline** — need live networking / a `Room` / real frames; left to e2e + on-device, per plan 08.

## Done criteria

1. `xcodebuild test -scheme WazaProto -destination 'platform=iOS Simulator,…'` green after each stage (add `CODE_SIGN_IDENTITY="-"` if the configure() bootstrap fatal appears).
2. Each stage's deliberate break (listed per stage) turns the relevant test red; revert → green.
3. The two `Status` equality tests are gone; `FrameSmoothingBuffer`, `InviteToken`, and the gate predicate each have a dedicated pure suite; the gate `nil`-permission row is covered.
4. Stage 4's in-process wiring test drives a denied mock through `GlassesGateway` and asserts `cameraPermission == .denied` → `.grantCamera`; the optional XCUITest row-render layer is either shipped or consciously skipped (not left half-built).
5. The `InviteToken` and gate extractions are pure refactors — verified by their unit tests; a quick "Copy viewer link" sanity check (no glasses) confirms the invite still works.

## Decisions logged during implementation

*(filled in as we go)*

## Vincent's learnings

*(filled in as we go)*

## Tech debt opened

*(filled in as we go)*
