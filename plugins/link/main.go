// rook-plugin-link — the direct rail: this machine, made visible from
// your phone with no cloud in between.
//
// It is the host half of rook-host's link rail (rook.link.v1): a
// durable identity, a paired-device book, a TLS listener on the LAN,
// and a Bonjour advertisement so the phone can find it. The phone gets
// the same snapshot the fleet pages get — the SAME fold, literally:
// plugins/internal/statusfold, shared with the cloud bridge — and the
// answers and commands it sends back land at the same keyboard under
// the same rules.
//
// Those rules are the point. Delivery is at-most-once at the keyboard,
// enforced by the delivery journal (plugins/internal/cmdjournal) that
// BOTH rails share — same file, same keys, flocked across the two
// processes — so a command that arrives over the cloud and over the
// link is one command, and a crash between the keyboard and the reply
// costs a redundant Duplicate and never a second round of typing.
//
// Pairing is a ceremony with a human in it: the panel row's "pair a
// phone" action opens a two-minute window and spawns a pane showing a
// QR (this same binary, `qr <url>` argv mode). Failed identity, failed
// listener, refused spawn: all are panel rows that say exactly that,
// never a dead plugin.
package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/incantery/rook-host/bonjour"
	"github.com/incantery/rook-host/identity"
	"github.com/incantery/rook-host/link"
	"github.com/incantery/rook-host/pairing"
	"github.com/incantery/rook-host/projection"
	"github.com/incantery/rook-host/registry"
	"github.com/incantery/rook-host/transport"

	"github.com/incantery/rook/plugins/internal/cmdjournal"
	"github.com/incantery/rook/plugins/internal/digestlog"
	"github.com/incantery/rook/plugins/internal/nowfile"
	"github.com/incantery/rook/plugins/internal/statusfold"
	"github.com/incantery/rook/plugins/internal/transcript"
)

const version = "0.1.0"

func main() {
	// `qr <url>` is a display, not a plugin: it renders the pairing QR
	// in whatever pane spawned it, waits for Enter, and exits. It must
	// not touch state or network — the URL already carries everything.
	if len(os.Args) >= 2 && os.Args[1] == "qr" {
		if len(os.Args) < 3 {
			fmt.Fprintln(os.Stderr, "usage: rook-plugin-link qr <rook-link://pair?...>")
			os.Exit(2)
		}
		runQR(os.Args[2])
		return
	}

	port := flag.Int("port", 0, "listen port (0 = ephemeral)")
	stateDir := flag.String("state-dir", "", "identity + device book directory (default ~/.local/state/rook/link)")
	advertise := flag.Bool("advertise", true, "advertise the listener over Bonjour")
	deliveries := flag.String("delivery-log", cmdjournal.DefaultPath(), "the SHARED delivery journal (empty = remember only while running)")
	name := flag.String("name", "", "host display name (default this machine's hostname)")
	dir := flag.String("dir", "", "projects directory (default ~/.claude/projects)")
	window := flag.Duration("window", 48*time.Hour, "how far back sessions are reported")
	busyRate := flag.Float64("busy-rate", 200, "pane output above this (bytes/sec) proves an agent is working")
	names := flag.String("claude-names", "claude,node", "foreground program names that count as Claude Code")
	digests := flag.String("digest-log", digestlog.DefaultPath(), "the agent plugin's digest journal (empty sends no digests)")
	rookVersion := flag.String("rook-version", "", "reported rook version")
	flag.Parse()

	home, _ := os.UserHomeDir()
	if *dir == "" {
		if home == "" {
			fmt.Fprintln(os.Stderr, "no home directory and no --dir")
			os.Exit(1)
		}
		*dir = filepath.Join(home, ".claude", "projects")
	}
	if *stateDir == "" {
		if x := os.Getenv("XDG_STATE_HOME"); x != "" {
			*stateDir = filepath.Join(x, "rook", "link")
		} else if home != "" {
			*stateDir = filepath.Join(home, ".local", "state", "rook", "link")
		}
	}
	if *name == "" {
		*name, _ = os.Hostname()
	}

	// The delivery journal — the SAME file the cloud bridge holds open.
	// cmdjournal flocks around every append and re-reads before every
	// Delivered(), which is what makes one command over two rails one
	// command.
	journal, jerr := cmdjournal.Open(*deliveries, 30*24*time.Hour, time.Now())

	h := &lk{
		journal: journal,
		sc: &transcript.Scanner{
			Dir:    *dir,
			Window: *window,
			Idle:   10 * time.Minute,
			Quiet:  60 * time.Second,
			Max:    50,
		},
		names:      strings.Split(*names, ","),
		busyRate:   *busyRate,
		digestLog:  *digests,
		rookVer:    *rookVersion,
		hostName:   *name,
		pairs:      &pairing.Manager{},
		spawnTries: 6,
		spawnWait:  2 * time.Second,
	}
	if jerr != nil {
		h.note("deliveries are not journaled (" + jerr.Error() + ") — a crash could retype an answer")
	}

	// Identity, device book, front door. Every failure here is a panel
	// row, not an exit: a failed plugin must render rows, not die.
	h.open(*stateDir, *port, *advertise)

	c := &conn{out: os.Stdout}
	h.c = c
	if h.srv != nil {
		go h.loop(c, 20*time.Second)
	}
	serve(c, h)
}

