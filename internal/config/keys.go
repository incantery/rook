package config

import (
	"fmt"
	"strings"
)

// Verbs is the engine's prefix vocabulary (mux/src/keys.zig), in the
// config's spelling. The engine skips a line it cannot read; this is
// where a typo refuses to boot instead. TestVerbsMatchTheEngine holds
// the two lists together.
var Verbs = []string{
	"split-right", "split-down",
	"focus-left", "focus-down", "focus-up", "focus-right",
	"resize-left", "resize-down", "resize-up", "resize-right",
	"new-window", "next-window", "previous-window", "select-window",
	"last-pane", "zoom", "copy-mode", "kill-pane", "detach",
	"next-unread", "inspect",
	"home", "home-running", "home-needs", "home-find", "home-command",
	"last-space", "companion", "companion-pin",
	"sidebar", "pin", "pin-global",
	"popup",
}

// checkKeys refuses a [keys] entry the engine would skip: a key it
// cannot name, or a verb it does not know. An empty value unbinds.
func checkKeys(keys map[string]string) error {
	for k, spec := range keys {
		if !keyName(k) {
			return fmt.Errorf("[keys] %q: a key is one character or C-<letter>", k)
		}
		fields := strings.Fields(spec)
		if len(fields) == 0 {
			continue
		}
		if !known(fields[0]) {
			return fmt.Errorf("[keys] %s = %q: no verb %q (one of %s)", k, spec, fields[0], strings.Join(Verbs, ", "))
		}
		if (fields[0] == "popup" || fields[0] == "select-window") && len(fields) < 2 {
			return fmt.Errorf("[keys] %s = %q: %s needs an argument", k, spec, fields[0])
		}
	}
	return nil
}

func known(verb string) bool {
	for _, v := range Verbs {
		if v == verb {
			return true
		}
	}
	return false
}

func keyName(k string) bool {
	if len(k) == 1 {
		return k[0] >= 0x20 && k[0] < 0x7f
	}
	if len(k) == 3 && (k[0] == 'C' || k[0] == 'c') && k[1] == '-' {
		c := k[2] | 0x20
		return c >= 'a' && c <= 'z'
	}
	return strings.EqualFold(k, "space")
}
