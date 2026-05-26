import { defineConfig } from '@playwright/test';

export default defineConfig({
    testDir: './e2e',
    testMatch: '**/*.spec.js',
    // CI is out of scope (plan 08); local-only retries don't help debug runs.
    retries: 0,
    timeout: 30_000,
    reporter: 'list',
    globalSetup: './e2e/global-setup.js',
    globalTeardown: './e2e/global-teardown.js',
    webServer: {
        command: 'node e2e/local-server.js',
        port: 4173,
        reuseExistingServer: false,
        timeout: 10_000,
    },
    use: {
        baseURL: 'http://localhost:4173',
        // Surface autoplay rejections + WebRTC errors in test output instead
        // of silently failing waitForFunction with no signal.
        video: 'off',
        trace: 'retain-on-failure',
    },
    // Playwright's vendored Chromium ships without proprietary codec support;
    // H.264 (what our test publisher uses, what real glasses publish on
    // hardware) is rejected silently — track is signaled but never subscribed.
    // System Chrome has the codecs compiled in.
    projects: [{ name: 'chrome', use: { channel: 'chrome' } }],
});
