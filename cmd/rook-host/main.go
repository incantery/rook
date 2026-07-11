// rook-host is the PTY host daemon: it owns shell sessions so the rook UI
// can restart, rebuild, and reload without killing shells. Idempotent — if a
// healthy host is already running it exits immediately.
package main

import (
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"syscall"
	"time"

	"github.com/incantery/rook/internal/host"
)

func main() {
	if st, err := host.ReadState(); err == nil && st.Healthy() {
		if st.Version == host.Version {
			fmt.Printf("rook-host already running (pid %d, port %d)\n", st.PID, st.Port)
			return
		}
		fmt.Printf("replacing outdated rook-host (v%d, pid %d)\n", st.Version, st.PID)
		syscall.Kill(st.PID, syscall.SIGTERM)
		time.Sleep(300 * time.Millisecond)
	}

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
		Version: host.Version,
	}); err != nil {
		log.Fatal(err)
	}

	log.Printf("rook-host listening on 127.0.0.1:%d (pid %d)", port, os.Getpid())
	if err := http.Serve(ln, h.Handler()); err != nil {
		log.Fatal(err)
	}
}
