package main

import (
	"os"

	"github.com/incantery/rook/internal/mux"
	"github.com/incantery/rook/internal/picker"
)

// runPick is the workspace picker prefix-s floats over the window:
// the workspaces in an fzf list, enter switches, ctrl-o creates the
// name typed. Creating from here is the same verb as `rook new`, cwd
// and all — the popup inherits the focused pane's directory, so a new
// workspace starts where you were standing.
func runPick() error {
	names, err := mux.Sessions()
	if err != nil {
		return err
	}
	choice, err := picker.Run(names)
	if err != nil {
		return err
	}
	switch choice.Action {
	case picker.Switch:
		return mux.Switch(choice.Name)
	case picker.New:
		cwd, _ := os.Getwd()
		return mux.Open(choice.Name, cwd)
	}
	return nil
}
