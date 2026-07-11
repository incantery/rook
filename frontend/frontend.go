// Package frontend embeds the built web assets served to the webview.
// It lives next to dist/ because go:embed cannot reference parent
// directories; dist/ must be built (wails3 task common:build:frontend)
// before the Go build.
package frontend

import "embed"

//go:embed all:dist
var Assets embed.FS
