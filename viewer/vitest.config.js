import { defineConfig } from 'vitest/config';

export default defineConfig({
    test: {
        // e2e/ holds Playwright specs; Vitest must skip them or it'll choke
        // on `test.describe` from @playwright/test (different test runner).
        exclude: ['node_modules/**', 'e2e/**'],
    },
});
