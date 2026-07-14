import {defineConfig} from "@playwright/test";

// End-to-end tests drive the real app over HTTP (e2e/serve.sh explains how).
// These are the slow, high-fidelity tier: vitest still owns the pure
// view-model units in src/**/*.spec.ts, and nothing here duplicates those.
// Note e2e/ is outside tsconfig's include, so specs are transpiled but not
// type-checked — svelte-check has no node types, and this keeps it that way.

const PORT = Number(process.env.E2E_PORT) || 9333;

export default defineConfig({
    testDir: "./e2e",
    // One app, one host daemon, one sandbox: parallel workers would race for
    // the same session state rather than scale.
    workers: 1,
    fullyParallel: false,
    forbidOnly: !!process.env.CI,
    reporter: process.env.CI ? "github" : "list",
    use: {
        baseURL: `http://127.0.0.1:${PORT}`,
        // roughly the window cmd/rook opens (1100x700), with room for splits
        viewport: {width: 1400, height: 900},
        screenshot: "only-on-failure",
        trace: "retain-on-failure",
    },
    webServer: {
        command: "./e2e/serve.sh",
        url: `http://127.0.0.1:${PORT}/`,
        // a cold start builds the bundle + two Go binaries
        timeout: 180_000,
        // iterate against an already-running sandbox instead of rebuilding
        reuseExistingServer: !process.env.CI,
        stdout: "pipe",
        stderr: "pipe",
    },
});
