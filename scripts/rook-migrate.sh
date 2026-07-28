#!/bin/sh
# rook migrate — retire the webview install and the rookz-era paths.
#
#   scripts/rook-migrate.sh --dry-run       # print what it would do
#   scripts/rook-migrate.sh                 # all three phases
#   scripts/rook-migrate.sh config          # just that phase
#
# Phases are separable because they are not equally reversible: `config`
# is additive and backed up, `binaries` deletes an app you can rebuild,
# and `daemons` takes live shells down with it. Run the last one when
# you are not in the middle of something.
#
# The zig app now IS /Applications/rook.app, so this is not an upgrade
# so much as a cleanup of everything the two-app period left lying
# around: the rookz bundle and its symlinks, a rookctl copy in GOPATH
# that shadows the real one, orphaned daemons, and a second config tree.
#
# WHAT IT NEVER TOUCHES — the state is the product, and all of it is
# already shared with the app that replaced its writer:
#
#   ~/.config/rook/            config (rook-host reads this too)
#   ~/.local/state/rook/       host.json, host.log
#   ~/.local/share/rook/       rook.db (the workspace registry the
#                              palette reads), worktrees
#
# Idempotent: run it twice and the second run reports nothing to do.
set -eu

DRY=0
PHASES=""
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY=1 ;;
        config|binaries|daemons) PHASES="$PHASES $arg" ;;
        *) echo "usage: $0 [--dry-run] [config] [binaries] [daemons]" >&2; exit 2 ;;
    esac
