#!/bin/sh
# One-time hand-off: print the sqlite workspace registry (rook.db, which
# nothing has written since the Go core left) as ready-to-paste config
# lines, in both SDK languages. Reads through the system sqlite3 so the
# app itself never has to link the library again.
#
#   scripts/migrate-workspaces.sh [path/to/rook.db]
#
# Paste the lines for YOUR config language into your config program,
# apply, and delete the db. Worktree rows are listed as comments only:
# worktrees are derived from git now, not declared.
set -eu

db="${1:-${XDG_DATA_HOME:-$HOME/.local/share}/rook/rook.db}"
[ -f "$db" ] || { echo "migrate-workspaces: no db at $db (nothing to migrate)" >&2; exit 0; }

q() { /usr/bin/sqlite3 -separator '	' "$db" "$1"; }

top=$(q "SELECT name, root FROM workspaces WHERE root != '' AND worktree_of = '' ORDER BY last_used DESC")
wt=$(q "SELECT name, root, worktree_of FROM workspaces WHERE root != '' AND worktree_of != '' ORDER BY last_used DESC")

[ -n "$top" ] || { echo "migrate-workspaces: $db has no workspaces" >&2; exit 0; }

echo "// Go (main.go):"
echo "$top" | while IFS='	' read -r name root; do
    printf 'e.Workspace("%s", "%s")\n' "$name" "$root"
done
echo
echo "// TypeScript (config.ts):"
echo "$top" | while IFS='	' read -r name root; do
    printf 'e.workspace("%s", "%s");\n' "$name" "$root"
done
if [ -n "$wt" ]; then
    echo
    echo "// Worktree rows NOT migrated (rook derives worktrees from git):"
    echo "$wt" | while IFS='	' read -r name root parent; do
        printf '//   %s -> %s (worktree of %s)\n' "$name" "$root" "$parent"
    done
fi
