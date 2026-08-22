package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/incantery/rook/internal/config"
	"github.com/incantery/rook/internal/worktree"
)

const worktreeUsage = "rook worktree ls [--json] | new <name> [--from <ref>] | merge <name> | rm <name> [--force]"

// runWorktree is `rook worktree <verb>`: git worktrees as rook sessions.
// The repo is whichever one the current directory is in — a worktree
// answers with its true home, so these work from inside any checkout.
func runWorktree(args []string) error {
	if len(args) == 0 {
		return fmt.Errorf("usage: %s", worktreeUsage)
	}
	cwd, err := os.Getwd()
	if err != nil {
		return err
	}
	repo, err := worktree.Find(cwd)
	if err != nil {
		return err
	}
	verb, rest := args[0], args[1:]
	switch verb {
	case "ls", "list":
		return listWorktrees(repo, has(rest, "--json"))
	case "new", "add":
		name, from := "", ""
		for i := 0; i < len(rest); i++ {
			switch {
			case rest[i] == "--from" && i+1 < len(rest):
				i++
				from = rest[i]
			case strings.HasPrefix(rest[i], "-"):
				return fmt.Errorf("worktree new: unknown flag %s", rest[i])
			default:
				name = rest[i]
			}
		}
		if name == "" {
			return fmt.Errorf("usage: rook worktree new <name> [--from <ref>]")
		}
		cfgPath, err := config.Path()
		if err != nil {
			return err
		}
		cfg, err := config.Load(cfgPath)
		if err != nil {
			return err
		}
		wt, err := repo.New(name, from, worktree.Options{Copy: cfg.Worktree.Copy, Link: cfg.Worktree.Link})
		if err != nil {
			return err
		}
		if err := worktree.Open(wt); err != nil {
			return err
		}
		fmt.Println(wt.Path)
		return nil
	case "open", "go":
		if len(rest) != 1 {
			return fmt.Errorf("usage: rook worktree open <name>")
		}
		wt, err := repo.Get(rest[0])
		if rest[0] == repo.Name {
			wt, err = repo.MainWorktree()
		}
		if err != nil {
			return err
		}
		return worktree.Open(wt)
	case "merge":
		if len(rest) != 1 {
			return fmt.Errorf("usage: rook worktree merge <name>")
		}
		if err := repo.Merge(rest[0]); err != nil {
			return err
		}
		fmt.Printf("merged %s into %s; worktree, session and branch removed\n", rest[0], repo.DefaultBranch())
		return nil
	case "rm", "remove":
		force := has(rest, "--force") || has(rest, "-f")
		name := ""
		for _, a := range rest {
			if !strings.HasPrefix(a, "-") {
				name = a
			}
		}
		if name == "" {
			return fmt.Errorf("usage: rook worktree rm <name> [--force]")
		}
		wt, err := repo.Get(name)
		if err != nil {
			return err
		}
		return repo.Remove(wt, force)
	default:
		return fmt.Errorf("unknown worktree command %q (%s)", verb, worktreeUsage)
	}
}

func listWorktrees(repo worktree.Repo, asJSON bool) error {
	wts, err := repo.List()
	if err != nil {
		return err
	}
	if asJSON {
		enc := json.NewEncoder(os.Stdout)
		for _, wt := range wts {
			if err := enc.Encode(wt); err != nil {
				return err
			}
		}
		return nil
	}
	for _, wt := range wts {
		name := wt.Name
		if wt.Main {
			name = repo.Name
		} else if name == "" {
			// off-convention (made by hand): the dir name is all we have
			name = filepath.Base(wt.Path)
		}
		mark := "○"
		if wt.Live {
			mark = "●"
		}
		branch := wt.Branch
		if branch == "" {
			branch = "(detached " + wt.Head + ")"
		}
		var notes []string
		if wt.Dirty {
			notes = append(notes, "dirty")
		}
		if wt.Ahead > 0 {
			notes = append(notes, fmt.Sprintf("+%d", wt.Ahead))
		}
		if wt.Behind > 0 {
			notes = append(notes, fmt.Sprintf("-%d", wt.Behind))
		}
		fmt.Printf("%s %-24s ⎇ %-28s %s\n", mark, name, branch, strings.Join(notes, " "))
	}
	return nil
}

func has(args []string, flag string) bool {
	for _, a := range args {
		if a == flag {
			return true
		}
	}
	return false
}
