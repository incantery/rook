// rookd keeps rook alive: it supervises the mux server (adopting one
// that already runs — rookd is a nanny, not an owner: the server is
// spawned into its own session and survives rookd restarts) and runs
// the web bridge in-process. One launchd agent, started at login.
package main

import (
	"context"
	"flag"
	"log"
	"net"
	"os"
	"os/exec"
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

func main() {
	addr := flag.String("addr", "0.0.0.0:7673", "web bridge listen address")
	sock := flag.String("sock", webd.DefaultSock(), "engine unix socket")
	dir := flag.String("dir", "", "static web client dir")
	token := flag.String("token", "", "bearer token (default: persisted beside the socket)")
	flag.Parse()

	go superviseMux(*sock)
	go nameTabs(*sock)
	log.Fatal(webd.Serve(webd.Options{Addr: *addr, Sock: *sock, Dir: *dir, Token: *token}))
}
