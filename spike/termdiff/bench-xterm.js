// Throughput of the browser emulator: how fast xterm.js parses the same
// firehose. The comparison to bench-vt is the point — if the Go parser is
// materially faster, moving parse off the browser's single JS thread and
// coalescing there is a real win, not a wash.
//
//   node spike/termdiff/bench-xterm.js spike/corpus/nvim-edit.raw
import {readFileSync} from "node:fs";
import {performance} from "node:perf_hooks";
import {basename} from "node:path";
import pkg from "@xterm/headless";
const {Terminal} = pkg;

const rawPath = process.argv[2];
const meta = JSON.parse(readFileSync(rawPath.replace(/\.raw$/, ".meta.json"), "utf8"));
const raw = readFileSync(rawPath);

const target = 40 << 20;
const reps = Math.floor(target / raw.length) + 1;
const big = Buffer.concat(Array(reps).fill(raw));

const term = new Terminal({cols: meta.cols, rows: meta.rows, allowProposedApi: true, scrollback: 2000});

const t0 = performance.now();
await new Promise((resolve) => term.write(big, resolve)); // callback fires when parsed
const dt = performance.now() - t0;
term.dispose();

const mib = big.length / (1 << 20);
console.log(
    `xterm  : ${mib.toFixed(0)} MiB in ${dt.toFixed(1).padStart(6)} ms = ${(mib / (dt / 1000)).toFixed(0).padStart(5)} MiB/s  (${meta.cols}x${meta.rows}, ${reps} reps of ${basename(rawPath)})`,
);
