// The membrane prints its own bill: every model call's cost folds into
// the shared spend ledger the status bridges publish. One recorder,
// process-wide — the watch loop, the screen-watcher, and the panel's
// draft actions all spend, and the ledger file wants one writer at a
// time.
package main

import (
	"sync"
	"time"

	"github.com/incantery/rook/plugins/internal/spendfile"
)

var spendMu sync.Mutex

func recordSpend(usd float64) {
	if usd <= 0 {
		return
	}
	spendMu.Lock()
	defer spendMu.Unlock()
	_ = spendfile.Add(spendfile.DefaultPath(), time.Now(), usd)
}