// ---- the host ----

// lk holds the link rail's truth: who this machine is to its paired
// devices, whether the front door is open, and the last delivery's
// story for the panel.
type lk struct {
	c       *conn
	journal *cmdjournal.Log

	sc        *transcript.Scanner
	names     []string
	busyRate  float64
	digestLog string
	rookVer   string
	hostName  string

	id    *identity.Identity
	reg   *registry.Registry
	pairs *pairing.Manager
	srv   *link.Server
	ln    *transport.Listener
	adv   *bonjour.Advertiser
	spki  string

	// How long a spawn waits for its new claude pane to be ready for
	// the prompt: spawnTries polls of the pane list, spawnWait apart.
	spawnTries int
	spawnWait  time.Duration

	mu       sync.Mutex
	fatal    string // identity/listener failure; the panel says exactly this
	lastNote string
	lastPub  time.Time
	agents   int
	world    world // the freshest scan, for the executor

	// The pane streamers, one per watched session (panes.go). Its own
	// mutex: Open/Close arrive under the link server's hub lock, and
	// h.mu is taken by paths a streamer itself calls into. pubPane is
	// srv.PublishPane in life and a recorder in tests.
	paneMu    sync.Mutex
	paneWatch map[string]context.CancelFunc
	pubPane   func(sessionID string, f projection.PaneFrame)
}

// world is the publish loop's latest view — what the executor delivers
// against, so an answer lands where the last snapshot said the ask was.
type world struct {
	sessions []transcript.Session
	panes    []transcript.PaneActivity
	at       time.Time
}

