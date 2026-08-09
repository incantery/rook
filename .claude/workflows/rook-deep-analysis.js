export const meta = {
  name: 'rook-deep-analysis',
  description: 'Exhaustive architecture/product research of the rook repo into docs/research/rook-deep-analysis/',
  phases: [
    { title: 'Research', detail: '14 parallel deep-dive investigators, notes to scratchpad' },
    { title: 'Write', detail: 'one writer per research document (01-09)' },
    { title: 'Verify', detail: 'contradiction, claim-verification, and status-label audits' },
    { title: 'Fix', detail: 'apply verified corrections to the documents' },
    { title: 'Summarize', detail: 'executive summary written from corrected docs' },
  ],
}

const ROOT = '/Users/sethlowie/go/src/github.com/incantery/rook'
const OUT = ROOT + '/docs/research/rook-deep-analysis'
const NOTES = '/private/tmp/claude-501/-Users-sethlowie-go-src-github-com-incantery-rook/bee82532-672c-429e-a1ac-1a030af53efa/scratchpad/notes'

const STANDARDS = [
  'EVIDENCE STANDARDS (non-negotiable):',
  '- The repository is the source of truth. Do NOT trust README/STATUS/TODO/docs/*.md or code comments as descriptions of behavior — verify against implementation. When repo docs and code disagree, say so explicitly.',
  '- For every important claim, cite a concrete reference: path/file.zig:123 or path/file.zig — TypeName.functionName. Give enough for independent inspection.',
  '- Classify findings with explicit labels: **Implemented:** (and actively used), **Partially implemented:**, **Scaffolded/prototyped:**, **Documented only (not implemented):**, **Obsolete/dead:**, **Unclear:**, **Inference:**.',
  '- Use git history (git log --oneline --follow, git log -p, git log --diff-filter=D, git blame) to understand trajectory, not just HEAD. Distinguish "how it works today" from "where recent commits show it moving".',
  '- Do not create fake precision. If evidence is thin, say what you inspected and what remains unclear.',
  '- Be opinionated but evidence-driven. Name concrete confusions (e.g. "X owns lifecycle while Y owns identity") rather than vague "opportunities to improve".',
  '- Also call out unusually GOOD design when you see it.',
  '- Do NOT modify any production code. You are read-only with respect to the repository.',
].join('\n')

const NOTE_SPEC = 'Your deliverable is an EXHAUSTIVE markdown research-notes file — this feeds a second-stage writer who will NOT re-read most of the code, so capture important details even when they seem mundane: exact types, functions, file paths with line numbers, protocol messages, lifecycle sequences, data structures, buffer/allocation patterns, gotchas, git-history findings. Do not optimize for brevity; thoroughness wins. First run: mkdir -p ' + NOTES + ' — then Write your notes file there. Structure the notes with clear headings, an "Evidence-labeled findings" section, a "Surprises" section, and an "Open questions" section (things the code cannot answer; note what you inspected and what to ask the author).'

const RESEARCH_SCHEMA = {
  type: 'object',
  required: ['topic', 'notesPath', 'summary', 'keyFindings', 'openQuestions', 'surprises'],
  properties: {
    topic: { type: 'string' },
    notesPath: { type: 'string' },
    summary: { type: 'string', description: '1-2 paragraph dense summary of what this subsystem actually is' },
    keyFindings: { type: 'array', items: { type: 'string' }, description: 'most important evidence-backed findings, each with a citation' },
    openQuestions: { type: 'array', items: { type: 'string' } },
    surprises: { type: 'array', items: { type: 'string' }, description: 'genuinely surprising findings, if any' },
  },
}

