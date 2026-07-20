package main

// The explore work-type from the CLI — investigations and their breadcrumb
// trails. The trail prints grep-shaped (path:line: text) because a claude
// session is a first-class reader of it, and `visit` makes it a first-class
// WRITER too: an agent can leave breadcrumbs on the same trail the human's
// editor writes through the opener seam.

import (
	"fmt"
	"strings"
)

type exploreTask struct {
	ID         int64
	ParentID   int64
	State      string
	Title      string
	Path       string
	StartLine  int
	AnchorText string
	Children   []exploreTask
}

// openExplore resolves the newest open investigation in a workspace.
func openExplore(c *client, ws string) (*exploreTask, error) {
	raw, err := c.req("GET", "/workspaces/"+ws+"/tasks?workType=explore", nil)
	if err != nil {
		return nil, err
	}
	var roots []exploreTask
	if err := jsonInto(raw, &roots); err != nil {
		return nil, err
	}
	for i := range roots {
		if roots[i].State == "open" {
			return &roots[i], nil
		}
	}
	return nil, fmt.Errorf("no open investigation in %s — rookctl explore start <question>", ws)
}

func runExplore(args []string) error {
	usage := fmt.Errorf("usage: rookctl explore start <question> | list | trail | visit <path>:<line> | done  [-w workspace]")
	if len(args) == 0 {
		return usage
	}
	verb, args := args[0], args[1:]
	ws, args, err := wsFlag(args)
	if err != nil {
		return err
	}
	c, err := connect()
	if err != nil {
		return err
	}
	switch verb {
	case "start":
		if len(args) == 0 {
			return usage
		}
		raw, err := c.req("POST", "/workspaces/"+ws+"/explore",
			map[string]string{"title": strings.Join(args, " ")})
		if err != nil {
			return err
		}
		var t exploreTask
		if err := jsonInto(raw, &t); err != nil {
			return err
		}
		fmt.Printf("#%d open — %s\n", t.ID, t.Title)
		return nil
	case "list":
		raw, err := c.req("GET", "/workspaces/"+ws+"/tasks?workType=explore", nil)
		if err != nil {
			return err
		}
		var roots []exploreTask
		if err := jsonInto(raw, &roots); err != nil {
			return err
		}
		if len(roots) == 0 {
			fmt.Printf("no investigations in %s\n", ws)
		}
		for _, t := range roots {
			fmt.Printf("#%d %-6s %s (%d breadcrumbs)\n", t.ID, t.State, t.Title, len(t.Children))
		}
		return nil
	case "trail":
		t, err := openExplore(c, ws)
		if err != nil {
			return err
		}
		fmt.Printf("#%d %s\n", t.ID, t.Title)
		for _, b := range t.Children {
			star := " "
			if b.State == "starred" {
				star = "★"
			}
			fmt.Printf("%s %s:%d: %s\n", star, b.Path, b.StartLine, b.AnchorText)
		}
		return nil
	case "visit":
		if len(args) != 1 {
			return usage
		}
		path, line, col, err := parseLoc(args[0])
		if err != nil {
			return err
		}
		t, err := openExplore(c, ws)
		if err != nil {
			return err
		}
		raw, err := c.req("POST", fmt.Sprintf("/tasks/%d/visit", t.ID),
			map[string]any{"path": path, "line": line, "col": col})
		if err != nil {
			return err
		}
		var b exploreTask
		if err := jsonInto(raw, &b); err != nil {
			return err
		}
		fmt.Printf("%s:%d: %s\n", b.Path, b.StartLine, b.AnchorText)
		return nil
	case "done":
		t, err := openExplore(c, ws)
		if err != nil {
			return err
		}
		if _, err := c.req("POST", fmt.Sprintf("/tasks/%d/state", t.ID),
			map[string]string{"state": "done"}); err != nil {
			return err
		}
		fmt.Printf("#%d done — %s\n", t.ID, t.Title)
		return nil
	default:
		return usage
	}
}
