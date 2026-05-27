# 13 — Glasses "disconnected" status message

Cross-cutting polish. When the Glasses tab is selected and there is no active glasses link, the app currently shows a "Grant camera access" button as the gate prompt. That's misleading: the glasses aren't even connected — there's nothing to grant access *to* yet, and the user's actual next action is to put the glasses on.

## Goal

When source = **Glasses** and there is no active glasses device, the gate area shows a short status message — **"Disconnected. Don glasses to connect"** — instead of the camera-access gate row. Front-camera behavior is untouched: when source = **Front camera** and not publishing, the bottom status label remains **"Disconnected"** as today.

## Why this slice

Two recent ground-truths surface the bug:

- The Meta DAT team confirmed (discussion [#199](https://github.com/facebook/meta-wearables-dat-ios/discussions/199)) that the glasses link cycles aggressively over BT Classic; `activeDeviceID` is genuinely the "we can start a session" signal, and `cameraPermission` going nil during off-link periods is expected, not a permissions problem.
- `GlassesGateway.refreshCameraPermission` already documents this: *"nil typically means 'SDK can't check right now' (e.g. glasses momentarily off-link during a hinge fold), not a real revocation."*

So the gate UI is reading a transient/unknown state and pushing the user toward the wrong action ("Grant camera access") when the real action is "don the glasses." A first-time user who has never granted camera permission AND has the glasses off sees the wrong prompt twice — once for camera, when the prerequisite (glasses online) hasn't been met.

## Direction

Keep the change tight — UI-only, no gateway logic changes:

1. **Suppress the "Grant camera access" gate row** when no glasses are active (`glasses.activeDeviceID == nil`). The existing `requestCameraAccess` comment already notes "a missing perm surfaces clearly on session.start anyway," so we don't lose a real-world recovery path by hiding the prompt while no device is selectable.
2. **Show a single-line message in its place** — "Disconnected. Don glasses to connect" — styled like the bottom status label (callout monospaced, secondary foreground), not like an actionable button.
3. **Leave "Register with Meta AI" untouched.** Registration is the prerequisite step and doesn't depend on the glasses being online; it should still appear when `registrationState != .registered`.
4. **Bottom status label stays `connection.status.label`** unchanged — `"Disconnected"` in both source modes. The new message in the gate area is the place that carries the Glasses-specific guidance, so we don't end up with two competing status strings.

## Approach

The change lives entirely in `ios/WazaProto/WazaProto/ContentView.swift`, in the `glassesGate` view builder (currently lines ~114–134).

Today:

```swift
@ViewBuilder
private var glassesGate: some View {
    VStack(spacing: 8) {
        if glasses.registrationState != .registered {
            gateRow(title: "Register with Meta AI", ...)
        }
        if glasses.registrationState == .registered,
           glasses.cameraPermission != .granted {
            gateRow(title: "Grant camera access", ...)
        }
    }
}
```

After:

```swift
@ViewBuilder
private var glassesGate: some View {
    VStack(spacing: 8) {
        if glasses.registrationState != .registered {
            gateRow(title: "Register with Meta AI", ...)
        } else if glasses.activeDeviceID == nil {
            // Registered but no device online — the real next action is to put
            // the glasses on. Don't prompt for camera access here: cameraPermission
            // can read nil while the link is down (see GlassesGateway), which
            // would push the user toward the wrong fix.
            Text("Disconnected. Don glasses to connect")
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if glasses.cameraPermission != .granted {
            gateRow(title: "Grant camera access", ...)
        }
    }
}
```

That's the whole change.

## File layout (delta)

```code
ios/WazaProto/WazaProto/ContentView.swift   ← glassesGate view builder only
plans/active/13-glasses-disconnected-status.md
plans/index.md
```

## Key decisions (upfront)

- **Gate row, not bottom status, carries the Glasses-specific guidance.** The bottom label is shared with the Front-camera flow and the user explicitly asked for it to remain `"Disconnected"` there; the gate area is already the source-conditional surface.
- **No GlassesGateway changes.** The "don't demote `.granted` → nil" logic is correct as-is; the bug is the *consumer* reading a transient nil as actionable. Treat it at the UI layer.
- **"Grant camera access" still appears** once `activeDeviceID != nil` — i.e. when prompting for the permission is actually meaningful.
- **Wording: "Don glasses to connect."** Short, accurate, matches Meta's own onboarding language ("put your glasses on"). Avoid technical terms like "BT link" or "session" in the UI.

## Done criteria

1. With the glasses powered down (or off the user's head and link dropped), selecting the Glasses tab shows the new message and no "Grant camera access" button.
2. Putting the glasses on and waiting for `activeDeviceID != nil` returns the gate to its prior behavior — either no gate row (if permission is granted) or the "Grant camera access" button (if not).
3. With source = Front camera and disconnected, the bottom status label still reads "Disconnected".
4. Registration flow unchanged: a never-registered user still sees "Register with Meta AI".
5. Verified on-device with a real glasses connect/disconnect cycle (not just simulator).

## Decisions logged during implementation

- **Moved the copy from the gate area to the bottom status label.** First pass put a `Text` inside `glassesGate` alongside the bottom status label and the result was two stacked "Disconnected" lines on-device. Single source of truth for the disconnected-state text is the bottom status row; `glassesGate` is now silent when registered + no active device (the "Grant camera access" button is gated on `activeDeviceID != nil`).
- **Final copy: "Don glasses to connect"** (no "Disconnected." prefix). Visually cleaner and the prefix was redundant with the Front-camera "Disconnected" label that lives in the same slot when the other tab is selected — context already says what state we're in.
- **`VideoView.layoutMode` changed from `.fit` to `.fill`** as part of the same pass. With `.fit` the front-camera feed letterboxed against the black backdrop (visible left/right bars), and the two tabs rendered the video at visibly different sizes because their source aspect ratios differ. `.fill` makes both feeds fill the container, no black bars, same outer size — at the cost of cropping whatever overflows the container aspect. Acceptable for a self-preview; revisit only if the glasses POV crop is too tight in practice.
- **No `GlassesGateway` changes.** Kept the "don't demote `.granted` → nil" behavior intact; the bug was a UI consumer reading a transient state as actionable.
- **Dropped the proactive "Grant camera access" gate row entirely.** After the first deploy a real-world state surfaced (registered + `activeDeviceID != nil` + `cameraPermission == nil`) where the button reappeared even though the link wasn't streaming. Since `cameraPermission` reads nil whenever the BT link is down and the Meta SDK already prompts the user on `session.start` when permission is actually missing, removing the proactive prompt eliminates the false positive without losing a recovery path. Only proactive gate left is "Register with Meta AI".
- **Refactored gate state into a single `GlassesGateAction` enum.** `glassesGate`, `showGlassesGate`, and `statusLabel` now all read from `glassesGateAction` instead of duplicating the predicate. Makes the rule auditable and prevents the kind of inconsistency the first pass had (where `showGlassesGate` and `glassesGate`'s body disagreed in edge cases).
- **Skipped rendering `glassesGate` when there's no gate action.** Earlier pass left an empty `VStack` in the layout; the parent's `spacing: 16` still allocated ~32pt on either side of it, which shortened the preview on the Glasses tab vs. Front camera. Hoisting the emptiness check to the parent's `if` removes the phantom spacing.
- **Pinned `actionButton` to a fixed 50pt height.** The three states (`Connect` borderedProminent, bare `ProgressView`, `Disconnect` bordered) had different intrinsic heights, so the preview area resized every time the connection status transitioned through `.connecting` / `.switching`. Locking the height stabilizes the layout.

## Vincent's learnings

*(filled in as we go)*

## Tech debt opened

*(filled in as we go)*
