// Seth's config as a TypeScript environment — the parity probe, now a
// consumer of the real TS SDK (sdk/ts/rook.ts). Output must stay
// byte-identical to main.go's:
//
//   diff <(go run ./sdk/rook/example) <(node sdk/rook/example/main.ts)

import { env } from "../../ts/rook.ts";

const e = env();

e.fontFamily("Hack Nerd Font Mono");
e.fontSize(18);
e.backgroundOpacity(1);
e.windowPadding(4);
e.theme("Nocturne");

e.leader("`");
e.editorLeader(",");

e.bind('<leader>"', "app.split.horizontal");
e.bind("<leader>v", "app.split.vertical");
e.bind("<leader>c", "tab.new");
e.bind("<leader>m", "workspace.manager");

e.editorBind("normal", "<leader>TAB", "explorer.toggle");
e.editorBind("normal", "<leader>o", "explorer.reveal");

e.host("coder", "claude");
e.host("workspace-allow", ["rook", "rook-cloud", "rook-site", "presentation"]);
e.table("agent", { enabled: true, engine: "auto", model: "", "daily-cap-usd": 1 });
e.table("lsp", { enable: ["go", "typescript", "svelte"] });
e.table("cloud", { url: "https://api.rookide.com" });

e.run();
