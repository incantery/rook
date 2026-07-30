// The preset bundles exist three times — config.zig's applyPreset,
// sdk/rook's Go Preset*, and rook.ts here. Each copy has a guard
// pinning it to the agreed values: the Zig↔bundle e2e (presetparity),
// the Go golden (rook_test.go), and this. Same golden strings as the
// Go test, byte for byte — that IS the cross-SDK parity check.
//
//   node --test sdk/ts/

import { test } from "node:test";
import assert from "node:assert";
import { env } from "./rook.ts";

test("preset goldens match the Go SDK's", () => {
  const tmux = env().presetTmuxNeovim().json();
  const wantTmux =
    `{"rookEnvironment":1,"nodes":[` +
    `{"id":"option:app:top-bar","kind":"option","scope":"app","key":"top-bar","value":[]},` +
    `{"id":"option:app:status-left","kind":"option","scope":"app","key":"status-left","value":["tabs"]},` +
    `{"id":"option:app:status-right","kind":"option","scope":"app","key":"status-right","value":["workspace","branch","cwd"]},` +
    `{"id":"option:app:tab-style","kind":"option","scope":"app","key":"tab-style","value":"index-name"},` +
    `{"id":"option:app:buffer-line","kind":"option","scope":"app","key":"buffer-line","value":false}` +
    `]}\n`;
  assert.strictEqual(tmux, wantTmux);

  const vscode = env().presetVSCode().json();
  const wantVSCode =
    `{"rookEnvironment":1,"nodes":[` +
    `{"id":"option:app:top-bar","kind":"option","scope":"app","key":"top-bar","value":[]},` +
    `{"id":"option:app:status-left","kind":"option","scope":"app","key":"status-left","value":["tabs","branch"]},` +
    `{"id":"option:app:status-right","kind":"option","scope":"app","key":"status-right","value":["cwd","hints"]},` +
    `{"id":"option:app:tab-style","kind":"option","scope":"app","key":"tab-style","value":"current"},` +
    `{"id":"option:app:buffer-line","kind":"option","scope":"app","key":"buffer-line","value":true},` +
    `{"id":"option:app:theme","kind":"option","scope":"app","key":"theme","value":"vscode-dark"},` +
    `{"id":"option:app:editor-mode","kind":"option","scope":"app","key":"editor-mode","value":"insert"},` +
    `{"id":"option:app:activity-bar","kind":"option","scope":"app","key":"activity-bar","value":true}` +
    `]}\n`;
  assert.strictEqual(vscode, wantVSCode);
});

test("a later explicit key overrides its preset's node in place", () => {
  const g = env().presetVSCode().bufferLine(false).json();
  assert.ok(g.includes(`"key":"buffer-line","value":false`));
  assert.ok(!g.includes(`"key":"buffer-line","value":true`));
});
