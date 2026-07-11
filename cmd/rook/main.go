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
			// Transparent, not Translucent: ghostty's background-opacity is
			// plain alpha compositing, no vibrancy blur. The visible
			// background comes from xterm's theme (Material Ocean at 0.95).
			Backdrop: application.MacBackdropTransparent,
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
