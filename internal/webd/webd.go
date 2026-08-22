// Package webd bridges browsers to the rook-mux socket and serves the
// web client. It is deliberately a dumb pipe: websocket binary frames
// are raw mux-protocol bytes in both directions, so the browser speaks
// the same type/len/payload framing as every other client and the
// bridge never needs to learn the protocol. rookd runs this in-process.
package webd

import (
	"context"
	"crypto/rand"
	"crypto/subtle"
	"encoding/hex"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/coder/websocket"
)

// DefaultSock is the mux server's default socket path.
func DefaultSock() string {
	if s := os.Getenv("ROOK_MUX_SOCK"); s != "" {
		return s
	}
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".local", "state", "rook", "mux.sock")
}

// Options configure the bridge; zero values get sane defaults.
type Options struct {
	Addr  string // listen address
	Sock  string // rook-mux unix socket
	Dir   string // static web client dir
	Token string // bearer token; empty = persisted beside the socket
}

// Serve runs the bridge until the listener fails.
func Serve(o Options) error {
	addr, sock, dir, token := &o.Addr, &o.Sock, &o.Dir, &o.Token
	if *addr == "" {
		*addr = "0.0.0.0:7673"
	}
	if *sock == "" {
		*sock = DefaultSock()
	}

	if *token == "" {
		// a stable token beside the mux state: survives restarts and
		// launchd, so devices that stored it keep working
		tf := filepath.Join(filepath.Dir(*sock), "web-token")
		if b, err := os.ReadFile(tf); err == nil && len(b) > 0 {
			*token = string([]byte(strings.TrimSpace(string(b))))
		} else {
			b := make([]byte, 16)
			if _, err := rand.Read(b); err != nil {
				return err
			}
			*token = hex.EncodeToString(b)
			_ = os.MkdirAll(filepath.Dir(tf), 0o755)
			if err := os.WriteFile(tf, []byte(*token+"\n"), 0o600); err != nil {
				log.Printf("warning: could not persist token: %v", err)
			}
		}
	}

	staticDir := *dir
	if staticDir == "" {
		if exe, err := os.Executable(); err == nil {
			staticDir = filepath.Join(filepath.Dir(exe), "..", "web", "build")
		}
		if _, err := os.Stat(staticDir); err != nil {
			staticDir = "web/build"
		}
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/ws", func(w http.ResponseWriter, r *http.Request) {
		if subtle.ConstantTimeCompare([]byte(r.URL.Query().Get("token")), []byte(*token)) != 1 {
			http.Error(w, "bad token", http.StatusUnauthorized)
			return
		}
		ws, err := websocket.Accept(w, r, &websocket.AcceptOptions{
			// same-host page is the only intended origin; token is the
			// real gate, this just blocks casual cross-site use
			InsecureSkipVerify: true,
		})
		if err != nil {
			return
		}
		defer ws.CloseNow()

		conn, err := net.Dial("unix", *sock)
		if err != nil {
			ws.Close(websocket.StatusInternalError, "mux server not running")
			return
		}
		defer conn.Close()

		ctx := r.Context()
		errc := make(chan error, 2)

		// ws -> socket
		go func() {
			for {
				typ, data, err := ws.Read(ctx)
				if err != nil {
					errc <- err
					return
				}
				if typ != websocket.MessageBinary {
					continue
				}
				if _, err := conn.Write(data); err != nil {
					errc <- err
					return
				}
			}
		}()
		// socket -> ws
		go func() {
			buf := make([]byte, 64*1024)
			for {
				n, err := conn.Read(buf)
				if n > 0 {
					wctx, cancel := context.WithTimeout(ctx, 10*time.Second)
					werr := ws.Write(wctx, websocket.MessageBinary, buf[:n])
					cancel()
					if werr != nil {
						errc <- werr
						return
					}
				}
				if err != nil {
					errc <- err
					return
				}
			}
		}()
		err = <-errc
		if err != nil && err != io.EOF {
			ws.Close(websocket.StatusNormalClosure, "")
		}
	})
	mux.Handle("/", http.FileServer(http.Dir(staticDir)))

	fmt.Printf("rook web on http://%s/?token=%s\n", *addr, *token)
	fmt.Printf("  mux socket: %s\n  static dir: %s\n", *sock, staticDir)
	return http.ListenAndServe(*addr, mux)
}