const TOPICS = [
  {
    key: 'arch-lifecycle',
    title: 'Overall architecture, process lifecycle, build & distribution, platform coupling',
    scope: 'Trace runtime architecture from startup: app/src/main.zig, app/src/macos.zig (445KB — AppKit/window/event-loop/render host: map its major responsibilities), app/build.zig + build.zig.zon (dependencies, vendored packages in app/vendor and app/zig-pkg), Makefile, install.sh, bin/, app/bundle/, .github/ CI. Identify every executable and every process alive at runtime (the app, plugin subprocesses, provider subprocesses, LSP servers, shells, rookctl, the checked-in 8.4MB `cloud` and 13MB `rookctl` binaries at repo root — figure out what those are and whether their source lives in this repo). Threads and event loops: who runs where. Also: what a reader of only README.md would miss; cross-check README/STATUS.md/TODO.md/NEXT.md claims against code. macOS-specific coupling and what a Linux port would require.',
  },
  {
    key: 'terminal-mux',
    title: 'Terminal emulator + multiplexer: PTY, VT, sessions, panes, scrollback, persistence',
    scope: 'Go very deep: app/src/pty.zig (NOTE: has uncommitted working-tree modifications — diff it with git diff and report what the in-flight change does), app/src/session.zig, app/src/panes.zig, app/src/workspaces.zig, app/src/keyenc.zig, app/src/paste.zig, the vendored/pinned terminal library (recent commit 291f6d0 "vt: the pin moves to upstream main, and the fork retires" — identify what VT engine is used, likely ghostty-vt, and how it is pinned/consumed). Trace: PTY creation and ownership, shell spawn/env, read loop, parser, terminal state, resize, scrollback model (host-backed? in-process?), mouse and keyboard paths into the PTY, pane create/destroy, session persistence, detach/reattach, what survives if the UI exits or crashes. Compare architecture honestly to: traditional emulator, tmux, Ghostty, IDE terminal, novel. Identify performance-sensitive paths: allocations, copies, wakeups, batching (gather/micro-batch/high-water marks), serialization under heavy throughput.',
  },
  {
    key: 'render-perf',
    title: 'Rendering stack and performance architecture',
    scope: 'app/src/render.zig, rendering parts of app/src/macos.zig (graphics API — Metal? CoreText shaping? glyph atlas/caching? layer setup, ProMotion handling per commit 27c1fe9), app/src/theme.zig, app/src/ui.zig, app/src/stats.zig, app/src/png.zig. Frame scheduling: what triggers a redraw, invalidation/damage model, vsync/CVDisplayLink or equivalent, keystroke-to-glass path. Terminal render pipeline vs editor render pipeline — same or different. Benchmarks: app/bench.sh, app/PERF.md, docs/PERF.md, docs/render-latency.md, recent bench commits (91e397e on-glass quiet-key row, 7ee6a6b, 337255d, 19f2eef) — verify what the harness actually measures in code, and report the current numbers/claims WITH the caveat of where they come from. Identify anything likely to cause keystroke latency, stalls, memory growth, excessive GPU work.',
  },
  {
    key: 'editor-core',
    title: 'Editor implementation: text model, vim core, buffers, syntax, navigation',
    scope: 'app/src/editor.zig (553KB — map its internal structure: major structs, mode machine, pending-operator model, registers, macros, marks, undo model, visual block), app/src/buffer.zig, app/src/rope.zig (is the rope actually used or is buffer.zig something else?), app/src/docs.zig (one file = one Buffer shared by N panes), app/src/regex.zig, app/src/unicase.zig + unicode strategy, app/src/syntax.zig + grammar.zig + language.zig + app/src/queries/ (tree-sitter? hand-rolled? — recent commit 6d154bd "typing costs a parse of what changed" suggests incremental parsing), app/src/filelist.zig, fuzzy.zig, search.zig, git.zig (gutter), diskscan.zig. Cursor/selection model, large-file handling, persistence of buffers/undo. The vim-oracle test method (real vim as oracle). Assess the primitives honestly: will this scale to a serious daily-driver editor? What is native-Rook concept vs vim-compat layer?',
  },
  {
    key: 'lsp-lang',
    title: 'LSP and language tooling',
    scope: 'app/src/lsp.zig (157KB), app/src/lspmgr.zig, app/src/hoverdoc.zig, app/src/language.zig. How rook speaks LSP natively in Zig: session/server pump, sans-io design, catalog of servers (Go/Python/TS/Zig?), root detection, routing, server installation (commit 22e0540 — typescript installs into rook prefix), diagnostics rendering, gd/K/]d, completion pipeline (recent flurry of completion-menu commits a3bbc72..2634edb — what does the completion UI actually do), shutdown handling (2bc1257). Also determine the relationship between in-app LSP and the Go plugins plugins/lang-typescript, lang-zig, lang-python — are those LSP-related or something else entirely? Overlap/duplication between the two paths is a key question.',
  },
  {
    key: 'plugins-providers',
    title: 'Plugin & provider architecture, SDKs',
    scope: 'HIGHEST PRIORITY AREA. app/src/plugins.zig (75KB), app/src/registry.zig, plugin-facing parts of app/src/ctl.zig. The Go side: sdk/rook (rook.go, cmds.go, example/), sdk/provider (provider.go, serve.go, client.go), sdk/ts, providers/github, providers/linear, providers/boundary_test.go + providers/doc.go, plugins/lang-*, plugins/claude, plugins/agent, plugins/cloud, plugins/internal/{transcript,digestlog,cmdjournal}, examples/, test-config/. docs/plugins/VOCABULARY.md — but verify against code. Determine: discovery, loading, process model (subprocess per plugin? in-proc?), IPC transport and schema, registration, lifecycle, UI extension points (can a plugin render UI? children bullets? panes?), commands, config, state, permissions/capability declarations if any, secrets handling, versioning/compat guarantees, install/update. The architectural distinction (if real in code) between plugin / provider / integration / command / service. Could this support multi-language plugins without becoming IPC-fragile? Name the most consequential unresolved questions.',
  },
  {
    key: 'config-env',
    title: 'Configuration and the environments/IR system',
    scope: 'app/src/config.zig (70KB), app/src/envapply.zig, docs/config.sample.toml, docs/environments/IR.md + VISION.md (verify vs code), test-config/main.go, scripts/gen-cmds.sh, scripts/migrate-workspaces.sh. Trace config from disk to runtime: formats (TOML + environment.json IR?), parsing, defaults, layering (machine/user/workspace), precedence, reload/hot-swap (rook-env swapping compiled Go/TS configs — how does that actually work at runtime), validation, migrations, plugin config, presets (tmux-neovim / vscode persona bundles), the declarative-graph model (preview/drift/apply diffs, provenance) — how much of that is implemented vs documented. Is configuration becoming a declarative environment description or still a preferences file? Cite the seams.',
  },
  {
    key: 'agents-claude',
    title: 'Agent architecture and Claude Code integration',
    scope: 'plugins/agent/ (main.go, watch.go behavior via watch_test.go, summarize.go, draft, persist), plugins/claude/main.go, plugins/internal/transcript, plugins/internal/digestlog, plugins/internal/cmdjournal, app/src/monitor.zig, app/src/procmon.zig. docs/agent/{VISION.md,DESIGN.md}, docs/agent.md, docs/agent-landscape.md, docs/agent/acp-brief.md — treat as aspirational and verify what is real. Determine precisely: how rook knows an agent exists (jsonl transcript watching? process table via procmon? program name?), terminal-based vs API-based agents, waiting/input-state detection, notifications, session resume, digest/journal pipeline (digestlog jsonl seam, headlines to phone), OpenAI summarizer (key at ~/.config/rook/openai_key), concurrent agents, failure/recovery. THE key question: is "agent" a first-class rook abstraction in code, or emergent behavior over terminals/processes? Answer with evidence.',
  },
  {
    key: 'cloud-remote',
    title: 'Cloud, remote, mobile, multi-device',
    scope: 'plugins/cloud/ (main.go, asktext, tests), the 8.4MB `cloud` binary and 13MB `rookctl` binary checked in at repo root (identify: strings/ls -l, are these build artifacts of this repo or of a separate rook-cloud repo? check .gitignore and git log for them), any mailbox/relay/ask code reachable from this repo, app-side surfaces for remote asks (search app/src for ask/mailbox/doorbell/relay/phone). Determine: local vs cloud responsibilities, connection establishment, protocol (the 3-verb host-relay wire?), device identity/auth, reconnect, what data leaves the machine, notification flow to phone, how a phone answer reaches a local Claude Code session. Then answer scenarios A-E concretely from implementation, saying explicitly when something is NOT implemented in this repo: (A) user walks away with phone while Claude Code works; (B) UI crashes with long-running terminal processes; (C) temporary internet loss; (D) two machines same user; (E) remote command during sensitive local state.',
  },
  {
    key: 'ipc-api',
    title: 'IPC, control API, CLI contracts, schemas, wire protocols',
    scope: 'app/src/ctl.zig (67KB — the control surface), the unix socket ($ROOK_SOCK; sun_path 104-byte cap issue), the `rook <verb>` CLI contract (how many verbs, what schema), rookctl (legacy?), scripts/gen-cmds.sh + sdk/rook/cmds.go (generated decls — the codegen seam), sdk/ts parity, plugin wire protocol framing, versioning/compat strategy (fail-open rules, wire v2/v3 history in git), JSON schemas anywhere, protobuf (search for .proto — memory says protobuf was rejected; confirm). For each API surface: producer, consumer, transport, versioning, coupling, stability, extensibility. Flag internal details leaking into APIs that will be hard to change.',
  },
  {
    key: 'testing-quality',
    title: 'Testing strategy, confidence map, code quality & technical debt',
    scope: 'Inventory ALL testing: Zig inline unit tests (count per file: grep -c "^test" app/src/*.zig), app/e2e/ (harness.zig, main.zig 263KB — catalog the scenario list and what harness can assert: dump? screenshots via ImageIO? sandboxed instances), golden tests (Go golden for presets, byte-parity probes for TS/Py SDKs), Go package tests across plugins/providers/sdk, spike/termcap + spike/termdiff (VT conformance/diff-fuzz oracle?), test/ and test-config/, benchmarks as tests, CI in .github/. Map subsystems to confidence: where are regressions caught automatically vs manually. THEN architectural debt hunt (not style): duplicate abstractions, layers without purpose, old implementations beside replacements, god-modules (editor.zig 553KB, macos.zig 445KB — is that debt or deliberate?), state across wrong boundaries, hard-coded assumptions, lifecycle ambiguity, concurrency ownership risks, inconsistent error handling. Rank debt by long-term impact.',
  },
  {
    key: 'history-trajectory',
    title: 'Repository evolution and trajectory from git history',
    scope: 'Use git history aggressively across all ~667 commits (repo starts ~2026-07): reconstruct the eras — Go host + webview/Svelte frontend era, the Zig-native experiment (07-27) becoming the app (07-28), deletion of the JS frontend (07-29), deletion of the Go core (07-31, commit range — find it), vt fork retirement (291f6d0). Use git log --diff-filter=D --summary to find major deletions, git log --oneline --stat groupings, commits-per-directory-per-week to find current hot areas. Identify: major rewrites, abandoned approaches (rook-server deletion 07-25?), renamed concepts, architecture currently being replaced, subsystems under heavy current development (editor completion, bench, lsp per recent log), decisions locked in recently. Deliver a dated timeline plus a "trajectory" section: what the last 2 weeks of commits imply about direction. Distinguish "works this way today" from "moving toward".',
  },
  {
    key: 'security',
    title: 'Security model and trust boundaries (threat-model style)',
    scope: 'Architectural security analysis, not a checklist. Trust boundaries between: rook core, plugins (Go subprocesses), providers, agents (Claude Code etc.), shell processes, workspaces, configuration (compiled Go/TS config programs — config is CODE EXECUTION: assess), cloud relay, remote devices (phone answering asks = remote input injection into local terminals: trace the authorization chain), external APIs (OpenAI summarizer key at ~/.config/rook/openai_key; provider tokens for github/linear). Look at: how plugin/provider processes are spawned (env inheritance, cwd), socket permissions on $ROOK_SOCK (who can connect — any local process?), secret storage/exposure, filesystem scope enforcement (workspace allowlist? none?), network access controls, what a malicious plugin or a malicious workspace config could do, what a compromised cloud relay could do. Separate: (a) vulnerabilities/obviously dangerous, (b) intentional trusted-local behavior, (c) unfinished security architecture, (d) future risk as remote/cloud grows. Do not sensationalize normal local-dev privileges.',
  },
  {
    key: 'repo-map',
    title: 'Complete codebase map (directory-by-directory)',
    scope: 'Sweep the ENTIRE repository and produce a navigation map. For every significant directory and module (app/src file-by-file for the big ones, app/e2e, app/vendor, app/zig-pkg, plugins/*, providers/*, sdk/*, docs/* including man/, examples/, scripts/, spike/, test/, test-config/, bin/, .github/): purpose, important files with LOC, important types/functions (skim each file enough to name its main structs/entry points), dependencies (what it imports), dependents (who uses it), maturity rating (mature/active/experimental/legacy/dead), and 1-3 architectural notes. Also note oddities: checked-in binaries, .DS_Store files, the 92KB PARITY.md, 77KB app/README.md (what is actually in it?), NOTES.md backlog. This becomes 08-codebase-map.md nearly verbatim, so make it genuinely useful for navigation.',
  },
]

