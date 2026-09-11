package main

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"

	"github.com/incantery/grove"
	"github.com/incantery/rook/internal/config"
	"github.com/incantery/rook/internal/mux"
)

const worktreeUsage = "rook worktree [ls [--json] | new <name> [--from <ref>] [--fetch] | open <name> | merge <name> | rm <name> [--force]]"

// runWorktree is `rook worktree <verb>`: git worktrees as rook
// workspaces. The model is grove's (github.com/incantery/grove); what
// is rook's is the place — its own engine, reached the way the rest
// of the front door reaches it, not through PATH. The repo is
// whichever one the current directory is in — a worktree answers with
// its true home, so these work from inside any checkout.
func runWorktree(args []string) error {
	cwd, err := os.Getwd()
	if err != nil {
		return err
	}
	repo, err := grove.Find(cwd)
	if err != nil {
		return err
	}
	repo.Place = enginePlace{}
	if len(args) == 0 {
		// No verb: the manager, which is grove's — standalone here, or
		// in the prefix-w popup, which is the same program at popup
		// size. It finds rook as the place from the pane it runs in.
		bin, err := exec.LookPath("grove")
		if err != nil {
			return fmt.Errorf("the worktree manager is grove, which is not on PATH (brew install --cask incantery/tap/grove)")
		}
		return syscall.Exec(bin, []string{"grove"}, append(os.Environ(), "GROVE_PLACE=rook"))
	}
	verb, rest := args[0], args[1:]
	switch verb {
	case "ls", "list":
		return listWorktrees(repo, has(rest, "--json"))
	case "new", "add":
		name, from := "", ""
		fetch := false
		for i := 0; i < len(rest); i++ {
			switch {
			case rest[i] == "--from" && i+1 < len(rest):
				i++
				from = rest[i]
			case rest[i] == "--fetch":
				fetch = true
			case strings.HasPrefix(rest[i], "-"):
				return fmt.Errorf("worktree new: unknown flag %s", rest[i])
			default:
				name = rest[i]
			}
		}
		if name == "" {
			return fmt.Errorf("usage: rook worktree new <name> [--from <ref>] [--fetch]")
		}
		if fetch {
			if err := repo.Fetch(); err != nil {
				return err
			}
		}
		opts, err := worktreeOptions(repo)
		if err != nil {
			return err
		}
		wt, err := repo.New(name, from, opts)
		if err != nil {
			return err
		}
		if err := repo.Open(wt); err != nil {
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
			wt, err = repo.Main()
		}
		if err != nil {
			return err
		}
		return repo.Open(wt)
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

// enginePlace is rook as a grove.Place: the workspace side of the
// lifecycle, through the engine the front door already resolves.
type enginePlace struct{}

func (enginePlace) Name() string                   { return "rook" }
func (enginePlace) Open(session, dir string) error { return mux.Open(session, dir) }
func (enginePlace) Close(session string) error     { return mux.Close(session) }
func (enginePlace) Live() map[string]bool {
	names, _ := mux.Sessions()
	live := map[string]bool{}
	for _, n := range names {
		live[n] = true
	}
	return live
}

// worktreeOptions is what a fresh checkout needs that git does not
// carry: the [worktree] table of rook.toml (this person's, for every
// repo), merged with grove's own — grove.toml at the repo root and
// ~/.config/grove/grove.toml — so a repo that wrote its conventions
// down for grove has them here too.
func worktreeOptions(repo grove.Repo) (grove.Conventions, error) {
	cfgPath, err := config.Path()
	if err != nil {
		return grove.Conventions{}, err
	}
	cfg, err := config.Load(cfgPath)
	if err != nil {
		return grove.Conventions{}, err
	}
	mine := grove.Conventions{Copy: cfg.Worktree.Copy, Link: cfg.Worktree.Link}
	return mine.Merge(grove.UserConventions()).Merge(grove.LoadConventions(repo.Root)), nil
}

func listWorktrees(repo grove.Repo, asJSON bool) error {
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
