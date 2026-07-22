import {defineConfig} from "vite";
import {svelte} from "@sveltejs/vite-plugin-svelte";
import tailwindcss from "@tailwindcss/vite";
import wails from "@wailsio/runtime/plugins/vite";

// https://vitejs.dev/config/
export default defineConfig({
    // monaco's editor worker (term/monaco.ts) — classic workers can't
    // import ESM
    worker: {format: "es"},
    // beamterm's wasm-bindgen entry locates its .wasm via
    // `new URL(..., import.meta.url)` — esbuild prebundling would break that
    optimizeDeps: {exclude: ["@beamterm/renderer"]},
    server: {
        host: "127.0.0.1",
        port: Number(process.env.WAILS_VITE_PORT) || 9245,
        strictPort: true,
    },
    plugins: [svelte(), tailwindcss(), wails("./bindings")],
});
