# 24 — Full-bleed streaming UI (corner controls)

Today the publisher screen is a stacked `VStack` (`ContentView.swift`): an inset rounded video preview on a white background, a full-width segmented **Front · Rear · Glasses** `Picker` below it, an optional glasses-gate row, optional debug panels, and a bottom status `HStack` carrying the connect / copy-link / debug icons plus a status label. Every control sits *outside* the video and the four icon-buttons share one flat visual weight.

This slice replaces that layout with a **full-bleed video** and **floating corner controls**: the camera feed fills the screen edge-to-edge (the device's own screen corners frame it — no drawn border), and the controls live in its safe-area corners. The segmented picker becomes a discreet bottom-left **source switcher** that blooms vertically on tap; connect becomes a centered **play/stop** button; the persistent status bar is removed in favour of ephemeral message pills (it returns only in debug mode).

This is a **view-layer rewrite only** — all of `RoomConnection`, `GlassesGateway`, the source/publisher layer, the profiler, and the gate *decision* logic are reused unchanged. The design was settled interactively against a live SwiftUI preview harness (`SourceSwitcherPreview.swift`), which this slice deletes once the real view is wired.

## Goal

The publisher screen is an immersive viewfinder: the live feed fills the screen, and the controls float over it in the corners —

- **bottom-left** source switcher (collapsed = current source glyph; tap → blooms the three options upward, active anchored at the bottom),
- **bottom-center** play/stop connect,
- **bottom-right** coach (live only),
- **top-right** audience zone — `N watching` then the copy-link button (live only),
- **top-left** muted debug toggle.

No persistent status bar. Errors / gate guidance / "link copied" surface as transient pills. Debug mode shrinks the video up and shows the existing debug panels underneath, as today. Behaviour (live source-swap, the glasses gate, profiler, mirror rule, "N watching", copy-link toast) is preserved — only its presentation changes.

## Why this slice

The control *logic* is already well-factored and stays put — this is purely about altitude and grouping in the view:

- The source switcher binds to the same `@State source` and calls the same `connection.switchSource(to:glasses:)` the picker's `onChange` calls; the live-swap guard (`canConnect(for:)` + revert) is unchanged.
- Play/stop maps 1:1 onto the existing `connection.status` machine and the existing `connect` / `disconnect` calls — the same states `connectButton` already switches on (`disconnected`/`failed` → play, `connecting`/`switching` → spinner, `connected` → stop).
- Coach, watcher badge, and copy-link toast already exist (`coachButton` `:259`, badge `:20`, `copyViewerLink`/`copyToast` `:90`) — they're restyled and repositioned, not rebuilt.
- The glasses gate's decision is already a pure function (`GlassesGateway.gateAction`, surfaced via `glassesGateAction`/`showGlassesGate` `:106`); only the *container* that renders `glassesGate` `:144` moves.
- Debug panels (`profilerDebug`, `devicesDebug`) are reused verbatim, just re-parented beneath the (now-shrinking) video.

So the change is concentrated in `ContentView.body` and a few new private subviews — no model, no networking, no pipeline, no `viewer/`, no `project.pbxproj` (synchronized file group), no Info.plist.

## Component spec (locked)

Settled visual language — all controls are circles over the feed:

- **Switcher pills** — 44pt, `.ultraThinMaterial` circle, white glyph. Active source carries a 2pt **white ring** (not a colour fill). Glyphs: `person.fill` (front / you), `camera.fill` (rear / world), `eyeglasses` (glasses). Collapsed = the active pill only; expanded = a `VStack` of all three with the active one anchored at the bottom (others bloom above), spring animation. Glasses-not-ready pill is dimmed (~0.35) but **still selectable** (see gate).
- **Connect** — 44pt, bottom-center. Idle: `play.fill`, **dark glyph** on `.regularMaterial` (crisp). Live: `stop.fill` white on **red**. Transition: small spinner on `.regularMaterial`. Disabled while `!canConnect` (idle) and during `.connecting`/`.switching`.
- **Coach** — 44pt blue circle, `sparkles`; live only. Reuses `coachBusy`/`coachPresent` states (busy = spinner, present = gray+red icon, idle = blue) from the current `coachButton`.
- **Audience** (top-right, live only) — `N watching` capsule (existing red badge style) then the copy-link button (`link`, 36pt material circle) in the far corner.
- **Debug** (top-left) — `ladybug`/`ladybug.fill`, 36pt material circle, ~0.6 opacity when off.
- **Colour grammar** — red = live (stop button + watcher badge), blue = coach, white/material = neutral controls. No other accent colours.
- **Borders** — none. Full-bleed video to the screen edges; the iPhone's hardware screen corners do the framing. Controls inset to the safe area. **Top + bottom legibility scrims** (black→clear gradients, ~120/140pt) sit behind the control clusters — invisible over dark feeds, keep controls readable over bright outdoor feeds.
- **Messages** — no persistent bar. A transient **red pill** (top-center, inset so it clears the corner controls) for errors / "Don glasses to connect"; a transient **green pill** for "Link copied". Debug mode shows the existing status + panels beneath the shrunk video.

## Direction

1. **Rewrite `ContentView.body`** as a `ZStack`/overlay over a full-bleed `LocalPreview`. Video uses `.ignoresSafeArea()`; control overlays respect the safe area. When `showDebug`, wrap video + debug panels in a `VStack` so the video shrinks up and the panels appear beneath (today's behaviour, now animated).
2. **Add private subviews** for the switcher, the connect button, the audience cluster, and the message pills. Keep them in `ContentView.swift` (small, view-only) rather than new files.
3. **Re-house the glasses gate** (see decision) as an overlay card surfaced when glasses is the selected source and `glassesGateAction != .none`, reusing `glassesGate`'s existing content/actions.
4. **Add scrims** behind the top and bottom control clusters.
5. **Delete `SourceSwitcherPreview.swift`** (the throwaway harness) and deploy to the iPhone 17 for the animation/thumb-reach pass.

## Approach

### `ContentView.swift`

`body` becomes (sketch — reusing existing members):

```swift
var body: some View {
    VStack(spacing: 0) {
        LocalPreview(track: connection.localVideoTrack, mirror: source == .frontCamera)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black)
            .overlay { topScrim; bottomScrim }          // legibility
            .overlay(alignment: .topLeading)     { debugToggle }
            .overlay(alignment: .topTrailing)    { if case .connected = connection.status { audienceCluster } }
            .overlay(alignment: .top)            { messagePill }   // error / gate / toast
            .overlay(alignment: .bottomLeading)  { sourceSwitcher }
            .overlay(alignment: .bottom)         { connectControl }
            .overlay(alignment: .bottomTrailing) { if case .connected = connection.status { coachButton } }
            .overlay(alignment: .center)         { glassesGateCard }   // re-housed gate
            .ignoresSafeArea()                    // video to the edges; overlays use safe-area insets
        if showDebug { debugPanels }              // profilerDebug + devicesDebug; video shrinks up
    }
    .onAppear { … }                               // unchanged
}
```

- **Source switcher** binds `$source` + `$switcherExpanded`; selecting a pill runs the *same* body as today's `Picker.onChange`: when `.connected`, guard `canConnect(for:newSource)` and revert if unready, else `connection.switchSource(to:glasses:)`; when disconnected, just set `source` (which lets the gate card appear for glasses).
- **Connect control** switches on `connection.status` exactly like `connectButton` does now (`:292`), only restyled to the 44pt play/stop circle; `.disabled` keys on `pickerDisabled`-equivalent + `!canConnect`.
- **Debug toggle** flips `showDebug` (the existing `@AppStorage`), animated so the video resize is smooth.
- **Message pill** chooses red (error: `.failed`; or `source == .glasses` "Don glasses to connect" guidance) vs green (`copyToast`).

### Glasses gate (re-housed, logic unchanged)

Keep `glassesGateAction` / `showGlassesGate` and the `glassesGate` view's *content* (the register / grant-camera buttons and messages). Move it from the inline `VStack` row into a centered overlay **card** shown when `source == .glasses && showGlassesGate`. The dimmed-but-tappable glasses pill is the entry point: selecting glasses makes it the active source, which surfaces the card; the "Don glasses to connect" case renders as the red guidance pill rather than a card (no action button needed). No change to `GlassesGateway` or the gate truth table.

## File layout (delta)

```code
ios/WazaProto/WazaProto/ContentView.swift            ← body rewrite + new private subviews; gate re-housed
ios/WazaProto/WazaProto/SourceSwitcherPreview.swift  ← DELETED (throwaway design harness)
plans/active/24-full-bleed-streaming-ui.md
plans/index.md
```

No `RoomConnection`/`GlassesGateway`/source-layer/profiler change. No `project.pbxproj`, Info.plist, `viewer/`, or test-file change required (see decisions).

## Key decisions (upfront)

- **View-layer only; reuse every piece of logic.** The connect state machine, `switchSource` live-swap (incl. the revert-on-unready guard), `canConnect(for:)`, the gate *decision* (`gateAction`), coach states, watcher count, copy-link/toast, and debug panels are all reused as-is. Only `ContentView.body` and its private subviews change. This honours the "change as little as possible" bar despite being a visible overhaul.
- **Full-bleed, no border.** The iPhone 17's hardware screen corners frame the feed; a drawn border would just compete with them. Decided against an inset card after an A/B in the harness — the card's margin wastes screen and reads "prototype." Controls inset to safe area; that negative space is the only "frame."
- **Scrims, not frames.** A faint top/bottom gradient keeps white-material controls legible over bright outdoor feeds (verified in-harness against a simulated sunny feed) without any hard border. Invisible over dark scenes.
- **No persistent status bar.** It earned its space only on errors. Errors/gate-guidance/toasts become transient pills; the full status readout + debug panels return only in debug mode (the one mode where a persistent readout is wanted) — matching the user's stated need ("I need to see error messages… otherwise I don't need a bar, unless I'm in debug").
- **Connect = play/stop, same 44pt size as its siblings.** Uniform sizing with the switcher and coach; differentiated by shape (play/stop) and colour (red = live), not by size. Dark play glyph on light material for contrast (white-on-light washed out in the harness).
- **Glasses pill stays selectable when dimmed.** "Not ready" must remain tappable, because selecting glasses is exactly how the user reaches registration / camera-permission. Dimming communicates state; the gate card / guidance pill does the rest. (Live-switching to an unready glasses is still blocked by the existing revert guard.)
- **Subviews stay in `ContentView.swift`.** They're small and view-only; a new file would add `project.pbxproj`-free but navigational overhead for no benefit. The harness, by contrast, is deleted — it was scaffolding.

## Out of scope / inherited behavior

- **Hide-status-bar / immersive chrome.** Whether to hide the iOS status bar (time/battery) over the feed is a later polish call; this slice keeps it.
- **Landscape.** The demo is portrait-only on the iPhone 17; no landscape layout work.
- **Coach button behaviour** (summon/dismiss, busy spinner) is plan-19 territory — reused verbatim, only restyled/repositioned.
- **Source set / publish paths** (Front · Rear · Glasses) are plan-22 territory — unchanged; this slice only changes how the source is *chosen*.
- **Animation tuning on hardware.** Final bloom spring + thumb-reach are judged on-device after wiring.

## Done criteria

1. The video fills the screen edge-to-edge (no white background, no drawn border, no inset margin); the device's screen corners frame it.
2. The **source switcher** (bottom-left) shows the current source's glyph collapsed; tapping blooms the three options upward with the active one anchored at the bottom and ringed; selecting a pill switches source; tapping the anchor or the empty video collapses it.
3. **Live switching** among Front · Rear · Glasses still works without dropping the room (same `switchSource` path); switching to an unready glasses is blocked as today.
4. **Play/stop** (bottom-center) drives connect/disconnect: play (dark glyph, light material) when idle, spinner while connecting/switching, red stop when live; disabled when `!canConnect` / mid-transition.
5. **Coach** (bottom-right) and the **audience cluster** — `N watching` then copy-link in the far corner — appear only while live; copy-link still mints the invite and flashes the "Link copied" pill.
6. The **debug** bug (top-left) toggles `showDebug`; turning it on shrinks the video up and shows `profilerDebug` + `devicesDebug` beneath it (today's panels), animated.
7. **No persistent status bar.** A red pill shows on `.failed` / "Don glasses to connect"; otherwise nothing below the controls (outside debug mode).
8. The **glasses gate** (register / grant-camera) appears as an overlay card when glasses is selected and not ready, with its existing actions working; rear/front show no gate.
9. **Scrims** keep the controls legible over a bright feed.
10. `SourceSwitcherPreview.swift` is deleted; build is clean; existing `WazaProtoTests` still pass; verified on the iPhone 17.

## Decisions logged during implementation

- **Layout that satisfies both full-bleed + safe controls.** `VStack { ZStack { LocalPreview.ignoresSafeArea + scrims + controlsLayer } ; if showDebug { debugPanel } }` with `.background(Color.black.ignoresSafeArea())` and `.preferredColorScheme(.dark)`. The video bleeds (top always; bottom only when debug isn't splitting the screen); `controlsLayer` is a plain `Color.clear` that *respects* the safe area, so every floating control clears the Dynamic Island / home indicator without per-control inset math. `.preferredColorScheme(.dark)` makes the status bar light and fixes the debug panel's text colours in one line.
- **On-device tweaks (after first install on iPhone 17):**
  - **Dropped the active-pill white ring** (criterion 2). It read as clutter on the collapsed switcher; active is still unambiguous (collapsed shows the current source; when expanded it's anchored at the bottom).
  - **Play glyph is white, not the planned dark** (criterion 4). Over the disconnected/black feed `.regularMaterial` renders *dark*, so the black glyph vanished. White reads in every state (the bottom scrim covers the bright-feed case).
  - **Debug toggle is hidden** (criterion 6). No visible bug — a **long-press (0.6s) on the top-left corner** reveals/hides the debug panel (the panel itself is the "it's on" signal). Keeps the chrome clean for demos.
- **Waza logo on the black screen.** New `WazaLogo` imageset, shown whenever `localVideoTrack == nil` (launch + post-Stop), `containerRelativeFrame` at 0.5 width. The opaque app-icon variants can't be dropped raw (Light has white corners; Dark's dark-gradient square shows on pure black). ImageMagick `-level 38%,100%` (per-channel) crushed the achromatic square + shadows to true black while keeping the colour mark — **but also killed the white "flashlight" beam** from the lower-left circle, and a hand-synthesised beam looked bad. Final: **gpt-image-2 edit of `AppIcon-Dark.png`** extracted the mark *with* its flashlight glow onto a pure-black 1024² — the clean win. (Raster, not vector — regenerate if the brand mark ever changes.)
- **App display name → "Waza"** via `CFBundleDisplayName` only; bundle id (`com.vincent.WazaProto`), target, and scheme are untouched (a real rename would churn `project.pbxproj`/scheme for no demo benefit).
- **Viewer coach-audio control** (`viewer/index.html`): the verbose "🔊 Tap to enable coach audio" text became a **round speaker-icon toggle** (`🔇`/`🔊`) in a top-left `#topbar` flex row, left of `#status`. It's now a real on/off **mute toggle** that shows whenever a coach voice track exists (was a one-shot autoplay-unblock prompt). No e2e change (`#status` id preserved).
- **Glasses gate re-housed** as a centered overlay card (reusing `gateAction` + the register/grant actions); the dimmed glasses pill stays *selectable* so registration/permission stays reachable — exactly as the plan called for.

## Vincent's learnings

*(filled in as we go)*

## Tech debt opened

- **Logo is a raster extraction**, not the source vector/mark. If the brand mark changes, re-run the gpt-image extraction rather than hand-editing.
- **Full-bleed safe-area behaviour verified on iPhone 17 portrait only.** No landscape layout; other device classes unverified (demo is single-device).
- **Viewer speaker toggle is now always-visible during coaching** (vs. the old prompt-only). Intentional, but a small behaviour change to note if the coach-audio UX is revisited.
