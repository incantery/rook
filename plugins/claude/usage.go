// The usage collector: every few minutes, ask the claude CLI itself
// how much of the subscription has been spent (`claude /usage -p`) and
// publish the parsed report to the shared usage file for the status
// bridges to fold. The CLI is the ONLY honest source here — it knows
// the account's rate-limit windows; rook's transcripts do not.
package main

import (
	"context"
	"os/exec"
	"time"

	"github.com/incantery/rook/plugins/internal/usagefile"
)

// usageLoop runs until the process dies. A missing binary, a
// non-subscription account, or a hung CLI are all quiet misses — the
// readers age the file out and the phone simply shows no usage.
func usageLoop(every time.Duration, path string) {
	for {
		collectUsage(path)
		time.Sleep(every)
	}
}

func collectUsage(path string) {
	bin, err := exec.LookPath("claude")
	if err != nil {
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()
	out, err := exec.CommandContext(ctx, bin, "/usage", "-p").Output()
	if err != nil {
		return
	}
	if u, ok := usagefile.Parse(string(out), time.Now()); ok {
		_ = usagefile.Write(path, u)
	}
}
