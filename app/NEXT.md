Rook Zig Editor: Directional Architecture Notes

> **Status, 2026-07-31.** Written mid-experiment, when the Zig app was a
> promising branch beside a shipping webview. It is still what it says it
> is — hypotheses, not decisions — but several have since been settled by
> events rather than by argument:
>
> - The Go host is **gone**, not receding. So is rookctl.
> - Language support is **half** what this describes: LSP servers are
>   spawned from a catalog and that works; tree-sitter grammars were
>   removed outright and want a native (dylib) plugin class rook does not
>   have.
> - Extensions/plugins now have a written vocabulary to aim at —
>   [`../docs/plugins/VOCABULARY.md`](../docs/plugins/VOCABULARY.md) — and
>   a shipped out-of-process protocol in `sdk/provider`.
>
> [`../STATUS.md`](../STATUS.md) is the current picture;
> [`../docs/OWED.md`](../docs/OWED.md) is what was removed and why.

This document collects current thoughts, hypotheses, and possible directions for the Zig rewrite of Rook. It is intentionally not a record of final decisions. The implementation should remain free to validate, reject, or refine these ideas as real constraints emerge.

Context

The Zig experiment has progressed far enough that Rook now has a functioning editor that it fully owns rather than embedding an existing editor component. That creates an opportunity to think about the surrounding architecture as one coherent system:

Editor and terminal rendering

Configuration

Language support and LSP servers

Extensions and plugins

UI composition and animation

Agent and rookctl integration

Rook Cloud coordination

The broad goal is not merely to reproduce VS Code or Zed in Zig. Rook may be able to use the native rewrite to build an editor/workspace optimized around low latency, agent-driven workflows, durable terminal sessions, and interfaces that both humans and agents can understand.

General principles worth exploring

Several principles appear useful as working constraints:

Configuration should primarily be data, not executable code.Ordinary settings, language definitions, keybindings, and extension configuration should be inspectable and deterministic.

Parsing configuration should not imply executing extensions.Rook may register capabilities at startup while starting language servers, extension processes, and other services only when their capabilities are needed.

Rook should own the product-defining UI layer.It can reuse platform, graphics, text, and accessibility infrastructure without allowing a general-purpose widget framework to define Rook's performance or experience ceiling.

Capabilities should have stable semantic identities.Commands, resources, views, settings, languages, language servers, and UI elements should be addressable by humans, rookctl, agents, and extensions.

The implementation should grow vertically through real Rook features.It may be healthier to extract a UI primitive from a real terminal, editor, command palette, or agent panel than to build a generic GUI framework in isolation.

Provenance and explainability are first-class features.Rook should ideally be able to explain where a resolved setting, keybinding, language server, or extension contribution came from.

Configuration format

TOML currently appears to be a strong default for canonical configuration:

Straightforward to read and write

Predictable data model

Suitable for schema validation

Friendly to diffs and dotfile synchronization

Reasonably safe for agents and rookctl to edit

Does not execute arbitrary code while loading

TOML itself does not define imports. Rook would not necessarily need to extend the TOML language to solve that problem. Its configuration loader could discover a deterministic tree of TOML fragments and combine their semantic contents.

One possible structure:

~/.config/rook/
├── rook.toml
├── config.d/
│ ├── editor/
│ │ └── appearance.toml
│ ├── keymaps/
│ │ └── vim.toml
│ ├── languages/
│ │ ├── go.toml
│ │ ├── typescript.toml
│ │ └── zig.toml
│ └── extensions/
│ └── github.toml
└── local.d/
└── work-machine.toml

Workspace configuration could use the same shape:

project/
└── .rook/
├── rook.toml
└── config.d/
└── languages/
└── typescript.toml

File paths versus semantic namespaces

A useful model may be:

The path organizes configuration for the human; the TOML tables determine what the file contributes to Rook.

For example, both of these files could configure the same language:

config.d/languages/typescript.toml
config.d/seth/experiments/new-typescript-server.toml

Rook would inspect their contents rather than assigning behavior based on their filenames. This would provide most of the organizational freedom associated with executable configuration while keeping the configuration itself declarative.

Possible top-level namespaces:

[editor]
[terminal]
[languages.<id>]
[language_servers.<id>]
[formatters.<id>]
[keymaps.<id>]
[extensions.<id>]
[extension_settings.<id>]

The directory names above would be conventions encouraged by documentation and generated by rookctl, not necessarily hard-coded semantic requirements.

Layering

Rook has previously explored Nix-like layered configuration. One possible resolution order is:

Rook defaults

