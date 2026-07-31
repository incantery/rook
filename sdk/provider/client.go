package provider

// rook's half: finding a provider, starting it, and surviving it.
//
// The lifecycle rules are the ones a thing rook does not control earns:
//
//   - LAZY. Nothing spawns until somebody asks a question. A configured
//     provider that is never used costs one struct.
//   - RESTARTABLE. A provider that died (crash, our own kill, an upgrade
//     replacing the binary) is respawned by the next call. Callers never
//     see "it was dead" as a distinct failure, because there is nothing
//     useful they could do differently.
//   - DEADLINE-BOUND, and a violated deadline is FATAL to the process. A
//     provider that answers after we stopped listening has left a frame
//     in the pipe, and every later answer would be off by one — so a
//     timeout kills it rather than trying to resynchronise. Cheap: the
//     next call starts a fresh one.
//
// One request in flight at a time, guarded by the mutex. The wire carries
// ids so this can be relaxed without a protocol change; nothing yet needs
// it, and a single outstanding request makes the timeout rule above a
// two-line invariant instead of a bookkeeping problem.

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

// handshakeTimeout bounds `describe`. A provider that cannot say who it
// is this fast is broken, not busy.
const handshakeTimeout = 5 * time.Second

// maxFrame caps one response. A provider cannot make rook grow without
// bound by answering at length.
const maxFrame = 8 << 20

// graceMS is how much sooner the PROVIDER's deadline is than ours.
//
// Both sides bounding the same call at the same instant is a race whose
// two outcomes are wildly different: the provider answers "I gave up",
// which leaves the stream in sync and the process healthy, or we give up
// first and kill it. Handing over a deadline slightly shorter than the
// one we are actually willing to wait for makes the cooperative outcome
// the one that happens, and reserves the kill for a provider that is
// genuinely wedged rather than merely slow.
const graceMS = 250

// Client is one provider process, started on demand.
type Client struct {
	Name string
	// Env is this provider's configuration, passed as environment
	// variables at spawn (`ROOK_PROVIDER_LINEAR_TEAM=ENG`) rather than
	// over the wire.
	//
	// Environment because it needs no protocol version to grow, works
	// from any language without a parser, and lets a human run the
	// provider by hand exactly as rook runs it — which is the difference
	// between a debuggable ecosystem and an opaque one. Credentials do
	// NOT come this way: a provider fetches its own, so a secret never
	// passes through rook's address space at all.
	Env map[string]string
	// Path overrides binary resolution. Empty means the normal search
	// (beside rook, then PATH); set it to run a provider from somewhere
	// else — a dev build, or a test's own helper.
	Path string

	mu   sync.Mutex
	path string
	cmd  *exec.Cmd
	w    io.WriteCloser
	r    *bufio.Reader
	caps map[string]bool
	id   int
}

// New names a provider without starting it. The binary is
// `rook-provider-<name>`, resolved at first use.
func New(name string) *Client { return &Client{Name: name} }

// Find reports whether the provider's binary exists, without starting it
// — how a caller decides a provider is available at all.
func (c *Client) Find() bool { _, err := c.resolve(); return err == nil }

// InstallDir is where installed providers live:
// $XDG_DATA_HOME/rook/providers (default ~/.local/share/rook/providers),
// one binary per provider. This is the home a third-party provider gets
// instead of "drop it on PATH and hope".
func InstallDir() string {
	base := os.Getenv("XDG_DATA_HOME")
	if base == "" {
		home, err := os.UserHomeDir()
		if err != nil {
			return ""
		}
		base = filepath.Join(home, ".local", "share")
	}
	return filepath.Join(base, "rook", "providers")
}

// resolve searches, in order: beside the running binary, the install
// directory, then PATH.
//
// Beside-first is for the ones rook SHIPS — they are built and installed
// with it and must upgrade with it, so a stale copy elsewhere must never
// win. The install directory is where everyone else's land. PATH is last
// and is really for development: it is the only one of the three a
// provider can end up on without anybody deciding to put it there.
func (c *Client) resolve() (string, error) {
	if c.Path != "" {
		if !isExec(c.Path) {
			return "", fmt.Errorf("%s is not executable", c.Path)
		}
		return c.Path, nil
	}
	bin := "rook-provider-" + c.Name
	if self, err := os.Executable(); err == nil {
		if p := filepath.Join(filepath.Dir(self), bin); isExec(p) {
			return p, nil
		}
	}
	if dir := InstallDir(); dir != "" {
		if p := filepath.Join(dir, bin); isExec(p) {
			return p, nil
		}
	}
	if p, err := exec.LookPath(bin); err == nil {
		return p, nil
	}
	return "", fmt.Errorf("%s is not installed", bin)
}

func isExec(p string) bool {
	st, err := os.Stat(p)
	return err == nil && !st.IsDir() && st.Mode()&0o111 != 0
}

// Call sends one op and decodes its result into out (which may be nil).
//
// An op the provider did not declare is refused HERE, before anything is
// written: the capability list from the handshake is the whole vocabulary
// rook will use, so a provider cannot be tricked into interpreting a verb
// it never claimed.
func (c *Client) Call(ctx context.Context, op string, params, out any) error {
	c.mu.Lock()
	defer c.mu.Unlock()

	if err := c.startLocked(ctx); err != nil {
		return err
	}
	if !c.caps[op] {
		return fmt.Errorf("provider %s does not offer %s", c.Name, op)
	}
	res, err := c.callLocked(ctx, op, params)
	if err != nil {
		return err
	}
	if out == nil || len(res) == 0 {
		return nil
	}
	return json.Unmarshal(res, out)
}

