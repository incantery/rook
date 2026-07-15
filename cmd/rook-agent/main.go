// rook-agent is the Rook Agent's process shell (docs/agent.md): supervised
// by rook-host (internal/host/agentproc.go), credentialed via env, and the
// only process in the system that calls an LLM. Missing config/key never
// crash-loops — the agent idles and re-checks, so turning the feature on
// is editing a file, not restarting anything.
package main

import (
	"context"
	"errors"
	"fmt"
	"log"
	"os"
	"os/exec"
	"strings"
	"time"

	"github.com/incantery/rook/internal/agent"
	"github.com/incantery/rook/internal/config"
	"github.com/incantery/rook/internal/version"
)

// newEngine resolves config to a model backend. "auto" prefers the coder CLI
// the user already has — rook-agent cannot work without claude anyway
// (agentmon reads its transcripts), so shelling out to it costs no new
// dependency and skips the key/keychain/config ritual entirely. An OpenAI key
// stays the alternative for anyone who wants the drafter kept off their
// subscription's rate limit (docs/agent.md: two tiers, two billing models).
// Neither present means idle, not crash — turning the feature on is editing a
// file, never restarting anything.
func newEngine(cfg config.Config) (agent.Engine, error) {
	// Coder may carry arguments; the engine wants the executable.
	bin, _, _ := strings.Cut(strings.TrimSpace(cfg.Coder), " ")
	if bin == "" {
		bin = "claude"
	}
	engine := cfg.AgentEngine
	if engine == "" || engine == "auto" {
		if _, err := exec.LookPath(bin); err == nil {
			engine = "claude"
		} else {
			engine = "openai"
		}
	}
	switch engine {
	case "claude":
		path, err := exec.LookPath(bin)
		if err != nil {
			return nil, fmt.Errorf("agent-engine = claude but %q is not on PATH: %w", bin, err)
		}
		model := cfg.AgentModel
		if model == "" {
			model = "haiku"
		}
		return agent.NewClaudeCode(path, model), nil
	case "openai":
		key, err := agent.LoadKey()
		if err != nil {
			return nil, err
		}
		model := cfg.AgentModel
		if model == "" {
			model = "gpt-5.4-nano"
		}
		return agent.NewOpenAI(key, model), nil
	default:
		return nil, fmt.Errorf("unknown agent-engine %q (want auto, claude, or openai)", engine)
	}
}

func main() {
	// `rook-agent mcp` is the judgment channel, not a daemon: the ClaudeCode
	// engine spawns us as its own MCP server (internal/agent/mcp.go) so the
	// drafter's output contract is a tool call. stdout is the JSON-RPC wire
	// here — nothing else may write to it.
	if len(os.Args) > 1 && os.Args[1] == "mcp" {
		log.SetOutput(os.Stderr) // stdout is the JSON-RPC wire
		pass := ""
		if len(os.Args) > 2 {
			pass = os.Args[2]
		}
		if err := agent.ServeMCP(pass, os.Stdin, os.Stdout); err != nil {
			log.Printf("mcp: %v", err)
			os.Exit(1)
		}
		return
	}

	log.SetFlags(log.LstdFlags | log.Lmsgprefix)
	log.SetPrefix("rook-agent: ")
	log.Printf("%s (build %s)", version.Version, version.Build)

	// Supervised (env-credentialed) agents must not outlive their host:
	// the endpoint/token in env die with the daemon, so retrying them
	// forever just leaks an orphan. Exit instead — respawning with fresh
	// credentials is the supervisor's job (agentproc.go).
	supervised := os.Getenv("ROOK_HOST_ENDPOINT") != ""

	for {
		cfg := config.Load()
		if !cfg.Agent {
			log.Println("agent = off in ~/.config/rook/config; checking again in 1m")
			time.Sleep(time.Minute)
			continue
		}
		eng, err := newEngine(cfg)
		if err != nil {
			log.Printf("no usable engine: %v; checking again in 1m", err)
			time.Sleep(time.Minute)
			continue
		}
		host, err := agent.Connect()
		if err != nil {
			if supervised {
				log.Printf("host: %v; exiting for respawn", err)
				os.Exit(0)
			}
			log.Printf("host: %v; retrying in 15s", err)
			time.Sleep(15 * time.Second)
			continue
		}
		a := agent.New(host, eng, cfg.AgentDailyCapUSD)
		log.Printf("drafting with %s (daily cap $%.2f) against %s", eng.Name(), cfg.AgentDailyCapUSD, host.Endpoint)
		err = a.Run(context.Background())
		if supervised || errors.Is(err, agent.ErrHostGone) {
			// dead or replaced daemon: exit clean, the supervisor (if any)
			// respawns us with fresh credentials
			log.Printf("run ended: %v; exiting for respawn", err)
			os.Exit(0)
		}
		log.Printf("run ended: %v; restarting in 15s", err)
		time.Sleep(15 * time.Second)
	}
}
