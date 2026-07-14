#!/bin/sh
# rook installer:
#   curl -fsSL https://raw.githubusercontent.com/incantery/rook/main/install.sh | sh
#
# Installs /Applications/rook.app and rookctl from the latest GitHub release.
# curl downloads never set the LaunchServices quarantine attribute, so the
# ad-hoc-signed app launches without Gatekeeper prompts — this script (and
# `rookctl update` after it) is the supported install path, not a browser
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

echo "installing /Applications/rook.app…"
was_running=""
pgrep -qx rook 2>/dev/null && was_running=yes
rm -rf /Applications/rook.app
ditto "$tmp/stage/rook.app" /Applications/rook.app
# Register with LaunchServices — a bare copy is invisible to Spotlight.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/rook.app
mdimport /Applications/rook.app >/dev/null 2>&1 || true

# rookctl → /usr/local/bin if writable, else ~/.local/bin
bindir="/usr/local/bin"
if [ ! -d "$bindir" ] || [ ! -w "$bindir" ]; then
    bindir="$HOME/.local/bin"
    mkdir -p "$bindir"
fi
install -m 0755 "$tmp/stage/rookctl" "$bindir/rookctl"

echo "installed rook $tag"
echo "  rookctl → $bindir/rookctl"
case ":$PATH:" in
    *":$bindir:"*) ;;
    *) echo "  note: $bindir is not on your PATH — add it to use rookctl" ;;
esac
[ -n "$was_running" ] && echo "  rook was running — quit + relaunch to pick up $tag"
echo
echo "next:"
echo "  open -a rook           # launch"
echo "  rookctl install-hooks  # let rook track claude sessions"
echo "  rookctl update         # upgrade to future releases"
