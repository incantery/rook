import {defineConfig} from "@playwright/test";

// The renderer frame-time gate (D5) runs in isolation: a plain vite dev server
// serving bench/vt-render.html, no app boot and no Go daemon. Kept apart from
// playwright.config.ts (which drives the whole app via e2e/serve.sh) so the
// bench is fast and depends on nothing but the renderer module.

const PORT = Number(process.env.BENCH_PORT) || 9334;

export default defineConfig({
	testDir: "./bench",
	testMatch: /.*\.spec\.ts/,
	workers: 1,
	reporter: "list",
	use: {
		baseURL: `http://127.0.0.1:${PORT}`,
	},
	webServer: {
		command: `pnpm vite --port ${PORT} --strictPort`,
		url: `http://127.0.0.1:${PORT}/bench/vt-render.html`,
		timeout: 60_000,
		reuseExistingServer: !process.env.CI,
		stdout: "ignore",
		stderr: "pipe",
	},
});
