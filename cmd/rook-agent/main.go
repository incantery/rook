// rook-agent is the Rook Agent's process shell (docs/agent.md): supervised
// by rook-host (internal/host/agentproc.go), credentialed via env, and the
// only process in the system that calls an LLM. Missing config/key never
// crash-loops — the agent idles and re-checks, so turning the feature on
// is editing a file, not restarting anything.
package main

import (
	"context"
	"errors"
	"log"
	"os"
	"time"

	"github.com/incantery/rook/internal/agent"
	"github.com/incantery/rook/internal/config"
	"github.com/incantery/rook/internal/version"
)

func main() {
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
		key, err := agent.LoadKey()
		if err != nil {
			log.Printf("no usable API key: %v; checking again in 1m", err)
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
		a := agent.New(host, agent.NewOpenAI(key, cfg.AgentModel), cfg.AgentDailyCapUSD)
		log.Printf("drafting with %s (daily cap $%.2f) against %s", cfg.AgentModel, cfg.AgentDailyCapUSD, host.Endpoint)
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
