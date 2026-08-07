#!/bin/sh
# rook installer:
#   curl -fsSL https://raw.githubusercontent.com/incantery/rook/main/install.sh | sh
#
# Installs /Applications/rook.app from the latest GitHub release.
# curl downloads never set the LaunchServices quarantine attribute, so the
# ad-hoc-signed app launches without Gatekeeper prompts — this script (and
# is the supported install path, not a browser
# download. No sudo.
set -eu

repo="incantery/rook"

fail() { echo "install: $*" >&2; exit 1; }

[ "$(uname -s)" = "Darwin" ] || fail "rook is macOS-only (for now)"
[ "$(uname -m)" = "arm64" ] || fail "no $(uname -m) build published yet — Apple Silicon only (for now)"

# Resolve the latest tag from the release-page redirect: no API, no rate limit.
tag=$(curl -fsSLI -o /dev/null -w '%{url_effective}' "https://github.com/$repo/releases/latest" | sed 's|.*/tag/||')
case "$tag" in
    v*) ;;
    *) fail "could not resolve latest release (got '$tag')" ;;
esac

zip="rook-$tag-darwin-arm64.zip"
base="https://github.com/$repo/releases/download/$tag"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

echo "downloading rook ${tag}…"
curl -fsSL -o "$tmp/$zip" "$base/$zip"
curl -fsSL -o "$tmp/checksums.txt" "$base/checksums.txt"
(cd "$tmp" && grep "  $zip\$" checksums.txt | shasum -a 256 -c - >/dev/null) \
    || fail "checksum mismatch for $zip"

# ditto preserves permissions/xattrs/signature exactly as packaged
ditto -x -k "$tmp/$zip" "$tmp/stage"
[ -d "$tmp/stage/rook.app" ] || fail "release zip did not contain rook.app"
[ -x "$tmp/stage/rook.app/Contents/MacOS/rook" ] \
    || fail "release zip is missing the rook binary"

echo "installing /Applications/rook.app…"
was_running=""
pgrep -qx rook 2>/dev/null && was_running=yes

# Transactional swap: copy the new app beside the target first (same
# filesystem, so the swap below is a pure rename), and only touch the
# existing install once the new one is fully staged and verified. On any
# failure before the swap the old install is untouched; if the swap
# itself fails, the old install is moved back.
new="/Applications/rook.app.new.$$"
old="/Applications/rook.app.old.$$"
trap 'rm -rf "$tmp" "$new"' EXIT
ditto "$tmp/stage/rook.app" "$new"
[ -x "$new/Contents/MacOS/rook" ] || fail "staged copy is missing the rook binary"
if [ -e /Applications/rook.app ]; then
    mv /Applications/rook.app "$old"
fi
if ! mv "$new" /Applications/rook.app; then
    if [ -e "$old" ]; then
        mv "$old" /Applications/rook.app \
            || fail "could not install rook.app; your old install was left at $old"
        fail "could not install rook.app — old install restored"
    fi
    fail "could not install rook.app"
fi
rm -rf "$old"
# Register with LaunchServices — a bare copy is invisible to Spotlight.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/rook.app
mdimport /Applications/rook.app >/dev/null 2>&1 || true

# the CLI names → /usr/local/bin if writable, else ~/.local/bin
bindir="/usr/local/bin"
if [ ! -d "$bindir" ] || [ ! -w "$bindir" ]; then
    bindir="$HOME/.local/bin"
    mkdir -p "$bindir"
fi
# `rook` is the app AND the CLI — one binary, no second process behind
# it. `re` is `rook edit` by argv[0].
ln -sf /Applications/rook.app/Contents/MacOS/rook "$bindir/rook"
ln -sf /Applications/rook.app/Contents/MacOS/rook "$bindir/re"

# rookctl was a real copy here until the Go core left. A stale one on
# PATH talks to a daemon that no longer ships, so remove ours rather
# than leave it to fail confusingly.
[ -f "$bindir/rookctl" ] && rm -f "$bindir/rookctl"

# Man pages ship inside the bundle. macOS man(1) derives its search path
# from PATH (<bindir>/../share/man), so mirror wherever the CLI went;
# fall back to ~/.local/share/man if that spot is not writable. Guarded:
# releases older than the pages simply have no man/ to copy.
srcman="/Applications/rook.app/Contents/Resources/man"
haveman=""
if [ -d "$srcman" ]; then
    mandir="${bindir%/bin}/share/man"
    if ! mkdir -p "$mandir" 2>/dev/null || [ ! -w "$mandir" ]; then
        mandir="$HOME/.local/share/man"
        mkdir -p "$mandir"
    fi
    for s in 1 5 7; do
        [ -d "$srcman/man$s" ] || continue
        mkdir -p "$mandir/man$s"
        cp "$srcman/man$s/"* "$mandir/man$s/"
    done
    haveman=yes
fi

echo "installed rook $tag"
echo "  rook    → $bindir/rook (the app, and the CLI)"
echo "  re      → $bindir/re (the editor: re file)"
[ -n "$haveman" ] && echo "  man     → man rook (also re, rook-config, rook-ctl, rook-plugin)"
case ":$PATH:" in
    *":$bindir:"*) ;;
    *) echo "  note: $bindir is not on your PATH — add it to use rook" ;;
esac
[ -n "$was_running" ] && echo "  rook was running — quit + relaunch to pick up $tag"
echo
echo "next:"
echo "  open -a rook           # launch"
echo
echo "note: in-app self-update left with the Go core — re-run this"
echo "      installer to upgrade until it lands again in Zig."
