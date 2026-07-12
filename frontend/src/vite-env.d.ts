/// <reference types="vite/client" />

// monaco's edcore entry (core + editor features, no language services)
// ships no .d.ts — term/monaco.ts casts it to the package types, which
// describe exactly the surface it re-exports
declare module "monaco-editor/esm/vs/editor/edcore.main";