phase('Research')
log('Fanning out ' + TOPICS.length + ' research investigators')
const research = await parallel(TOPICS.map(t => () =>
  agent(
    'You are one of ' + TOPICS.length + ' parallel investigators performing a deep, product-and-architecture research pass over the Rook repository at ' + ROOT + ' (a native macOS terminal/multiplexer/editor written in Zig, with Go plugins/providers; the developer is its daily driver; git history is ~667 commits since 2026-07).\n\n' +
    'YOUR TOPIC: ' + t.title + '\n\nSCOPE AND STARTING POINTS:\n' + t.scope + '\n\n' +
    'Follow leads beyond the listed files — the scope is a starting point, not a fence. Investigate your subsystem\'s git history for trajectory.\n\n' +
    STANDARDS + '\n\n' + NOTE_SPEC + '\n\nWrite your notes to: ' + NOTES + '/' + t.key + '.md\nThen return the structured output (notesPath must be that exact path).',
    { label: 'research:' + t.key, phase: 'Research', schema: RESEARCH_SCHEMA }
  )
)) // barrier justified: every writer needs the full set of research notes

const done = research.filter(Boolean)
log('Research complete: ' + done.length + '/' + TOPICS.length + ' investigators returned')
const notesList = done.map(r => '- ' + r.notesPath + ' — ' + r.topic).join('\n')
const allOpenQuestions = done.flatMap(r => (r.openQuestions || []).map(q => '[' + r.topic + '] ' + q)).join('\n')