Built-in language and extension contributions

Synced user configuration

Machine-local configuration

Workspace configuration

Nested folder configuration

Temporary session overrides

Possible merge behavior:

Value type

Possible default behavior

Scalar

Most specific layer wins

Table/map

Merge by key

Ordinary array

Replace

Named collection

Merge by stable ID

Removal

Explicit tombstone or unset operation

It may be preferable for duplicate definitions inside the same layer to produce a diagnostic rather than relying on alphabetic filename ordering. Otherwise, configuration can drift toward conventions such as 00-base.toml and 99-final-final.toml.

A provenance command could make this model visible:

rook config explain languages.typescript.language_servers

Possible output:

["tsgo"]

Set by:
~/.config/rook/config.d/languages/typescript.toml:6

Overrode:
builtin:languages/typescript.toml:12
value: ["typescript_language_server"]

Comment-preserving edits

If rookctl, the GUI, and agents are going to update TOML, a normal parse-to-struct-and-reserialize workflow may not be sufficient. Rook may need a lossless concrete syntax tree that retains:

Comments

Whitespace

Table and key ordering

Original quoting

Unknown extension-owned keys

Source spans

rook config set could then perform a localized syntax-tree patch rather than rewriting the entire document.

This parser/editor may become reusable infrastructure, but it does not need to make configuration executable.

Conditional expressions

Some configuration will likely need conditions:

[[keybindings]]
keys = "cmd-k cmd-r"
command = "workspace.open_review"
when = "workspace.has_changes && !terminal.focused"

The when value could use a small, side-effect-free Rook expression grammar. It would be intended for boolean conditions and selectors rather than general-purpose computation.

Potential supported concepts:

Equality and comparison

Boolean operators

Membership

Access to a predefined context object

No filesystem, process, network, or arbitrary function access

This would keep ordinary configuration deterministic while avoiding a separate configuration runtime.

Languages and language servers

Language support may benefit from being modeled as named declarative contributions rather than ordinary executable plugins.

There are at least two distinct concepts:

Language definition

File extensions

Grammar

Comment syntax

Indentation behavior

Language-server preferences

Formatter preferences

Language-server adapter

Executable and arguments

Root markers

Environment

Initialization options

Capabilities or compatibility information

Separating those concepts would allow one server to support multiple languages and allow the implementation for one language to be changed without redefining the language.

Example:

# config.d/languages/typescript.toml

[languages.typescript]
extensions = ["ts", "mts", "cts"]
grammar = "builtin:typescript"
language_servers = ["tsgo"]

[languages.tsx]
extensions = ["tsx"]
grammar = "builtin:tsx"
language_servers = ["tsgo"]

[languages.javascript]
extensions = ["js", "mjs", "cjs"]
grammar = "builtin:javascript"
language_servers = ["tsgo"]

[language_servers.tsgo]
command = ["tsgo", "--lsp", "--stdio"]
root_markers = ["tsconfig.json", "package.json"]

[language_servers.typescript_language_server]
command = ["typescript-language-server", "--stdio"]
root_markers = ["tsconfig.json", "package.json"]

Selecting the alternative implementation could be a small override:

[languages.typescript]
language_servers = ["typescript_language_server"]

Ordered fallback might also be worth exploring:

[languages.typescript]
language_servers = [
"tsgo",
"typescript_language_server",
]

Language packs versus user configuration

A complete language contribution may require assets beyond TOML:

share/rook/languages/go/
├── language.toml
├── grammar.wasm
└── queries/
├── highlights.scm
├── indents.scm
└── injections.scm

This suggests a distinction:

An installed language pack supplies a language definition, grammar, and queries.

User TOML selects and customizes that contribution.

Workspace TOML can override it for a particular repository.

Common language packs could ship with Rook. A third-party pack could potentially be installed through a command such as:

rook language install <package>

For built-in Go support, a user-created config.d/languages/go.toml would normally refine the existing language rather than install an implementation from scratch.

Lazy capability activation

Loading configuration should not require launching every configured program.

For example, Rook could:

Parse the language and server definitions.

Register that gopls can provide LSP capabilities for Go.

Wait until a Go file or workspace becomes relevant.

Start gopls only when an editor operation requests an LSP capability.

The same principle could apply to extensions:

Parse manifests at startup.

Register commands, settings schemas, language contributions, and view types.

Start a process or instantiate Wasm only when a capability is invoked.

Shut down idle services when appropriate.

This may make startup cost primarily proportional to parsing small data files rather than executing an ecosystem of extension hosts.

Explicit startup behavior

