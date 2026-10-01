package main

import (
	"encoding/json"
	"fmt"
	"net"
	"os"
	"os/exec"
	"slices"
	"sort"
	"strconv"
	"strings"
	"text/tabwriter"
	"time"

	"github.com/incantery/rook/internal/mux"
)

// The background (docs/background.md): panes that run in no window.
// The engine holds them and moves them; what a pane's processes are
// listening on, and whether the port it promised answers, is asked of
// the machine here — the engine knows panes, not sockets.

// bgPane is one row of the engine's `bg ls`, plus what this layer
// finds out about it.
type bgPane struct {
	ID        int    `json:"id"`
	Pid       int    `json:"pid"`
	Group     string `json:"group"`
	Place     string `json:"place"`
	Workspace string `json:"workspace"`
	Window    *int   `json:"window"`
	Program   string `json:"program"`
	Command   string `json:"command"`
	By        string `json:"by"`
	Port      int    `json:"port"`
	Cwd       string `json:"cwd"`
	BornMs    int64  `json:"bornMs"`
	Exited    bool   `json:"exited"`
	ExitMs    int64  `json:"exitMs"`
	LastOutMs int64  `json:"lastOutputMs"`

	// Ports are the TCP ports the pane's processes listen on.
	Ports []int `json:"ports"`
	// Health is exited, healthy (the promised port answers), starting
	// (it does not yet), or running (no port was promised).
	Health string `json:"health"`
}

func runBg(args []string) error {
	sub := "ls"
	if len(args) > 0 {
		sub = args[0]
	}
	switch sub {
	case "ls", "list", "--json":
		asJSON := sub == "--json"
		for _, a := range args[min(1, len(args)):] {
			if a == "--json" {
				asJSON = true
			}
		}
		return bgList(asJSON)
	case "wait":
		return bgWait(args[1:])
	case "pick":
		return bgPick()
	case "run":
		execMux(append([]string{"bg"}, bgAutoPort(args)...))
	default:
		execMux(append([]string{"bg"}, args...))
	}
	return nil
}

// bgAutoPort turns `--port auto` into a free port: said to the engine
// as the port the service promises, and to the service as $PORT.
func bgAutoPort(args []string) []string {
	out := slices.Clone(args)
	for i := 1; i+1 < len(out); i++ {
		if out[i] == "--" {
			break
		}
		if out[i] != "--port" || out[i+1] != "auto" {
			continue
		}
		l, err := net.Listen("tcp", "127.0.0.1:0")
		if err != nil {
			fmt.Fprintln(os.Stderr, "rook: bg run: no free port:", err)
			os.Exit(1)
		}
		port := l.Addr().(*net.TCPAddr).Port
		l.Close()
		out[i+1] = strconv.Itoa(port)
		// the command starts after the options: at `--`, else at the
		// first word that is not one
		at := len(out)
		for j := 1; j < len(out); j++ {
			if out[j] == "--" {
				at = j + 1
				break
			}
			if strings.HasPrefix(out[j], "-") {
				j++ // its value
				continue
			}
			at = j
			break
		}
		// exported in the shell the command runs under, so the command
		// line itself can say $PORT
		env := []string{"export PORT=" + strconv.Itoa(port) + ";"}
		out = append(out[:at:at], append(env, out[at:]...)...)
		fmt.Fprintf(os.Stderr, "rook: PORT=%d\n", port)
		break
	}
	return out
}

// bgPanes asks the engine for the table and fills in ports and health.
func bgPanes() ([]bgPane, error) {
	out, err := exec.Command(mux.EnginePath(), "bg", "ls").Output()
	if err != nil {
		return nil, fmt.Errorf("the engine did not answer — is rook running?")
	}
	var panes []bgPane
	if err := json.Unmarshal(out, &panes); err != nil {
		return nil, fmt.Errorf("bg ls: %w", err)
	}
	listening := listeners()
	kids := children()
	for i := range panes {
		p := &panes[i]
		p.Ports = []int{}
		if !p.Exited {
			seen := map[int]bool{}
			for _, pid := range descendants(p.Pid, kids) {
				for _, port := range listening[pid] {
					if !seen[port] {
						seen[port] = true
						p.Ports = append(p.Ports, port)
					}
				}
			}
			sort.Ints(p.Ports)
		}
		p.Health = health(*p)
	}
	sort.SliceStable(panes, func(a, b int) bool {
		if panes[a].Group != panes[b].Group {
			return panes[a].Group < panes[b].Group
		}
		return panes[a].ID < panes[b].ID
	})
	return panes, nil
}