done
[ -n "$PHASES" ] || PHASES="config binaries daemons"
want() { case " $PHASES " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

did_something=0
say() { echo "  $*"; }
act() {
    did_something=1
    if [ "$DRY" -eq 1 ]; then
        echo "  would: $*"
    else
        echo "  + $*"
        "$@"
    fi
}

APP="/Applications/rook.app"
CFG_DIR="$HOME/.config/rook"
CFG="$CFG_DIR/config.toml"
OLD_CFG_DIR="$HOME/.config/rookz"
OLD_CFG_BAK="$CFG_DIR/rookz.bak"

if want config; then
echo "config"
# rookz kept its own config.toml + keybinds.toml. There is one file now,
# and it is the one rook-host already reads — so carry across the two
# settings that only ever existed on the rookz side, then retire the
# tree. Values already present in the target win: it is canonical.
if [ -d "$OLD_CFG_DIR" ]; then
    if [ -f "$CFG" ]; then
        [ "$DRY" -eq 1 ] || cp "$CFG" "$CFG.pre-migrate"
        say "backup: $CFG.pre-migrate"

        merged=$(mktemp)
        awk -v old_cfg="$OLD_CFG_DIR/config.toml" -v old_kb="$OLD_CFG_DIR/keybinds.toml" -v cur="$CFG" '
        function keyof(line,   k) { k = line; sub(/[ \t]*=.*/, "", k); gsub(/^[ \t]+/, "", k); return k }
        BEGIN {
            # Read the rookz files: window settings from config.toml,
            # <leader> chords from keybinds.toml.
            while ((getline line < old_cfg) > 0) {
                if (line ~ /^[ \t]*background-opacity[ \t]*=/) opacity = line
                if (line ~ /^[ \t]*background-blur[ \t]*=/)    blur = line
            }
            # Only the [app] table. rookz keybinds.toml also has an
            # [editor] one, and its chords belong to the editor scope —
            # hoisting them into [keybinds] would silently rebind them
            # app-wide.
            nchord = 0; in_app = 0
            while ((getline line < old_kb) > 0) {
                if (line ~ /^[ \t]*\[/) { in_app = (line ~ /^[ \t]*\[app\]/); continue }
                if (in_app && line ~ /^[ \t]*"<leader>/) chord[nchord++] = line
            }
            # Which chords the target already binds. Only UNCOMMENTED
            # lines count: the shared file documents its defaults as
            # commented examples, and a substring match against those
            # silently dropped a real binding on the first attempt.
            while ((getline line < cur) > 0) {
                if (line ~ /^[ \t]*"<leader>/) have[keyof(line)] = 1
            }
        }
        # Replace an existing background-opacity in place.
        /^[ \t]*background-opacity[ \t]*=/ && opacity != "" {
            print opacity; opacity = ""; seen_opacity = 1; next
        }
        /^[ \t]*background-blur[ \t]*=/ && blur != "" {
            print blur; blur = ""; next
        }
        # First [table] marks the end of the top level: flush anything
        # left before it, or it would land inside someone else s table.
        /^[ \t]*\[/ && !flushed {
            flushed = 1
            if (opacity != "" || blur != "") print "# carried over from ~/.config/rookz"
            if (opacity != "") print opacity
            if (blur != "") print blur
            print ""
        }
        # Add the rookz chords to [keybinds], skipping ones already bound.
        { print }
        /^[ \t]*\[keybinds\][ \t]*$/ {
            for (i = 0; i < nchord; i++)
                if (!have[keyof(chord[i])]) print chord[i] "  # carried over from rookz"
        }
        END {
            if (!flushed) {
                if (opacity != "") print opacity
                if (blur != "") print blur
            }
        }
        ' "$CFG" > "$merged"

        if cmp -s "$CFG" "$merged"; then
            say "nothing to carry across"
            rm -f "$merged"
        else
            did_something=1
            echo "  + merge rookz settings into $CFG"
            diff -u "$CFG" "$merged" | sed 's/^/    /' || true
            if [ "$DRY" -eq 1 ]; then rm -f "$merged"; else mv "$merged" "$CFG"; fi
        fi
    else
        say "no $CFG — nothing to merge into"
    fi
    # MOVED, not deleted. The merge above carries every value the app
    # reads, so nothing is lost in substance — but "my config directory
    # vanished" is an alarming thing to discover, and a merge is exactly
    # the kind of step whose inputs you want to be able to re-read.
    act mv "$OLD_CFG_DIR" "$OLD_CFG_BAK"
else
    say "no $OLD_CFG_DIR — already done"
fi

fi

if want binaries; then
echo "binaries"
[ -d /Applications/rookz.app ] && act rm -rf /Applications/rookz.app || say "no rookz.app"
# A rookctl in GOPATH/bin shadows nothing on its own, but it is a
# DIFFERENT BUILD from the one in the app bundle, and which one wins is
# whatever PATH says. That ambiguity has cost real debugging time.
GOBIN="$(go env GOPATH 2>/dev/null || echo "$HOME/go")/bin"
[ -f "$GOBIN/rookctl" ] && act rm -f "$GOBIN/rookctl" || say "no $GOBIN/rookctl"
# Symlinks left pointing into a bundle that no longer exists.
for link in rookz rook re rookctl; do
    p="$HOME/.local/bin/$link"
    if [ -L "$p" ] && [ ! -e "$p" ]; then
        act rm -f "$p"
    fi
done

fi

if want daemons; then
echo "daemons"
# rook-host used to outlive its app on purpose — the wails app rode a
# healthy daemon rather than restarting it, so shells survived an app
# restart. The zig app owns its ptys and kills the daemon it started, so
# any daemon still standing is either from the old world or from a dev
# or e2e sandbox. Their shells go with them, which is why this phase
# prints everything before it touches anything.
#
# EXCEPT one with a live parent. Killing the daemon the running rook
# owns is not cleanup, it is breaking the app you are sitting in — and
# the first version of this phase did exactly that.
#
# ORPHANHOOD IS THE TEST, and PPID states it exactly: rook forks the
# daemon, so a rook-host whose parent is still alive has an app
# responsible for it. When that app dies the daemon reparents to launchd
# (pid 1) — which is the whole "background work while rook is closed"
# problem, visible as a number. Matching on the binary's path instead
# looked obvious and was wrong twice over: the app and the daemon share
# a path prefix, so `.../MacOS/rook` matches rook-HOST.
pids=$(pgrep -f 'rook-host' 2>/dev/null || true)
if [ -n "$pids" ]; then
    for pid in $pids; do
        say "running: $(ps -o pid=,command= -p "$pid" 2>/dev/null || true)"
    done
    for pid in $pids; do
        ppid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
        if [ -n "$ppid" ] && [ "$ppid" != "1" ]; then
            say "keeping $pid — parent $ppid is alive and owns it"
            continue
        fi
        act kill -TERM "$pid"
    done
else
    say "none running"
fi

fi

echo ""
if [ "$DRY" -eq 1 ]; then
    echo "dry run — nothing changed. Re-run without --dry-run to apply."
elif [ "$did_something" -eq 0 ]; then
    echo "nothing to do."
else
    echo "done. Launch rook; it starts its own rook-host and stops it on quit."
fi
