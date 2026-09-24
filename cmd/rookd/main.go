// rookd keeps rook alive: it supervises the mux server (adopting one
// that already runs — rookd is a nanny, not an owner: the server is
// spawned into its own session and survives rookd restarts) and runs
// the web bridge in-process. One launchd agent, started at login.
package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"net"
	"os"
	"os/exec"
	"strings"
	"syscall"
	"time"

	"github.com/incantery/rook/internal/config"
	"github.com/incantery/rook/internal/mux"
	"github.com/incantery/rook/internal/namer"
	"github.com/incantery/rook/internal/webd"
)

func sockAlive(sock string) bool {
	c, err := net.DialTimeout("unix", sock, 500*time.Millisecond)
	if err != nil {
		return false
	}
	c.Close()
	return true
}

// superviseMux keeps a server answering on sock. A live one is left
// alone; a dead socket gets a fresh server, detached (Setsid) so a
// rookd restart never takes the user's panes with it.
func superviseMux(sock string) {
	backoff := 2 * time.Second
	for {
		if sockAlive(sock) {
			backoff = 2 * time.Second
			time.Sleep(5 * time.Second)
			continue
		}
		log.Printf("mux server not answering on %s; starting one", sock)
		cmd := exec.Command(mux.EnginePath(), "server")
		cmd.Env = mux.Env()
		cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
		started := time.Now()
		if err := cmd.Start(); err != nil {
			log.Printf("cannot start mux server: %v", err)
			time.Sleep(backoff)
			continue
		}
		err := cmd.Wait()
		if time.Since(started) < 2*time.Second {
			// crashed on boot (or lost a start race): back off
			log.Printf("mux server exited immediately (%v); retry in %v", err, backoff)
			time.Sleep(backoff)
			if backoff < 30*time.Second {
				backoff *= 2
			}
			continue
		}
		log.Printf("mux server exited (%v); restarting", err)
	}
}

// nameTabs runs the tab namer against the engine on sock. The config
// is read once: rookd is restarted by launchd, not reloaded. A config
// that does not load names nothing rather than guessing.
func nameTabs(sock string) {
	command := namer.DefaultCommand
	if path, err := config.Path(); err == nil {
		c, err := config.Load(path)
		if err != nil {
			log.Printf("namer: off: %v", err)
			return
		}
		command = c.NamerCommand(namer.DefaultCommand)
	}
	if command == "" {
		log.Printf("namer: off by config")
		return
	}
	n := namer.New(namer.Options{
		Command: command,
		Engine: func(args ...string) (string, error) {
			cmd := exec.Command(mux.EnginePath(), args...)
			cmd.Env = append(os.Environ(), "ROOK_MUX_SOCK="+sock)
			out, err := cmd.Output()
			return string(out), err
		},
		Logf: log.Printf,
	})
	n.Run(context.Background(), 4*time.Second)
}

// watchConfig reloads the engine when rook.toml or a rice it includes
// changes: saved and
// good, the running server takes it (`rook reload`); saved and not, the
// calm bar says why and the config that is running stays. Polled —
// once a second is plenty for a file a person saves, and it survives
// editors that replace the file rather than write it.
func watchConfig(sock string) {
	path, err := config.Path()
	if err != nil {
		return
	}
	// every file the last good load read: rook.toml and its rices
	files := []string{path}
	if c, err := config.Load(path); err == nil {
		files = c.Files
	}
	stamp := func() string {
		var b strings.Builder
		for _, f := range append([]string{path}, files...) {
			if fi, err := os.Stat(f); err == nil {
				fmt.Fprintf(&b, "%d/%d;", fi.ModTime().UnixNano(), fi.Size())
			} else {
				b.WriteString("-;")
			}
		}
		return b.String()
	}
	engine := func(stdin string, args ...string) error {
		cmd := exec.Command(mux.EnginePath(), args...)
		cmd.Env = append(os.Environ(), "ROOK_MUX_SOCK="+sock)
		cmd.Stdin = strings.NewReader(stdin)
		out, err := cmd.CombinedOutput()
		if err != nil {
			return fmt.Errorf("%v: %s", err, strings.TrimSpace(string(out)))
		}
		return nil
	}
	last := stamp()
	for {
		time.Sleep(time.Second)
		now := stamp()
		if now == last {
			continue
		}
		last = now
		c, err := config.Load(path)
		if err != nil {
			log.Printf("config: not reloaded: %v", err)
			// the reason, after the path the person already knows
			why := err.Error()
			if i := strings.Index(why, ": "); i >= 0 && strings.HasPrefix(why, path) {
				why = why[i+2:]
			}
			_ = engine("", "notify", "--mark", "failed", "rook.toml: "+why)
			continue
		}
		files = c.Files
		last = stamp()
		if err := engine(string(c.Compile().JSON()), "reload"); err != nil {
			log.Printf("config: reload failed: %v", err)
			continue
		}
		log.Printf("config: reloaded %s", path)
	}
}

func main() {
	addr := flag.String("addr", "0.0.0.0:7673", "web bridge listen address")
	sock := flag.String("sock", webd.DefaultSock(), "engine unix socket")
	dir := flag.String("dir", "", "static web client dir")
	token := flag.String("token", "", "bearer token (default: persisted beside the socket)")
	flag.Parse()

	go superviseMux(*sock)
	go nameTabs(*sock)
	go watchConfig(*sock)
	log.Fatal(webd.Serve(webd.Options{Addr: *addr, Sock: *sock, Dir: *dir, Token: *token}))
}