const WRITER_COMMON =
  'You are writing one document of a multi-document research package about the Rook repository (' + ROOT + '). ' +
  'A prior phase produced exhaustive research notes; read ALL of the notes files relevant to your document (listed below), and skim the others for cross-references:\n' + notesList + '\n\n' +
  'RULES:\n' +
  '- Before asserting any load-bearing claim taken from notes, spot-verify it against the source when it is cheap to do so (open the cited file/line). If you cannot verify a claim, either drop it or label it explicitly.\n' +
  '- ' + STANDARDS.split('\n').slice(1).join('\n- ') + '\n' +
  '- Audience: another AI/researcher doing second-stage analysis WITHOUT repo access. Do not optimize for brevity; capture load-bearing detail. Readable prose over fragments; but use tables/lists where they genuinely fit.\n' +
  '- Never describe planned/documented architecture as implemented. Use the evidence labels.\n' +
  '- Create your file ONLY under ' + OUT + '/ (the Write tool creates parent directories). Do not touch anything else.\n' +
  '- Use mermaid diagrams (```mermaid fences) where a diagram genuinely clarifies — derive them from implementation, not docs.\n'

const DOCS = [
  { file: '01-system-architecture.md', notes: 'arch-lifecycle, terminal-mux, ipc-api, plugins-providers, cloud-remote', spec: 'Detailed system architecture: every executable, process, thread/event loop, long-lived service, subprocess, PTY, IPC mechanism, socket, file watcher, render loop, state store, persistence surface, network connection, plugin process, agent process, and cloud link — traced from application startup onward, with clear ownership ("who owns what"). Include at least: a process/runtime topology mermaid diagram and a startup-sequence description. File paths and symbols liberally.' },
  { file: '02-terminal-renderer-editor.md', notes: 'terminal-mux, render-perf, editor-core, lsp-lang', spec: 'Deep analysis of terminal, multiplexer, renderer, and editor architecture, plus performance. Cover: PTY/shell lifecycle, VT state/parsing, resize, scrollback, input paths, pane/session lifecycle, persistence/detach/crash behavior, similarity verdict (traditional emulator / tmux / Ghostty / IDE terminal / novel); the full render stack (graphics API, shaping, glyph caching, frame scheduling, invalidation, keystroke-to-glass) with performance-threat callouts; editor internals (text representation, cursor/selection, undo, syntax/incremental parsing, vim emulation depth and oracle method, LSP pipeline, completion, large files) and an honest assessment of whether the editor primitives scale to a daily driver. Include current benchmark claims with their provenance.' },
  { file: '03-plugins-providers-security.md', notes: 'plugins-providers, ipc-api, security, config-env', spec: 'Deep analysis of plugin/provider architecture, IPC and API boundaries, SDKs, capabilities/permissions, and the security model. Cover discovery/loading/process-isolation/lifecycle/registration, wire protocol and schemas, SDK surfaces (Go/TS parity, codegen), UI extension points, plugin-vs-provider-vs-command distinctions as implemented, multi-language feasibility, versioning/compat, then a threat-model section with trust boundaries, separating vulnerabilities vs intentional local-trust vs unfinished security architecture vs future risks. Include the config-as-compiled-program security angle. End with the most consequential unresolved plugin-architecture questions.' },
  { file: '04-agents-cloud-remote.md', notes: 'agents-claude, cloud-remote, ipc-api', spec: 'Agent, Claude Code, cloud, remote, mobile, multi-device analysis. How agents are detected/launched/observed; transcript watching; digest/journal pipeline; waiting-state detection; whether "agent" is first-class or emergent (answer definitively with evidence); the cloud/relay/ask architecture, device identity/auth, protocol; then walk scenarios A (phone walk-away), B (UI crash with running processes), C (internet loss), D (two machines), E (remote command during sensitive state) using implementation behavior, explicitly labeling anything not implemented in this repo.' },
  { file: '05-codebase-quality-and-evolution.md', notes: 'testing-quality, history-trajectory, repo-map', spec: 'Testing and confidence map (which subsystems are protected by which kinds of tests; where regressions surface manually), architectural technical debt ranked by long-term impact, subsystem maturity ratings, and the git-history-derived evolution story: dated era timeline, major rewrites/deletions/abandoned approaches, renamed concepts, current hot areas, and what the last two weeks imply about direction. Clearly separate snapshot-state from trajectory.' },
  { file: '06-product-architecture-analysis.md', notes: 'ALL notes', spec: 'Product/architecture synthesis. Evaluate each thesis against the implementation with evidence: (A) terminal-first IDE — is the terminal/mux genuinely foundational; (B) own-everything-end-to-end — what rook actually owns vs depends on, and which dependencies constrain it; (C) extreme extensibility — can substantial workflows land without core changes, what must live in core today, missing plugin primitives; (D) agent-native — what primitives exceed terminal+scripts, what would make it structurally better for agents than VS Code / Ghostty+tmux / Zed / Neovim; (E) bridge to less-technical users — plausibility, exposed Unix complexity, path to simplified UX without a second product; (F) rook as runtime not IDE — evidence it could become an execution/policy layer usable under other editor UIs, what would need to become independent services. Then a competitive architectural comparison (tmux, Ghostty, Neovim, VS Code, Zed, JetBrains) focused on the question "what primitive does rook combine that these do not" — say "none yet" if true. Then a section titled "Emergent architectural capabilities": things likely built without full realization of strategic importance (do not force these; only real ones, with why each could matter).' },
  { file: '07-architectural-forks-and-recommendations.md', notes: 'ALL notes', spec: 'Identify the major architectural decisions not yet locked in that will become expensive to reverse — derived from the repo, not from a template (candidates: plugin isolation, editor text representation, IPC model, cloud/local boundary, session ownership, rendering abstraction, agent model, config-execution model — but only include forks the code actually shows). For each: Decision / Current direction (what the code implies) / Alternatives / Lock-in point (what future work makes it irreversible) / Recommendation with reasoning. Rank by urgency, upside, cost-of-wrong, difficulty-of-later-change. End with a section "The five architectural decisions I would make next" — concrete enough for the author to act on.' },
  { file: '08-codebase-map.md', notes: 'repo-map (primary), all others for cross-checks', spec: 'A practical navigation map of the repository for an engineer or AI entering it: every significant directory/module with purpose, important files, important types/functions, dependencies, dependents, maturity, and architectural notes. Include the oddities (checked-in binaries, large single files, doc files that are really design journals).' },
  { file: '09-open-questions.md', notes: 'ALL notes — every investigator returned open questions; the aggregate list is included below', spec: 'Questions where the code does not provide enough evidence for a confident conclusion. For each: what is unclear, why it matters, what evidence was inspected, and the precise question to ask the author. Deduplicate and group by theme. Do NOT silently fill gaps with assumptions. Aggregate open questions from research:\n' + '' },
]

