package tracker

import (
	"encoding/json"
	"fmt"
	"strings"
	"time"
)

// PR is the pull request a branch resolved to on the code host. PRs are a
// code-host concept, not a tracker one — a Jira-tracked repo still merges
// through GitHub — so this lives beside the gh plumbing rather than behind
// the Tracker interface.
type PR struct {
	Number   int       `json:"number"`
	State    string    `json:"state"` // OPEN | CLOSED | MERGED
	URL      string    `json:"url"`
	MergedAt time.Time `json:"mergedAt"`
}

// PRStatus resolves the PR for a branch, run in the checkout so gh finds
// the repo from its remote. (nil, nil) means the branch has no PR — a
// normal answer, not an error. GitHub keeps the PR↔branch association
// even after the remote branch is auto-deleted post-merge.
func PRStatus(root, branch string) (*PR, error) {
	out, err := runGH(root, "pr", "view", branch, "--json", "number,state,url,mergedAt")
	if err != nil {
		if strings.Contains(err.Error(), "no pull requests found") {
			return nil, nil
		}
		return nil, err
	}
	return parsePR([]byte(out))
}

func parsePR(data []byte) (*PR, error) {
	var pr PR
	if err := json.Unmarshal(data, &pr); err != nil {
		return nil, fmt.Errorf("gh pr json: %w", err)
	}
	return &pr, nil
}