Behavior that is intentionally triggered at startup could be represented separately:

[[startup_actions]]
id = "daily-report"
command = "reports.daily"
when = "once_per_day"

This would make a useful conceptual distinction:

Configuration is parsed at startup.

Contributions are registered at startup.

Most code is activated on demand.

Only explicit startup actions perform work because Rook launched.

Scheduled reports may ultimately belong in Rook Cloud or a local automation subsystem rather than the extension loader, but the important property is that the behavior is visible and intentional.

Extensions and plugins

One possible direction is to treat Rook as a protocol-first capability platform rather than recreating the VS Code extension host.

Extensions could contribute typed concepts such as:

Commands

Resources

Views

Events

Settings schemas

Language definitions

Language-server adapters

Formatters

Tasks

Debug adapters

Agent tools

Possible execution forms:

Declarative contribution

Themes

Keymaps

Language metadata

Settings schemas

Commands that delegate to existing Rook capabilities

Sandboxed Wasm

Small, portable in-process behavior

Explicit capability grants

Predictable lifecycle

External protocol service

LSP

DAP

MCP

ACP or similar agent protocols

Purpose-built extension processes over a typed Rook protocol

This direction could avoid a universal Node.js extension runtime and reduce the need for arbitrary extension code to run inside the UI process.

It may also be useful to distinguish the installed package from the user's configuration:

Installed extension:
~/.local/share/rook/extensions/example/rook-extension.toml

User configuration:
~/.config/rook/config.d/extensions/example.toml

The installed manifest describes what the extension can contribute. User configuration enables, disables, selects, or configures those contributions.

UI framework direction

The current Zig GUI ecosystem has useful projects, but none appears to obviously provide the long-term ceiling expected of a highly polished, animated IDE.

Projects worth studying include:

DVUI

Mach

SDL3

Zed's GPUI architecture

Ghostty's platform/core split

DVUI may be a useful reference, prototype environment, or source of implementation ideas. Its current text and accessibility limitations suggest that Rook should be cautious about making it the permanent product boundary.

One hypothesis worth testing is that Rook should own a small, product-specific UI layer from the beginning while reusing low-level infrastructure.

Infrastructure Rook could reuse

SDL3 for initial windows and input

SDL_GPU for Metal, Vulkan, and D3D12 abstraction

CoreText on macOS

HarfBuzz and FreeType where appropriate

Native platform accessibility APIs or AccessKit

Existing image and SVG decoders

Thin AppKit/Swift or other platform shims when necessary

Product-defining behavior Rook may want to own

Element/component model

Layout

Styling and design tokens

Scene representation

Focus and keyboard dispatch

Hit testing

Scrolling and virtualization

Animation

Semantic/accessibility tree

Rook-specific controls

This would not need to become a general-purpose Zig GUI framework. Rook's initial control set could remain small:

Row
Column
Stack
Text
Icon
Surface
Scroll
VirtualList
Split
Tabs
Button
Input
Popover
Modal

The terminal, editor, diff viewer, markdown view, and agent timeline could remain specialized surfaces built on the same scene renderer.

Rendering model

Zed's GPUI work suggests that a text-intensive editor can be built from a relatively small set of GPU primitives:

Rectangles

Rounded corners

Shadows

Glyphs

Icons

Images

Lines and a limited path primitive

Rook could shape and rasterize text using platform or established text libraries, cache glyphs in an atlas, and assemble scenes on the GPU.

One possible initial stack:

Platform
SDL3 initially
Thin native integration where a platform requires it

Rook UI
Keyed element tree
Layout and virtualization
Styling and design tokens
Focus, input, and hit testing
Animation and transitions
Semantic/accessibility tree

Rook Scene
Rectangles
Shadows
Glyphs
Icons
Images
Lines

GPU
SDL_GPU → Metal / Vulkan / D3D12

Text
CoreText on macOS
HarfBuzz + FreeType elsewhere

Hybrid immediate/retained model

The authoring API could feel declarative or immediate:

ui.row(.{ .gap = 8 }, struct {
fn render(ctx: \*Ui) void {
ctx.icon(.terminal);
ctx.label("Agent session");
ctx.spacer();
ctx.button("Attach", attach);
}
}.render);

Internally, Rook could retain keyed nodes:

ui.panel(.{
.id = "agent.activity",
.visible = agent.running,
.transition = .spring,
});

Stable identity could support:

Interruptible animations

Layout transitions

Focus preservation

Scroll preservation

Accessibility

Agent inspection

Deterministic UI testing

Animation

If Rook wants to distinguish itself through polish, animation may need to be foundational rather than added after the UI model is established.