// health is what "running" is worth: a service that promised a port
// is healthy when something answers on it.
func health(p bgPane) string {
	switch {
	case p.Exited:
		return "exited"
	case p.Port == 0:
		return "running"
	case answers(p.Port):
		return "healthy"
	}
	return "starting"
}

func answers(port int) bool {
	for _, host := range []string{"127.0.0.1", "[::1]"} {
		c, err := net.DialTimeout("tcp", host+":"+strconv.Itoa(port), 300*time.Millisecond)
		if err == nil {
			c.Close()
			return true
		}
	}
	return false
}

// listeners maps a pid to the TCP ports it listens on (lsof).
func listeners() map[int][]int {
	m := map[int][]int{}
	// lsof lives in /usr/sbin, which a pane's PATH may not have
	lsof := "/usr/sbin/lsof"
	if found, err := exec.LookPath("lsof"); err == nil {
		lsof = found
	}
	out, _ := exec.Command(lsof, "-nP", "-iTCP", "-sTCP:LISTEN", "-Fpn").Output()
	pid := 0
	for _, line := range strings.Split(string(out), "\n") {
		if len(line) < 2 {
			continue
		}
		switch line[0] {
		case 'p':
			pid, _ = strconv.Atoi(line[1:])
		case 'n':
			if i := strings.LastIndex(line, ":"); i >= 0 {
				if port, err := strconv.Atoi(line[i+1:]); err == nil && pid > 0 {
					m[pid] = append(m[pid], port)
				}
			}
		}
	}
	return m
}

// children maps a pid to its child pids (ps).
func children() map[int][]int {
	m := map[int][]int{}
	out, _ := exec.Command("ps", "-axo", "pid=,ppid=").Output()
	for _, line := range strings.Split(string(out), "\n") {
		f := strings.Fields(line)
		if len(f) != 2 {
			continue
		}
		pid, _ := strconv.Atoi(f[0])
		ppid, _ := strconv.Atoi(f[1])
		m[ppid] = append(m[ppid], pid)
	}
	return m
}

func descendants(root int, kids map[int][]int) []int {
	out := []int{root}
	for i := 0; i < len(out) && len(out) < 4096; i++ {
		out = append(out, kids[out[i]]...)
	}
	return out
}

func bgList(asJSON bool) error {
	panes, err := bgPanes()
	if err != nil {
		return err
	}
	if asJSON {
		if panes == nil {
			panes = []bgPane{}
		}
		return json.NewEncoder(os.Stdout).Encode(panes)
	}
	if len(panes) == 0 {
		fmt.Println("nothing in the background  (rook bg run -- <command>)")
		return nil
	}
	w := tabwriter.NewWriter(os.Stdout, 0, 0, 2, ' ', 0)
	fmt.Fprintln(w, "GROUP\tPANE\tSTATE\tPORTS\tUP\tWHERE\tBY\tWHAT")
	now := time.Now().UnixMilli()
	for _, p := range panes {
		fmt.Fprintf(w, "%s\t%d\t%s\t%s\t%s\t%s\t%s\t%s\n",
			p.Group, p.ID, p.Health, bgPorts(p), bgUp(p, now), bgWhere(p), dash(p.By), bgWhat(p))
	}
	return w.Flush()
}

func dash(s string) string {
	if s == "" {
		return "-"
	}
	return s
}

// bgPorts is what it listens on, and the promised port it does not
// answer on yet, marked.
func bgPorts(p bgPane) string {
	var out []string
	has := false
	for _, port := range p.Ports {
		out = append(out, ":"+strconv.Itoa(port))
		if port == p.Port {
			has = true
		}
	}
	if p.Port != 0 && !has && p.Health != "healthy" {
		out = append(out, ":"+strconv.Itoa(p.Port)+"?")
	} else if p.Port != 0 && !has {
		out = append(out, ":"+strconv.Itoa(p.Port))
	}
	return dash(strings.Join(out, " "))
}

func bgUp(p bgPane, now int64) string {
	if p.BornMs == 0 {
		return "-"
	}
	end := now
	if p.Exited && p.ExitMs > 0 {
		end = p.ExitMs
	}
	d := time.Duration(end-p.BornMs) * time.Millisecond
	switch {
	case d < time.Minute:
		return fmt.Sprintf("%ds", int(d.Seconds()))
	case d < time.Hour:
		return fmt.Sprintf("%dm", int(d.Minutes()))
	case d < 48*time.Hour:
		return fmt.Sprintf("%dh%02dm", int(d.Hours()), int(d.Minutes())%60)
	}
	return fmt.Sprintf("%dd", int(d.Hours())/24)
}

