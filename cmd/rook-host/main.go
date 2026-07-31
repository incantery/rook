// rook-host is the PTY host daemon: it owns shell sessions so the rook UI
// can restart, rebuild, and reload without killing shells. Idempotent — if a
// healthy host of the same build is already running it exits immediately.
package main

import (
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"syscall"
	"time"

	"github.com/incantery/rook/internal/host"
	"github.com/incantery/rook/internal/version"
)

func main() {
	if st, err := host.ReadState(); err == nil && st.Healthy() {
		// Same compatibility rule the app applies (app/src/hostc.zig):
		// build identity, and an unstamped build (go run, make dev)
		// never replaces a stamped daemon — it rides it.
		if st.Build == version.Build || version.Build == "dev" {
			fmt.Printf("rook-host already running (pid %d, port %d, build %s)\n", st.PID, st.Port, st.Build)
			return
		}
		fmt.Printf("replacing rook-host build %s (pid %d) with %s\n", st.Build, st.PID, version.Build)
		syscall.Kill(st.PID, syscall.SIGTERM)
		time.Sleep(300 * time.Millisecond)
	}

	// Before anything execs: a Finder-launched daemon inherits the GUI PATH
	// (no homebrew, no toolchains) — adopt the login shell's entries.
	host.AdoptLoginPATH()

	dir := host.StateDir()
	if err := os.MkdirAll(dir, 0o700); err != nil {
		log.Fatal(err)
	}
	logf, err := os.OpenFile(filepath.Join(dir, "host.log"), os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600)
	if err == nil {
		log.SetOutput(logf)
	}

	h := host.New()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		log.Fatal(err)
	}
	port := ln.Addr().(*net.TCPAddr).Port
	if err := host.WriteState(host.State{
		Port:    port,
		Token:   h.Token(),
		PID:     os.Getpid(),
		Release: version.Version,
		Build:   version.Build,
		BinHash: host.BinHash(),
	}); err != nil {
		log.Fatal(err)
	}

	log.Printf("rook-host %s (build %s) listening on 127.0.0.1:%d (pid %d)", version.Version, version.Build, port, os.Getpid())

	// Die clean on replacement: SIGTERM (hostclient/rook-host upgrading
	// past us) cancels the lifecycle context, which is what anything
	// spawned under it watches.
	//
	// There is nothing spawned under it today — agentmon, rook-agent, the
	// usage prober and the PR watcher all left in the strip, and the beat
	// this used to sleep for was theirs. The context and the signal
	// handler stay because the daemon's whole reason to exist is owning
	// ptys that outlive the app, and that is the seam they hang off.
	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGTERM, os.Interrupt)
	go func() {
		s := <-sig
		log.Printf("rook-host: %v — shutting down", s)
		h.Shutdown()
		os.Exit(0)
	}()

	if err := http.Serve(ln, h.Handler()); err != nil {
		log.Fatal(err)
	}
}
