#!/bin/sh
# Build the app icon into a bundle's Contents/Resources.
#
#   scripts/build-icon.sh <Contents-dir> [--strict]
#
# THE SOURCE OF TRUTH IS app/bundle/appicon.icon — an Icon Composer
# document: a bare glyph (Assets/rook.png) over a solid fill, with
# icon.json saying `"squares": "shared"`. "Bare glyph" is the point —
# macOS 26 draws the rounded container itself, so the artwork must NOT
# bake one in, and the same document is what gives the icon its Liquid
# Glass treatment.
#
# actool compiles that document into BOTH outputs at once:
#   Assets.car    the modern icon; macOS 26 reads it via CFBundleIconName
#   appicon.icns  a legacy fallback; every macOS reads it via
#                 CFBundleIconFile, and we ship it because
#                 LSMinimumSystemVersion is 13.0 and an Assets.car built
#                 from a .icon renders on 26 only
# That icns tops out at 256px (actool emits 16/16@2x/128/128@2x only), so
# on macOS 13-15 a 512px Finder icon is an upscale. Accepted: the
# alternative is a second, divergent composition of the same logo.
#
# actool needs FULL Xcode, not just the Command Line Tools. Without it we
# fall back to app/bundle/appicon.png — the older, flattened render that
# has its own container baked in — so a from-source build still gets an
# icon. `make release` passes --strict so a release can never quietly
# ship the fallback.
#
# Must run BEFORE codesign: the bundle seal covers Resources, so an icon
# added afterwards invalidates the signature.
set -eu

CONTENTS="${1:?usage: build-icon.sh <Contents-dir> [--strict]}"
STRICT="${2:-}"

root=$(cd "$(dirname "$0")/.." && pwd)
icon_doc="$root/app/bundle/appicon.icon"
icon_png="$root/app/bundle/appicon.png"
res="$CONTENTS/Resources"

mkdir -p "$res"

if command -v actool >/dev/null 2>&1 && [ -d "$icon_doc" ]; then
	# --minimum-deployment-target does not change the output here (13.0
	# and 26.0 produce byte-identical files), but actool requires one.
	plist=$(mktemp -t rook-icon)
	actool "$icon_doc" \
		--compile "$res" \
		--app-icon appicon \
		--output-partial-info-plist "$plist" \
		--platform macosx \
		--minimum-deployment-target 13.0 >/dev/null
	rm -f "$plist"
	[ -f "$res/Assets.car" ] || { echo "build-icon: actool produced no Assets.car" >&2; exit 1; }
	echo "icon: Assets.car + appicon.icns (from appicon.icon)"
	exit 0
fi

if [ "$STRICT" = "--strict" ]; then
	echo "build-icon: actool not found — it ships with Xcode, not the" >&2
	echo "  Command Line Tools. A release must carry the real icon, so" >&2
	echo "  this is fatal here even though 'make install' would degrade." >&2
	exit 1
fi

# Fallback: the flattened 1024 render, resized into a full icns ladder.
# A DIFFERENT composition from the one above (this one bakes in its own
# container), which is why it is the fallback and not the source.
echo "build-icon: actool not found (needs Xcode) — falling back to the" >&2
echo "  flattened appicon.png. The icon will not get the macOS 26" >&2
echo "  treatment. Install Xcode for the real one." >&2

[ -f "$icon_png" ] || { echo "build-icon: no $icon_png either; no icon" >&2; exit 1; }

set=$(mktemp -d -t rook-iconset)/appicon.iconset
mkdir -p "$set"
for spec in 16:icon_16x16 32:icon_16x16@2x 32:icon_32x32 64:icon_32x32@2x \
	128:icon_128x128 256:icon_128x128@2x 256:icon_256x256 512:icon_256x256@2x \
	512:icon_512x512 1024:icon_512x512@2x; do
	px=${spec%%:*}
	name=${spec#*:}
	sips -z "$px" "$px" "$icon_png" --out "$set/$name.png" >/dev/null
done
iconutil -c icns "$set" -o "$res/appicon.icns"
rm -rf "$(dirname "$set")"
echo "icon: appicon.icns only (fallback)"