// startLocked spawns and handshakes when there is no live process.
func (c *Client) startLocked(ctx context.Context) error {
	if c.cmd != nil && c.cmd.ProcessState == nil {
		return nil
	}
	path, err := c.resolve()
	if err != nil {
		return err
	}
	cmd := exec.Command(path)
	// The provider inherits the environment (it needs HOME to find its
	// own credentials) but never rook's stdin/stdout.
	cmd.Env = os.Environ()
	for k, v := range c.Env {
		cmd.Env = append(cmd.Env, fmt.Sprintf("ROOK_PROVIDER_%s_%s=%s",
			strings.ToUpper(c.Name), strings.ToUpper(k), v))
	}
	stdin, err := cmd.StdinPipe()
	if err != nil {
		return err
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return err
	}
	// stderr is the provider's log. It goes where rook's log goes, tagged,
	// so a provider that is failing says so somewhere a human will look.
	cmd.Stderr = prefixWriter{name: c.Name}
	if err := cmd.Start(); err != nil {
		return fmt.Errorf("start %s: %w", filepath.Base(path), err)
	}
	c.path, c.cmd, c.w, c.r = path, cmd, stdin, bufio.NewReaderSize(stdout, 1<<16)

	hctx, cancel := context.WithTimeout(ctx, handshakeTimeout)
	defer cancel()
	raw, err := c.callLocked(hctx, OpDescribe, nil)
	if err != nil {
		c.killLocked()
		return fmt.Errorf("%s handshake: %w", c.Name, err)
	}
	var d Describe
	if err := json.Unmarshal(raw, &d); err != nil {
		c.killLocked()
		return fmt.Errorf("%s handshake: %w", c.Name, err)
	}
	c.caps = map[string]bool{}
	for _, op := range d.Capabilities {
		c.caps[op] = true
	}
	return nil
}

// callLocked writes one frame and waits for its answer, or kills the
// process trying. Callers hold c.mu.
func (c *Client) callLocked(ctx context.Context, op string, params any) (json.RawMessage, error) {
	c.id++
	req := Request{V: Version, ID: c.id, Op: op}
	if params != nil {
		data, err := json.Marshal(params)
		if err != nil {
			return nil, err
		}
		req.Params = data
	}
	if dl, ok := ctx.Deadline(); ok {
		req.DeadlineMS = max(int(time.Until(dl).Milliseconds())-graceMS, 1)
	}
	frame, err := json.Marshal(req)
	if err != nil {
		return nil, err
	}
	if _, err := c.w.Write(append(frame, '\n')); err != nil {
		c.killLocked()
		return nil, fmt.Errorf("%s: %w", c.Name, err)
	}

	type answer struct {
		line []byte
		err  error
	}
	done := make(chan answer, 1)
	go func() {
		line, err := c.r.ReadBytes('\n')
		done <- answer{line, err}
	}()

	select {
	case <-ctx.Done():
		// It may still answer, into a pipe nobody is reading in order any
		// more. Kill rather than resynchronise — see the package comment.
		c.killLocked()
		return nil, fmt.Errorf("%s: %s timed out", c.Name, op)
	case a := <-done:
		if len(a.line) == 0 && a.err != nil {
			c.killLocked()
			if errors.Is(a.err, io.EOF) {
				return nil, fmt.Errorf("%s exited without answering %s", c.Name, op)
			}
			return nil, fmt.Errorf("%s: %w", c.Name, a.err)
		}
		if len(a.line) > maxFrame {
			c.killLocked()
			return nil, fmt.Errorf("%s: %s answered with %d bytes", c.Name, op, len(a.line))
		}
		var res Response
		if err := json.Unmarshal(a.line, &res); err != nil {
			c.killLocked()
			return nil, fmt.Errorf("%s: unreadable answer to %s: %w", c.Name, op, err)
		}
		if res.ID != req.ID {
			// Off by one is exactly the state the kill-on-timeout rule
			// exists to prevent; if it happens anyway, do not guess.
			c.killLocked()
			return nil, fmt.Errorf("%s: answer %d for request %d", c.Name, res.ID, req.ID)
		}
		if !res.OK {
			return nil, fmt.Errorf("%s: %s", c.Name, res.Error)
		}
		return res.Result, nil
	}
}

// Close stops the provider. Idempotent.
func (c *Client) Close() {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.killLocked()
}

func (c *Client) killLocked() {
	if c.cmd == nil {
		return
	}
	if c.w != nil {
		c.w.Close() // stdin close is the polite shutdown; the kill is the guarantee
	}
	if c.cmd.Process != nil {
		c.cmd.Process.Kill()
		go c.cmd.Wait() // reap without holding the lock
	}
	c.cmd, c.w, c.r, c.caps = nil, nil, nil, nil
}

// prefixWriter tags a provider's stderr so its lines are attributable in
// a log that carries everyone else's too.
type prefixWriter struct{ name string }

func (p prefixWriter) Write(b []byte) (int, error) {
	for _, line := range strings.Split(strings.TrimRight(string(b), "\n"), "\n") {
		if line != "" {
			fmt.Fprintf(os.Stderr, "provider %s: %s\n", p.name, line)
		}
	}
	return len(b), nil
}