func bgWhere(p bgPane) string {
	if p.Place == "bg" {
		return "background"
	}
	if p.Window != nil {
		return fmt.Sprintf("%s:%d", p.Workspace, *p.Window)
	}
	if p.Workspace != "" {
		return p.Workspace + ":" + p.Place
	}
	return p.Place
}

func bgWhat(p bgPane) string {
	what := p.Command
	if what == "" {
		what = p.Program
	}
	if len(what) > 60 {
		what = what[:59] + "…"
	}
	return what
}

// bgWait blocks until a pane, or every pane of a group, is healthy —
// or one of them has exited, which is exit status 1 with the row said.
// `--exit` waits for the exit instead: the watch on a thing that is
// meant to end.
func bgWait(args []string) error {
	target, timeout, forExit := "", time.Duration(0), false
	for i := 0; i < len(args); i++ {
		switch {
		case args[i] == "--timeout" && i+1 < len(args):
			ms, err := strconv.Atoi(args[i+1])
			if err != nil {
				return fmt.Errorf("bg wait: --timeout is milliseconds")
			}
			timeout = time.Duration(ms) * time.Millisecond
			i++
		case args[i] == "--exit":
			forExit = true
		case strings.HasPrefix(args[i], "-") && args[i] != ".":
			return fmt.Errorf("bg wait: unknown option %s", args[i])
		default:
			target = args[i]
		}
	}
	if target == "" {
		return fmt.Errorf("usage: rook bg wait <pane>|<group> [--exit] [--timeout MS]")
	}
	if target == "." {
		target = os.Getenv("ROOK_MUX_PANE")
	}
	start := time.Now()
	for {
		panes, err := bgPanes()
		if err != nil {
			return err
		}
		var mine []bgPane
		for _, p := range panes {
			if strconv.Itoa(p.ID) == target || p.Group == target {
				mine = append(mine, p)
			}
		}
		if len(mine) == 0 {
			return fmt.Errorf("bg wait: nothing called %s", target)
		}
		ready, exited := 0, 0
		for _, p := range mine {
			switch p.Health {
			case "exited":
				exited++
			case "healthy", "running":
				ready++
			}
		}
		if forExit && exited == len(mine) {
			return json.NewEncoder(os.Stdout).Encode(mine)
		}
		if !forExit && exited > 0 {
			json.NewEncoder(os.Stdout).Encode(mine)
			return fmt.Errorf("bg wait: %d of %s exited", exited, target)
		}
		if !forExit && ready == len(mine) {
			return json.NewEncoder(os.Stdout).Encode(mine)
		}
		if timeout > 0 && time.Since(start) >= timeout {
			json.NewEncoder(os.Stdout).Encode(mine)
			return fmt.Errorf("bg wait: timed out")
		}
		time.Sleep(500 * time.Millisecond)
	}
}

// bgPick is the picker to bind (`B = "popup rook bg pick"`): the
// groups in the background in fzf; enter brings one into the window
// you are in.
func bgPick() error {
	panes, err := bgPanes()
	if err != nil {
		return err
	}
	type row struct {
		n      int
		states map[string]int
		what   []string
	}
	groups := map[string]*row{}
	var order []string
	for _, p := range panes {
		if p.Place != "bg" {
			continue
		}
		r := groups[p.Group]
		if r == nil {
			r = &row{states: map[string]int{}}
			groups[p.Group] = r
			order = append(order, p.Group)
		}
		r.n++
		r.states[p.Health]++
		r.what = append(r.what, strings.TrimSpace(bgWhat(p)+" "+strings.ReplaceAll(bgPorts(p), "-", "")))
	}
	if len(order) == 0 {
		fmt.Println("nothing in the background")
		time.Sleep(900 * time.Millisecond)
		return nil
	}
	var in strings.Builder
	for _, g := range order {
		r := groups[g]
		var st []string
		for _, k := range []string{"exited", "starting", "healthy", "running"} {
			if r.states[k] > 0 {
				st = append(st, fmt.Sprintf("%d %s", r.states[k], k))
			}
		}
		fmt.Fprintf(&in, "%s\t%s\t%s\n", g, strings.Join(st, ", "), strings.Join(r.what, " · "))
	}
	cmd := exec.Command("fzf", "--delimiter=\t", "--with-nth=1..", "--prompt=♜ bg ", "--height=100%", "--reverse")
	cmd.Stdin = strings.NewReader(in.String())
	cmd.Stderr = os.Stderr
	out, err := cmd.Output()
	if err != nil {
		return nil // esc
	}
	group, _, _ := strings.Cut(strings.TrimSpace(string(out)), "\t")
	if group == "" {
		return nil
	}
	return exec.Command(mux.EnginePath(), "bg", "show", group, "--focus").Run()
}
