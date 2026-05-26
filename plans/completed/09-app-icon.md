# 09 — App icon

Cross-cutting polish (not a build-ladder rung). Shipped a real iOS app icon for WazaProto so the prototype is recognizable on a phone during demos and no longer uses the default blank asset. v0.09.

## Goal

WazaProto has a distinctive icon on the iPhone home screen, app switcher, Settings, and install prompts. The icon should read at small sizes, feel tied to "live POV streaming," and avoid any Meta/Ray-Ban brand dependency.

## Why this slice

The app is now used on-device enough that the default icon is friction: it is hard to find, looks unfinished during demos, and makes screenshots/TestFlight installs feel rougher than the streaming work deserves. This is a small, self-contained polish pass with low implementation risk.

## Direction

Use a simple abstract mark, not a literal pair of glasses:

- **Primary concept:** a rounded square field with a small off-center camera aperture / lens and a forward signal beam. It implies "first-person video leaves the phone" without copying glasses hardware.
- **Shape language:** one bold symbol, high contrast, no text, no detailed linework.
- **Color:** restrained dark base with one bright live-signal accent. Needs to work in light, dark, and iOS tinted appearances.
- **Avoid:** Meta/Ray-Ban shapes, eyewear silhouettes that look like product branding, tiny "Waza" text, photorealistic glasses, and gradients that disappear when tinted.

## Approach

### 1. Produce two or three quick candidates

Make small candidate icons before committing to assets. Keep them comparable: same canvas, same rounded-square preview, same size check at 60px and 29px.

Candidate directions:

- **Lens + beam:** aperture dot with a single diagonal/forward stream shape.
- **POV frame:** simplified video-crop corner marks around a small live dot.
- **W mark as path:** abstract `W` made from a camera ray / route line, only if it still reads without text.

Pick one by small-size legibility, not full-size cleverness.

Generated first-pass candidates with the `gpt-image` skill on 2026-05-26, chose `path-mark.png`, then removed the candidate directory before commit to avoid carrying rejected binary assets.

Notes:

- **`lens-beam.png`**: strongest "camera streaming" read, but too photorealistic and gradient-heavy for tinted mode. Better as direction only, not a final asset.
- **`pov-frame.png`**: clean and legible, but the crop marks + red dot feel generic and the center stack reads more like a road/cone than POV video.
- **`path-mark.png`**: chosen direction. Simple, brand-safe, no text, no glasses silhouette, and easy to redraw as a small SVG source. Needs simplification before shipping: remove glow/noise, normalize stroke widths, and make the signal/lens relationship more deliberate.

### 2. Generate production assets

Use the existing asset catalog:

```code
ios/WazaProto/WazaProto/Assets.xcassets/AppIcon.appiconset/
  Contents.json
```

It already has universal 1024x1024 slots for light, dark, and tinted appearances, but no filenames. Add 1024px PNGs and wire them into `Contents.json`.

Expected files:

```code
AppIcon-Light.png
AppIcon-Dark.png
AppIcon-Tinted.png
```

Use `path-mark.png` directly for the first production pass. An SVG/vector redraw is optional follow-up work only if small-size, dark-mode, tinted-mode, or editability checks reveal a real problem.

If we do need an SVG later, redraw `path-mark.png` rather than tracing it literally: dark rounded-square field, lower-left lens/live dot, clean white route/ray to an upper-right signal dot, and two or three signal arcs. Keep the mark bold enough to survive 29px Settings-list size and monochrome/tinted rendering.

### 3. Verify in Xcode/simulator

Build the app and verify the icon appears in:

- Home screen at normal size.
- App switcher.
- Settings app list if visible.
- Dark appearance.
- Tinted appearance if the simulator/device supports it.

Also check the asset catalog for warnings about transparency, missing variants, or invalid icon dimensions.

## File layout (delta)

```code
ios/WazaProto/WazaProto/Assets.xcassets/AppIcon.appiconset/
  Contents.json          ← + filenames for light/dark/tinted universal icons
  AppIcon-Light.png      ← new
  AppIcon-Dark.png       ← new
  AppIcon-Tinted.png     ← new
plans/active/09-app-icon.md
plans/features.md
plans/index.md
```

## Key decisions (upfront)

- **No licensed brand references.** The icon should evoke the product experience, not Meta/Ray-Ban hardware.
- **No text or letters printed on the icon.** App icons are too small for words to help, and text makes tinted/dark variants worse.
- **One universal 1024px asset per appearance.** The current Xcode catalog is already set up for modern universal icon assets; don't expand into legacy per-size slots unless Xcode forces it.
- **iOS-only polish for now.** Do not expand this into viewer-site branding work.
- **PNG-first is acceptable for this prototype.** `path-mark.png` is good enough to try as the final icon. SVG/vector source becomes follow-up only if verification shows tinting, small-size, or editability issues.

## Open questions

- Should the app display name remain `WazaProto`, or should the home-screen label eventually become `Waza`? The icon itself should not depend on this.

## Done criteria

1. A chosen icon direction is recorded here with a small rationale.
2. Light, dark, and tinted 1024px icon PNGs exist in `AppIcon.appiconset`.
3. `Contents.json` references all icon files without Xcode asset warnings.
4. The app builds and shows the icon on simulator or device.
5. The icon remains legible at home-screen and Settings-list sizes.

## Decisions logged during implementation

- **`path-mark.png` shipped as the first production icon.** The generated candidate is already 1024x1024, RGB, and opaque. Copy it directly into the light/dark slots; use a grayscale derivative for the tinted slot.
- **SVG deferred.** We originally considered requiring a vector source, but for this prototype the generated PNG is good enough. Revisit only if tinted mode, small-size legibility, or future edits become painful.
- **Asset catalog build passed.** `xcodebuild -quiet -project ios/WazaProto/WazaProto.xcodeproj -scheme WazaProto -destination 'platform=iOS Simulator,name=iPhone 17' build` completed successfully on 2026-05-26. Xcode generated `AppIcon60x60@2x.png` and `AppIcon76x76@2x~ipad.png` in the built app bundle. Existing Swift 6 concurrency warnings in `GlassesSource.swift` remain unrelated.
- **Home-screen verification passed.** Installed the built app on the booted iPhone 17 simulator with `xcrun simctl install booted .../WazaProto.app`; Vincent confirmed the icon appeared correctly on the simulator home screen.

## Vincent's learnings

*(filled in as we go)*

## Tech debt opened

*(filled in as we go)*