phase('Write')
log('Writing documents 01-09 in parallel')
const written = await parallel(DOCS.map(d => () =>
  agent(
    WRITER_COMMON + '\nYOUR DOCUMENT: ' + OUT + '/' + d.file + '\nPRIMARY NOTES: ' + d.notes + '\nSPEC:\n' + d.spec +
    (d.file === '09-open-questions.md' ? '\n\nAGGREGATED OPEN QUESTIONS FROM ALL INVESTIGATORS:\n' + allOpenQuestions : '') +
    '\n\nWrite the document now. Return the structured output when done.',
    { label: 'write:' + d.file, phase: 'Write', schema: {
      type: 'object', required: ['docPath', 'status'],
      properties: { docPath: { type: 'string' }, status: { type: 'string' }, weakClaims: { type: 'array', items: { type: 'string' }, description: 'claims you included but could not fully verify' } },
    } }
  )
)) // barrier justified: verification needs the complete document set

phase('Verify')
const VERIFY_SCHEMA = {
  type: 'object', required: ['findings'],
  properties: { findings: { type: 'array', items: {
    type: 'object', required: ['doc', 'issue', 'severity', 'fix'],
    properties: { doc: { type: 'string' }, issue: { type: 'string' }, severity: { type: 'string', enum: ['critical', 'major', 'minor'] }, fix: { type: 'string', description: 'the correct statement / what to change, with evidence citation' } },
  } } },
}
const LENSES = [
  { key: 'contradictions', prompt: 'Read ALL documents in ' + OUT + ' (01 through 09). Hunt for contradictions BETWEEN documents and internal inconsistencies WITHIN documents (e.g. one doc says scrollback is host-backed, another says in-process; conflicting process counts; conflicting maturity verdicts; a "fork" in doc 07 premised on something doc 02 says is already locked in). Where two docs disagree, open the source at ' + ROOT + ' and determine which is right. Report each contradiction with the correct resolution and citation.' },
  { key: 'claim-audit', prompt: 'Read ALL documents in ' + OUT + ' (01 through 09). Select the ~20 most load-bearing factual claims across them (claims that, if wrong, would mislead a second-stage researcher: process model, PTY ownership, IPC protocol, text representation, what is/is not implemented in cloud/agent paths, benchmark provenance). Adversarially verify each against the source at ' + ROOT + ' — try to REFUTE it. Report only claims that are wrong, half-wrong, or unsupported, with the correction and citation. Also verify a random sample of ~15 file:line citations actually point at what the doc says.' },
  { key: 'status-labels', prompt: 'Read ALL documents in ' + OUT + ' (01 through 09). Audit for the single most dangerous failure mode of this research package: PLANNED or DOCUMENTED-ONLY architecture described as if implemented (the repo has extensive aspirational docs in docs/agent/, docs/environments/, docs/plugins/, STATUS.md). For every suspicious "rook does X" statement about agents, cloud, environments-IR, plugins, or capabilities, check the implementation at ' + ROOT + '. Also flag the reverse: implemented behavior wrongly labeled as planned. Report each mislabel with the correct status and citation.' },
]
log('Running 3 adversarial verification lenses')
const verdicts = await parallel(LENSES.map(l => () =>
  agent(l.prompt + '\n\nBe strict but do not manufacture findings — an empty findings list is a valid result. ' + STANDARDS,
    { label: 'verify:' + l.key, phase: 'Verify', schema: VERIFY_SCHEMA, effort: 'high' })
)) // barrier justified: fixer needs all findings merged
const findings = verdicts.filter(Boolean).flatMap(v => v.findings)
log('Verification found ' + findings.length + ' issues')

