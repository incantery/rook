package main

import (
	"log"

	"github.com/wailsapp/wails/v3/pkg/application"

	"github.com/incantery/rook/frontend"
	"github.com/incantery/rook/internal/session"
)

func main() {
	app := application.New(application.Options{
		Name:        "rook",
		Description: "An AI-native terminal for the agent age",
		Services: []application.Service{
			application.NewService(&session.Service{}),
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
		Mac: application.MacWindow{
			// Matches the top padding in the frontend: the invisible bar is
			// the drag region, and terminal row 0 starts below the traffic
			// lights.
			InvisibleTitleBarHeight: 34,
			// Translucent (NSVisualEffectView), not Transparent: a fully
			// transparent backdrop discards the native window shape —
			// rounded corners, shadow, the lot. The 0.95 Material Ocean
			// tint is painted full-bleed by the page; the slight vibrancy
			// vs ghostty's plain alpha is invisible at 0.95.
			Backdrop: application.MacBackdropTranslucent,
			TitleBar: application.MacTitleBarHiddenInset,
		},
		BackgroundColour: application.NewRGBA(0, 0, 0, 0),
		URL:              "/",
	})

	err := app.Run()
	if err != nil {
		log.Fatal(err)
	}
}
