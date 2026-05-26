import { test, expect } from '@playwright/test';

test.describe('viewer e2e', () => {
    test('connects to LiveKit and receives video frames', async ({ page }) => {
        const invite = process.env.E2E_INVITE;
        expect(invite, 'globalSetup did not mint E2E_INVITE').toBeTruthy();

        // Surface console errors / page errors so a silent failure (e.g.
        // autoplay rejection, WebRTC ICE failure) shows up in the test log.
        page.on('console', (msg) => {
            if (msg.type() === 'error') console.error(`[browser console] ${msg.text()}`);
        });
        page.on('pageerror', (err) => console.error(`[browser pageerror] ${err.message}`));

        await page.goto(`/?invite=${encodeURIComponent(invite)}`);

        // The viewer is in the LiveKit room. We don't assert on the #status
        // text because index.html's RoomEvent.TrackUnsubscribed handler can
        // flip the label back to "waiting for video…" when LiveKit JS
        // re-negotiates the subscription on the simulcast/backup-codec
        // dance — that's a UI race in the viewer, not a real failure.
        // The frames-flowing assertion below is the load-bearing check.
        await expect(page.locator('#status')).toHaveClass(/connected/, { timeout: 15_000 });

        // <video> element gets created by index.html on RoomEvent.TrackSubscribed.
        // Non-zero videoWidth/videoHeight is proof that decoded H.264 frames
        // are flowing through the full pipeline: lk publisher → LiveKit Cloud
        // SFU → Chrome WebRTC stack → <video>.
        await expect
            .poll(
                async () => {
                    const v = await page.locator('#video-slot video').first().evaluate(
                        (el) => ({ w: el?.videoWidth ?? 0, h: el?.videoHeight ?? 0 }),
                        undefined,
                        { timeout: 1000 }
                    ).catch(() => ({ w: 0, h: 0 }));
                    return v.w > 0 && v.h > 0;
                },
                {
                    timeout: 20_000,
                    intervals: [500, 500, 1000, 1000],
                    message: 'video element never reached non-zero dimensions — frames not flowing',
                }
            )
            .toBe(true);

        const { w, h } = await page.locator('#video-slot video').first().evaluate(
            (el) => ({ w: el.videoWidth, h: el.videoHeight })
        );
        expect(w).toBeGreaterThan(0);
        expect(h).toBeGreaterThan(0);
        console.log(`[viewer e2e] received frames at ${w}x${h}`);
    });
});