phase('Fix')
let fixReport = 'no issues found; fix phase skipped'
if (findings.length > 0) {
  fixReport = await agent(
    'You are correcting a research document package in ' + OUT + ' based on verified findings from an adversarial review. For each finding: open the named document, check the finding against the source at ' + ROOT + ' if in doubt, and apply the fix with Edit (correct the claim, fix the label, resolve the contradiction consistently across ALL docs that state it — a fact fixed in one doc must not survive wrong in another). Only edit files under ' + OUT + '. Findings (JSON):\n' + JSON.stringify(findings, null, 2) + '\n\nReturn a short report of what you changed and any findings you rejected as wrong (with reasons).',
    { label: 'fix:apply', phase: 'Fix', effort: 'high' }
  )
}

phase('Summarize')
const execResult = await agent(
  'All detailed research documents (01 through 09) now exist, verified and corrected, in ' + OUT + '. Read ALL of them fully. Then write ' + OUT + '/00-executive-summary.md: a dense but readable overview containing — what Rook actually is today (implementation-based); the architecture in ~1 page; the most important findings; the strongest architectural decisions; the biggest weaknesses; the highest-impact risks; the most important architectural opportunities; and an overall assessment of the project\'s technical trajectory. It must reflect the detailed research (cite which doc covers what, e.g. "see 02-terminal-renderer-editor.md"), never first impressions, and must keep the implemented/planned distinction crisp. Someone reading only this file should understand the conclusions. While reading, if you notice a remaining blatant contradiction between docs, fix the wrong one (verify against source at ' + ROOT + ' first). ' + STANDARDS + '\n\nReturn structured output: a 10-15 sentence digest of the executive summary, plus the 3 most surprising findings across the whole package.',
  { label: 'write:00-executive-summary', phase: 'Summarize', effort: 'high', schema: {
    type: 'object', required: ['digest', 'topSurprises'],
    properties: { digest: { type: 'string' }, topSurprises: { type: 'array', items: { type: 'string' } } },
  } }
)

return {
  docs: written.filter(Boolean).map(w => w.docPath).concat([OUT + '/00-executive-summary.md']),
  researchSummaries: done.map(r => ({ topic: r.topic, summary: r.summary, surprises: r.surprises })),
  verifierFindingsCount: findings.length,
  fixReport: fixReport,
  executive: execResult,
}