// open stands the rail up: identity, registry, server, listener,
// advertisement. Any failure is recorded and the rest is skipped — the
// stdio side serves rows either way.
func (h *lk) open(stateDir string, port int, advertise bool) {
	if stateDir == "" {
		h.fail("no state directory — no home and no --state-dir")
		return
	}
	id, err := identity.LoadOrCreate(filepath.Join(stateDir, "identity.json"))
	if err != nil {
		h.fail("identity: " + err.Error())
		return
	}
	h.id = id
	pin, err := id.SPKIPin()
	if err != nil {
		h.fail("identity has no TLS pin: " + err.Error())
		return
	}
	h.spki = pin
	reg, err := registry.Open(filepath.Join(stateDir, "devices.json"))
	if err != nil {
		h.fail("device book: " + err.Error())
		return
	}
	h.reg = reg
	srv := link.NewServer(link.Options{
		Identity: id,
		Registry: reg,
		Pairing:  h.pairs,
		Executor: h,
		Panes:    h,
		Digests:  h,
		HostName: h.hostName,
	})
	// The port must survive relaunches: a phone caches host:port from
	// its pairing, and Bonjour rediscovery is a convenience that TCC
	// can silently take away — a fresh ephemeral port on every launch
	// would orphan every paired device that can't browse. First launch
	// picks one ephemeral port; every launch after rebinds it, falling
	// back to ephemeral (and re-persisting) only if something else
	// holds it.
	portFile := filepath.Join(stateDir, "port")
	if port == 0 {
		port = readPort(portFile)
	}
	ln, err := transport.Listen(fmt.Sprintf(":%d", port), id, srv.Handler())
	if err != nil && port != 0 {
		h.note(fmt.Sprintf("port %d is taken — moving to an ephemeral one; phones re-find it by Bonjour or a fresh QR", port))
		ln, err = transport.Listen(":0", id, srv.Handler())
	}
	if err != nil {
		h.fail("cannot listen: " + err.Error())
		return
	}
	writePort(portFile, ln.Port())
	h.srv, h.ln = srv, ln
	h.pubPane = srv.PublishPane
	if advertise {
		adv, err := bonjour.Advertise(context.Background(), bonjour.Info{
			Name:            h.hostName,
			Port:            ln.Port(),
			HostID:          id.HostID(),
			TrustDomainID:   id.TrustDomainID,
			ProtocolVersion: link.ProtocolVersion,
		})
		if err != nil {
			// Discovery is a convenience, not the rail: the QR carries
			// direct addresses, so pairing still works.
			h.note("bonjour refused (" + err.Error() + ") — the QR's address hints still work")
		} else {
			h.adv = adv
		}
	}
}

// readPort recalls the previously bound port, 0 when there is nothing
// worth recalling.
func readPort(path string) int {
	raw, err := os.ReadFile(path)
	if err != nil {
		return 0
	}
	p, err := strconv.Atoi(strings.TrimSpace(string(raw)))
	if err != nil || p <= 0 || p > 65535 {
		return 0
	}
	return p
}

// writePort persists the bound port for the next launch. Best effort:
// a failure costs the next launch a fresh port, which is where we
// started.
func writePort(path string, port int) {
	_ = os.WriteFile(path, []byte(strconv.Itoa(port)+"\n"), 0o600)
}

func (h *lk) fail(msg string) {
	h.mu.Lock()
	h.fatal = msg
	h.mu.Unlock()
}

func (h *lk) note(msg string) {
	h.mu.Lock()
	h.lastNote = msg
	h.mu.Unlock()
}

// loop is the heartbeat: scan, fuse with pane activity, fold, publish
// to whoever is watching. Same cadence and same fold as the cloud
// bridge — one membrane, another rail.
func (h *lk) loop(c *conn, interval time.Duration) {
	samples := map[int]transcript.PaneSample{}
	for {
		now := time.Now()
		sessions := h.sc.Scan(now)
		panes := fetchActivity(c)
		transcript.ComputeRates(samples, panes, now)
		transcript.Fuse(sessions, panes, h.names, h.busyRate, 45*time.Second)

		var digests map[string]digestlog.Digest
		if h.digestLog != "" {
			digests = digestlog.Latest(digestlog.Load(h.digestLog, h.sc.Window, now))
		}
		// The agent plugin's screen-watcher file; read-only here, same
		// ownership story as the journal.
		nows := nowfile.Read(nowfile.DefaultPath(), 90*time.Second, now)
		st := statusfold.Fold(sessions, digests, nows, h.hostName, h.rookVer)
		h.srv.Publish(toProjection(st))

		agents := 0
		for _, w := range st.Workspaces {
			agents += len(w.Agents)
		}
		h.mu.Lock()
		h.world = world{sessions: sessions, panes: panes, at: now}
		h.lastPub = now
		h.agents = agents
		h.mu.Unlock()

		time.Sleep(interval)
	}
}