Potential animated properties:

Opacity

Transform

Background and border colors

Shadow

Clip rectangle

Scroll offset

Layout proxy

Potential requirements:

Tween and spring motion

Retargeting without visible jumps

Reduced-motion support

Vsync-based scheduling

120 Hz and ProMotion support

No continuous rendering while idle

Deterministic clocks for tests

A small system of motion design tokens

The ability to drop ornamental frames before delaying terminal or typing updates

Agent-native UI semantics

Owning the UI element tree could support a particularly important Rook capability: the same interface could be understandable to humans, accessibility tools, rookctl, and agents.

An element might carry metadata such as:

.id = "agent.approval.accept",
.role = .button,
.label = "Accept changes",
.command = "agent.approval.accept",

That semantic identity could power:

Accessibility

Agent observation

rookctl automation

Extension UI

Screenshot and interaction tests

Remote UI projections

Extensions could contribute typed Rook UI rather than arbitrary webviews:

Stack
Label
Button
Command
List
Tree
Markdown
Diff
Terminal attachment
Editor resource

Rook would remain responsible for rendering, theme compatibility, animation, keyboard behavior, and accessibility.

Experiments that could validate the direction

The next implementation work could be treated as a set of tests rather than a commitment to the entire architecture.

UI vertical slice

Possible milestone:

SDL3 window using Metal through SDL_GPU

Rectangles, borders, clipping, and shadows

Platform-shaped text and a GPU glyph atlas

Constraint-based row, column, and stack layout

Mouse and keyboard dispatch

One functioning terminal surface

Editor surface

Tabs and splits

Animated command palette or agent panel

Frame-time, idle CPU, and input-to-photon instrumentation

Useful success criteria:

Clean frame pacing at 120 Hz

Essentially zero rendering work while idle

Terminal output does not stall UI animation

Ornamental animation cannot delay typing

Window resize remains smooth

Elements are inspectable through a semantic debug tree

DVUI comparison spike

A small disposable DVUI implementation of the same shell could help identify:

Which layout and event abstractions are worth borrowing

Whether DVUI's architecture can be adapted without friction

Whether Rook's custom renderer and text stack integrate naturally

Whether using DVUI materially accelerates the project

The result could inform the custom UI work without requiring the production code to depend on DVUI.

Configuration prototype

A useful config prototype could demonstrate:

Recursive config.d/\*_/_.toml discovery

Deterministic layer resolution

Duplicate-definition diagnostics

Named language and server objects

Comment-preserving rook config set

rook config explain

Machine and workspace overrides

Lazy LSP startup

One concrete scenario:

Rook ships a built-in TypeScript definition using one server.

User configuration selects tsgo.

A particular repository switches back to typescript-language-server.

rook config explain shows the complete resolution chain.

Neither server starts until a TypeScript capability is requested.

Open questions

These areas still appear worth deliberate experimentation:

Should all TOML fragments under config.d be loaded automatically, or should rook.toml optionally select roots?

How should a user explicitly remove an inherited value when TOML has no null?

Should arrays always replace, or should schemas opt into keyed merging?

Should server fallback be automatic or explicit?

How are language packs discovered, installed, updated, and pinned?

Which extension capabilities are safe for in-process Wasm?

Which capabilities should always live in external processes?

How much native platform code is desirable around the Zig core?

Is SDL_GPU sufficient for the final renderer, or primarily a productive first backend?

Which text APIs provide the right balance of cross-platform consistency and native appearance?

What is the minimum semantic UI model that can serve accessibility, agents, and extensions together?

How should extension-provided UI be constrained without making it feel too limited?

Which animation properties can stay compositor-like and avoid triggering layout?

What performance budgets should become automated regression tests?

Possible near-term posture

A reasonable experimental posture may be:

Continue treating TOML as the likely canonical configuration format.

Explore recursive TOML fragments instead of executable imports.

Model languages, servers, formatters, commands, and extensions as named semantic contributions.

Keep ordinary configuration separate from explicit startup automation.

Activate language servers and extension processes lazily.

Build a small Rook-specific UI layer through real product features.

Reuse SDL3, established text systems, and thin native platform integration.

Include stable semantic IDs and provenance before the system becomes difficult to retrofit.

Measure the implementation continuously rather than assuming Zig or custom rendering automatically produces a better experience.

The central hypothesis is that Rook could gain significant leverage by owning the boundaries that define its identity—editor, terminal, UI semantics, motion, capability model, and agent integration—while borrowing the mature low-level infrastructure that does not differentiate the product.
