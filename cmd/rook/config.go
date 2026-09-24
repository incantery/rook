package main

import (
	"fmt"
	"os"

	"github.com/incantery/rook/internal/config"
	"github.com/incantery/rook/internal/mux"
)

// runConfig is `rook config`: the one parser of rook.toml, for people
// and for the engine.
//
//	rook config check   is the file good? (exit 1 and why, when not)
//	rook config path    where it is
//	rook config json    the engine's half, compiled (what it boots on)
func runConfig(args []string) error {
	sub := "check"
	if len(args) > 0 {
		sub = args[0]
	}
	path, err := config.Path()
	if err != nil {
		return err
	}
	switch sub {
	case "path":
		fmt.Println(path)
		return nil
	case "check", "json":
		c, err := config.Load(path)
		if err != nil {
			return err
		}
		if sub == "json" {
			os.Stdout.Write(append(c.Compile().JSON(), '\n'))
			return nil
		}
		fmt.Printf("%s: ok\n", path)
		return nil
	default:
		return fmt.Errorf("config: check | path | json")
	}
}

// runReload is `rook reload`: compile rook.toml and hand it to the
// running engine. A file that does not load changes nothing.
func runReload() error {
	path, err := config.Path()
	if err != nil {
		return err
	}
	c, err := config.Load(path)
	if err != nil {
		return err
	}
	if err := mux.Reload(c.Compile().JSON()); err != nil {
		return err
	}
	fmt.Println("reloaded", path)
	return nil
}
