# 14 — Viewer fixed aspect box

Cross-cutting polish. The browser `<video>` element today sizes itself from the incoming stream's native frame dimensions, so when DAT's adaptive ladder promotes 504×896 → 720×1280 or demotes the other way mid-stream the element jumps and the surrounding layout reflows. Lock the box to a fixed 9:16 aspect at 504×896 native size so the layout is stable regardless of what DAT delivers.

## Goal

The viewer `<video>` element occupies a fixed 9:16 slot. On desktop the box is 504 px wide so DAT's native 504×896 frames hit the pixel grid 1:1 (no scaling); when DAT promotes to 720×1280 (also 9:16) the browser does a clean downscale — the easy direction. On phones the box shrinks to viewport width and height. No reflow when DAT switches rungs, no flash before the first frame arrives.

## Why this slice

Plan 12 closed the streaming-smoothness loop (smoothing buffer, depth=2 winner). The remaining viewer-side complaints are about *visual* quality, not motion: (a) the element jumps size when DAT changes resolution, (b) the picture looks grainy at 504×896. This plan addresses (a) only — pure CSS, no pipeline change, no added latency. (b) is a separate question once the layout is stable; the leading hypothesis is the LiveKit encoder's 0.78 Mbps bitrate being tight for natural-scene video, tracked separately.

The reason 504×896 is the right native target rather than 720×1280: in the matched-regime data from plan 12 (`features/glasses-stream-buffer-sweep.md`), DAT spent the entire run at 504×896. The 720×1280 promotion only ever surfaced once during a contaminated sweep and isn't the typical state. Sizing the box to 720 would mean upscaling almost all real frames; sizing to 504 means downscaling on the rare promotion and 1:1 the rest of the time.

## Direction

CSS-only change inside `viewer/index.html`. No JS changes — `livekit-client` attaches its `<video>` element into `#video-slot` already, and the styling cascades to it.

1. **Lock the `#video-slot video` to `aspect-ratio: 9/16`.** Reserves the slot before the first frame paints — no flash, no reflow on first attach either.
2. **Fixed `width: 504px` on desktop**, the native DAT resolution width. Pixel-perfect at the common case.
3. **`max-width: 100vw` / `max-height: 100dvh`** so phones and short windows shrink the box instead of overflowing.
4. **Keep `background: #000`** so the slot reads as "video pane" before the first frame.

## Approach

The change lives entirely in the `<style>` block of `viewer/index.html` (currently lines 6–22).

Today:

```css
#video-slot video { max-width: 100%; max-height: 100%; background: #000; }
```

After:

```css
#video-slot video {
  aspect-ratio: 9 / 16;
  width: 504px;          /* desktop: pixel-perfect to native DAT frame */
  max-width: 100vw;      /* phone: shrink to viewport width */
  max-height: 100dvh;    /* short windows: don't overflow vertically */
  height: auto;
  background: #000;
  object-fit: contain;   /* both DAT rungs are 9:16, this is just a safety net */
}
```

That's the whole change.

## File layout (delta)

```code
viewer/index.html                            ← #video-slot video rule only
plans/active/14-viewer-fixed-aspect-box.md
plans/index.md
```

## Key decisions (upfront)

- **Box sized to 504×896 native, not 720×1280.** Per plan 12 / `features/glasses-stream-buffer-sweep.md`, DAT effectively lives at 504×896; the promotion is rare and brief. Sizing to the common case keeps the typical render 1:1 with no scaling at all.
- **CSS-only.** No JS to read `videoWidth`/`videoHeight` and resize on the fly — `aspect-ratio` + fixed width is enough, and avoids a layout flicker on every resolution swap.
- **`aspect-ratio: 9/16`, not `504/896`.** Same ratio, more legible. Both DAT rungs (504×896 and 720×1280) are 9:16.
- **`object-fit: contain` over `cover`.** Both DAT rungs are 9:16 so neither would actually crop or letterbox today, but `contain` is the safer default if a future rung changes aspect.
- **No `min-width` / `min-height`.** On phones narrower than 504 px the `max-width: 100vw` clamp wins and the box scales down — that's the desired phone behavior, not a defect.

## Done criteria

1. With the viewer open in a desktop browser, the video slot is 504 px wide and 896 px tall (within 1px) regardless of incoming stream resolution.
2. Triggering a DAT promotion 504×896 → 720×1280 (or demotion back) mid-stream causes **no visible jump** in the video element's box on the page — surrounding layout is stable.
3. Opening the same page on a phone narrower than 504 CSS px shows the box filling the viewport width, with height auto-derived from the 9:16 aspect.
4. Before the first frame arrives, the slot is already laid out at the right size (black `#000` rectangle, not a 0×0 collapsed element).
5. The grain/sharpness question is explicitly out of scope here — tracked as a separate follow-up.

## Decisions logged during implementation

- **`vercel dev` local setup needed `.env` (not `.env.local`).** The viewer's API endpoints (`/api/viewer-token`, `/api/publisher-token`) read four secrets from env: `LIVEKIT_URL`, `LIVEKIT_API_KEY`, `LIVEKIT_API_SECRET`, `INVITE_SIGNING_SECRET` (plus `PUBLISHER_SIGNING_SECRET`). `vercel env pull` returned them all as empty strings because they're stored as Sensitive in the Vercel project (write-only — name pulls, value doesn't). Copying the root `.env` into `viewer/.env.local` *should* work per Vercel CLI docs but didn't on the installed CLI version; `cp` to `viewer/.env` did. Permanent fix: `ln -sf .env .env.local` inside `viewer/` so both names point at one file. Also added `.env*` to `viewer/.gitignore` to prevent the local copy from leaking into commits.

## Vincent's learnings

*(filled in as we go)*

## Vincent's learnings

*(filled in as we go)*

## Tech debt opened

*(filled in as we go)*