// snapshot is what the executor delivers against: the loop's view if
// it is fresh, or its own scan if the loop is behind (first tick, or a
// wedged substrate). Rate fusion needs two ticks, so the fallback leans
// on recency alone — good enough to find a pane, honest about state.
func (h *lk) snapshot() ([]transcript.Session, []transcript.PaneActivity) {
	h.mu.Lock()
	w := h.world
	h.mu.Unlock()
	if time.Since(w.at) < 45*time.Second {
		return w.sessions, w.panes
	}
	now := time.Now()
	sessions := h.sc.Scan(now)
	panes := fetchActivity(h.c)
	transcript.ComputeRates(map[int]transcript.PaneSample{}, panes, now)
	transcript.Fuse(sessions, panes, h.names, h.busyRate, 45*time.Second)
	return sessions, panes
}

// toProjection renders the neutral fold as rook-host's projection —
// the 1:1 twin of the cloud bridge's wire conversion.
func toProjection(n statusfold.Status) projection.Status {
	st := projection.Status{Hostname: n.Hostname, RookVersion: n.RookVersion}
	for _, w := range n.Workspaces {
		pw := projection.Workspace{Name: w.Name, Branch: w.Branch, Attention: w.Attention}
		for _, a := range w.Agents {
			pa := projection.Agent{
				ID:        a.ID,
				State:     a.State,
				Title:     a.Title,
				Ask:       a.Ask,
				AskID:     a.AskID,
				Model:     a.Model,
				CostUSD:   a.CostUSD,
				CtxPct:    a.CtxPct,
				Now:       a.Now,
				NowAt:     a.NowAt,
				LastEvent: a.LastEvent,
			}
			if a.Digest != nil {
				pa.Digest = &projection.AgentDigest{Headline: a.Digest.Headline, Bullets: a.Digest.Bullets, At: a.Digest.At}
			}
			pw.Agents = append(pw.Agents, pa)
		}
		st.Workspaces = append(st.Workspaces, pw)
	}
	return st
}

// ---- the panel ----

type wireField struct {
	Key   string `json:"key"`
	Kind  string `json:"kind"`
	Value string `json:"value"`
}

type wireItemAction struct {
	ID    string `json:"id"`
	Label string `json:"label"`
}

type wireItem struct {
	ID      string           `json:"id"`
	Title   string           `json:"title"`
	State   string           `json:"state,omitempty"`
	Fields  []wireField      `json:"fields,omitempty"`
	Actions []wireItemAction `json:"actions,omitempty"`
}

// items is the rail as rows: the front door first (or exactly what is
// wrong with it), then one row per paired device, then the last
// delivery's story.
func items(h *lk, now time.Time) []wireItem {
	h.mu.Lock()
	fatal, lastNote := h.fatal, h.lastNote
	h.mu.Unlock()

	var out []wireItem
	switch {
	case fatal != "":
		out = append(out, wireItem{ID: "link:down", Title: fatal, State: "error"})
	case h.ln != nil && h.ln.Err() != nil:
		out = append(out, wireItem{ID: "link:down", Title: "listener died: " + h.ln.Err().Error(), State: "error"})
	default:
		paired := 0
		for _, d := range h.reg.List() {
			if !d.Revoked() {
				paired++
			}
		}
		it := wireItem{
			ID:      "link:door",
			Title:   fmt.Sprintf("link: listening on :%d · %d paired", h.ln.Port(), paired),
			State:   "up",
			Actions: []wireItemAction{{ID: "pair", Label: "pair a phone"}},
		}
		if h.pairs.OpenNow(now) {
			it.Fields = append(it.Fields, wireField{"pairing", "TEXT", "window open"})
		}
		out = append(out, it)
	}

	if h.reg != nil {
		devices := h.reg.List()
		sort.Slice(devices, func(i, j int) bool { return devices[i].PairedAt.Before(devices[j].PairedAt) })
		for _, d := range devices {
			name := d.Name
			if name == "" {
				name = d.Model
			}
			if name == "" {
				name = d.ID
			}
			it := wireItem{ID: "link:dev:" + d.ID, Title: name}
			if d.Model != "" && d.Model != name {
				it.Fields = append(it.Fields, wireField{"model", "TEXT", d.Model})
			}
			if d.LastSeenAt.IsZero() {
				it.Fields = append(it.Fields, wireField{"seen", "TEXT", "never"})
			} else {
				it.Fields = append(it.Fields, wireField{"seen", "TEXT", transcript.RelAge(now.Sub(d.LastSeenAt)) + " ago"})
			}
			if d.Revoked() {
				it.Title += " — revoked"
				it.State = "off"
			} else {
				it.Actions = []wireItemAction{{ID: "revoke:" + d.ID, Label: "revoke"}}
			}
			out = append(out, it)
		}
	}

	if lastNote != "" {
		out = append(out, wireItem{ID: "link:note", Title: lastNote})
	}
	return out
}

