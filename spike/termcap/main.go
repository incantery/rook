// termcap runs a program under a pty at a fixed geometry, feeds it a scripted
// sequence of inputs, and writes the raw output byte stream plus its geometry.
// That raw stream is the corpus the emulator diff (../termdiff) replays into
// both a candidate Go emulator and headless xterm.js.
//
// Reproducibility is the point: a recipe is a committed JSON file, so a
// capture can be regenerated and a diff rerun. The captured bytes ARE the
// input to both emulators, so where they came from does not bias the
// comparison — both parsers get identical bytes.
//
//	go run ./spike/termcap spike/termcap/recipes/nvim-edit.json
//
// writes spike/corpus/nvim-edit.raw and nvim-edit.meta.json
package main

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sync"
	"time"

	cpty "github.com/creack/pty"
)

type Recipe struct {
	Name      string            `json:"name"`
	Cols      int               `json:"cols"`
	Rows      int               `json:"rows"`
	Cmd       []string          `json:"cmd"`
	Env       map[string]string `json:"env"`
	Steps     []Step            `json:"steps"`
	CaptureMs int               `json:"captureMs"`
}

// Step: wait, then send. Send is a normal JSON string, so escapes come free —
// "i:wq\r" is insert / Escape / :wq / Enter.
type Step struct {
	WaitMs int    `json:"waitMs"`
	Send   string `json:"send"`
}

func main() {
	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr, "usage: termcap <recipe.json> [outdir]")
		os.Exit(2)
	}
	outDir := "spike/corpus"
	if len(os.Args) >= 3 {
		outDir = os.Args[2]
	}
	raw, err := os.ReadFile(os.Args[1])
	must(err)
	var r Recipe
	must(json.Unmarshal(raw, &r))
	if r.Cols == 0 || r.Rows == 0 || len(r.Cmd) == 0 {
		fatal("recipe needs cols, rows, and cmd")
	}
	if r.CaptureMs == 0 {
		r.CaptureMs = 4000
	}

	cmd := exec.Command(r.Cmd[0], r.Cmd[1:]...)
	cmd.Env = append(os.Environ(), "TERM=xterm-256color", "COLORTERM=truecolor")
	for k, v := range r.Env {
		cmd.Env = append(cmd.Env, k+"="+v)
	}
	ptmx, err := cpty.StartWithSize(cmd, &cpty.Winsize{Cols: uint16(r.Cols), Rows: uint16(r.Rows)})
	must(err)
	defer func() { _ = ptmx.Close() }()

	// Capture output, and answer the startup queries so a program that waits
	// on DA/DSR does not stall producing its interesting frames. The answers
	// are minimal on purpose (see answer): the corpus wants realistic OUTPUT,
	// not a faithful terminal — that faithfulness is exactly what termdiff is
	// measuring, and it must not be assumed by the tool that feeds it.
	var mu sync.Mutex
	var out []byte
	done := make(chan struct{})
	go func() {
		buf := make([]byte, 32*1024)
		for {
			n, rerr := ptmx.Read(buf)
			if n > 0 {
				mu.Lock()
				out = append(out, buf[:n]...)
				mu.Unlock()
				if reply := answer(buf[:n]); len(reply) > 0 {
					_, _ = ptmx.Write(reply)
				}
			}
			if rerr != nil {
				close(done)
				return
			}
		}
	}()

	start := time.Now()
	for _, s := range r.Steps {
		time.Sleep(time.Duration(s.WaitMs) * time.Millisecond)
		if s.Send != "" {
			_, _ = ptmx.Write([]byte(s.Send))
		}
	}
	if rem := time.Duration(r.CaptureMs)*time.Millisecond - time.Since(start); rem > 0 {
		time.Sleep(rem)
	}

	// stop the program; the reader closes `done` on the resulting EOF
	if cmd.Process != nil {
		_ = cmd.Process.Signal(os.Interrupt)
		time.Sleep(150 * time.Millisecond)
		_ = cmd.Process.Kill()
	}
	_ = ptmx.Close()
	select {
	case <-done:
	case <-time.After(2 * time.Second):
	}

	mu.Lock()
	captured := out
	mu.Unlock()

	must(os.MkdirAll(outDir, 0o755))
	rawPath := filepath.Join(outDir, r.Name+".raw")
	must(os.WriteFile(rawPath, captured, 0o644))
	meta, _ := json.MarshalIndent(map[string]any{
		"name":  r.Name,
		"cols":  r.Cols,
		"rows":  r.Rows,
		"cmd":   r.Cmd,
		"bytes": len(captured),
	}, "", "  ")
	must(os.WriteFile(filepath.Join(outDir, r.Name+".meta.json"), meta, 0o644))
	fmt.Printf("%s: %d bytes at %dx%d → %s\n", r.Name, len(captured), r.Cols, r.Rows, rawPath)
}

// answer replies to the queries a program asks on startup, minimally, so it
// does not stall. DA1, DA2, DSR-5, and DECRQM (reported unrecognized). NOT a
// terminal emulator — no cursor, no modes; termdiff is what measures whether a
// real one agrees with xterm.js, so this must not pretend to be one.
var (
	reDA1    = regexp.MustCompile(`\x1b\[(?:0)?c`)
	reDA2    = regexp.MustCompile(`\x1b\[>\d*(?:;\d+)*c`)
	reDSR5   = regexp.MustCompile(`\x1b\[5n`)
	reDECRQM = regexp.MustCompile(`\x1b\[\?(\d+)\$p`)
)

func answer(b []byte) []byte {
	var out []byte
	if reDA1.Match(b) {
		out = append(out, []byte("\x1b[?1;2c")...)
	}
	if reDA2.Match(b) {
		out = append(out, []byte("\x1b[>0;276;0c")...)
	}
	if reDSR5.Match(b) {
		out = append(out, []byte("\x1b[0n")...)
	}
	for _, m := range reDECRQM.FindAllSubmatch(b, -1) {
		out = append(out, []byte("\x1b[?"+string(m[1])+";0$y")...)
	}
	return out
}

func must(err error) {
	if err != nil {
		fatal(err.Error())
	}
}

func fatal(msg string) {
	fmt.Fprintln(os.Stderr, "termcap:", msg)
	os.Exit(1)
}
