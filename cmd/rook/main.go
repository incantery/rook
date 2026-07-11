package main

import (
	"log"

	"github.com/wailsapp/wails/v3/pkg/application"

	"github.com/incantery/rook/frontend"
	"github.com/incantery/rook/internal/config"
	"github.com/incantery/rook/internal/session"
)

func main() {
	app := application.New(application.Options{
		Name:        "rook",
		Description: "An AI-native terminal for the agent age",
		Services: []application.Service{
			application.NewService(&session.Service{}),
			application.NewService(&config.Service{}),
		},
		Assets: application.AssetOptions{
			Handler: application.AssetFileServerFS(frontend.Assets),
		},
		Mac: application.MacOptions{
			ApplicationShouldTerminateAfterLastWindowClosed: true,
		},
	})

	app.Window.NewWithOptions(application.WebviewWindowOptions{
		Title:           "rook",
		Width:           1100,
		Height:          700,
		DevToolsEnabled: true,
		// Per the frameless/transparent docs: BackgroundType plus an alpha-0
		// colour make the page's pixels the window's pixels.
		BackgroundType: application.BackgroundTypeTranslucent,
		Mac: application.MacWindow{
			// Matches the top padding in the frontend: the invisible bar is
			// the drag region, and terminal row 0 starts below the traffic
			// lights.
			InvisibleTitleBarHeight: 34,
			// Transparent = clear NSWindow + non-drawing webview: the page's
			// full-bleed rgba(15,17,26,0.95) is what you see — ghostty-style
			// plain alpha. Translucent instead injects an NSVisualEffectView,
			// frosted blur that reads as opaque black in dark mode with no
			// actual see-through. The window is still titled, so macOS keeps
			// the rounded-corner clip and shadow.
			Backdrop: application.MacBackdropTransparent,
			TitleBar: application.MacTitleBarHiddenInset,
		},
		// Alpha here is moot on macOS: MacBackdropTransparent overrides the
		// window colour with clearColor and the webview doesn't draw its
		// background — the page CSS is the only layer that paints.
		BackgroundColour: application.NewRGBA(0, 0, 0, 0),
		URL:              "/",
	})

	err := app.Run()
	if err != nil {
		log.Fatal(err)
	}
}
