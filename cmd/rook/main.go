package main

import (
	"log"

	"github.com/wailsapp/wails/v3/pkg/application"

	"github.com/incantery/rook/frontend"
	"github.com/incantery/rook/internal/config"
	"github.com/incantery/rook/internal/hostclient"
	"github.com/incantery/rook/internal/notify"
)

func main() {
	app := application.New(application.Options{
		Name:        "rook",
		Description: "An AI-native terminal for the agent age",
		Services: []application.Service{
			application.NewService(&hostclient.Service{}),
			application.NewService(&config.Service{}),
			// notifications for the attention router — the frontend calls
			// this by FQN (no generated bindings needed for one method)
			application.NewService(&notify.Service{}),
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
			// Matches the titlebar height in the frontend; tabs and buttons
			// inside it opt out via --wails-draggable: no-drag.
			InvisibleTitleBarHeight: 44,
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
