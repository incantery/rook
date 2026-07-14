import {defineConfig} from "vitest/config";

// Standalone from vite.config so the Wails/Svelte app build stays out of
// the test path — the view-model is pure, node env, no DOM.
export default defineConfig({
    test: {
        environment: "node",
        include: ["src/**/*.spec.ts"],
    },
});