func act(h *lk, id uint64, params json.RawMessage) reply {
	var p struct {
		ActionID string `json:"actionId"`
	}
	if json.Unmarshal(params, &p) != nil {
		return reply{1, id, false, nil, "params did not parse"}
	}
	switch {
	case p.ActionID == "pair":
		if h.srv == nil || h.ln == nil {
			return reply{1, id, false, nil, "the link is down — nothing to pair against"}
		}
		// The spawn is a conn.call, and act runs ON the serve goroutine
		// — the one that delivers replies — so the ceremony must leave
		// this stack before it waits on anything.
		go h.pair()
		return reply{1, id, true, map[string]string{"message": "pairing window opening…"}, ""}
	case strings.HasPrefix(p.ActionID, "revoke:"):
		if h.srv == nil {
			return reply{1, id, false, nil, "the link is down"}
		}
		devID := strings.TrimPrefix(p.ActionID, "revoke:")
		if err := h.srv.RevokeDevice(devID); err != nil {
			return reply{1, id, false, nil, "revoke: " + err.Error()}
		}
		h.note("revoked a device — its next call fails, its streams are cut")
		return reply{1, id, true, map[string]string{"message": "revoked"}, ""}
	}
	return reply{1, id, false, nil, "no such action: " + p.ActionID}
}

// pair opens the two-minute window and puts the QR on a screen: a
// fresh pane running this same binary in `qr` mode. The URL is built
// from url.Values — percent-encoded, so shell-safe by construction —
// and refused outright if a quote somehow appears anyway. If the spawn
// is refused (grant withheld), the URL falls back to the clipboard.
func (h *lk) pair() {
	secret, err := h.pairs.Open(time.Now())
	if err != nil {
		h.note("could not open a pairing window: " + err.Error())
		return
	}
	// Minimal on purpose: every byte here is QR modules, and QR modules
	// are pane columns. The phone learns the name from GetHostInfo and
	// the trust domain from PairResponse — no n=, no td=, and at most
	// two address hints.
	addrs := transport.Addrs()
	if len(addrs) > 2 {
		addrs = addrs[:2]
	}
	url := pairing.QR{
		HostID:  h.id.HostID(),
		SPKIPin: h.spki,
		Secret:  secret,
		Port:    h.ln.Port(),
		Addrs:   addrs,
	}.URL()
	if strings.ContainsAny(url, `'"`) {
		h.pairs.Close()
		h.note("refused to display the QR — the URL grew a quote character")
		return
	}
	exe, err := os.Executable()
	if err != nil || strings.ContainsAny(exe, `'"`) {
		h.clipFallback(url, "cannot name this binary for the QR pane")
		return
	}
	cmd := "'" + exe + "' qr '" + url + "'"
	if _, err := h.c.call("session.spawn", map[string]any{"command": cmd}, 5*time.Second); err != nil {
		h.clipFallback(url, "QR pane refused ("+err.Error()+")")
		return
	}
	h.note("pairing window open (2 minutes) — scan the QR in the new pane")
}

// clipFallback is the QR's second life: the same URL on the clipboard,
// for typing or pasting into the phone by hand.
func (h *lk) clipFallback(url, why string) {
	if _, err := h.c.call("clipboard.set", map[string]any{"text": url}, 3*time.Second); err == nil {
		h.note(why + " — pairing URL copied to the clipboard (2-minute window)")
	} else {
		h.pairs.Close()
		h.note(why + ", and the clipboard refused too — pairing needs one of them")
	}
}
