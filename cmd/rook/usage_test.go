package main

import (
	"strings"
	"testing"
)

// The usage text and the verb table are two copies of one fact —
// which words the front door hands the engine — so a verb added to
// one and not the other is the kind of drift a test should catch.
func TestUsageNamesEveryEngineVerb(t *testing.T) {
	for verb := range muxVerbs {
		if verb == "server" {
			continue // the daemon's own spelling; nobody types it
		}
		if !strings.Contains(usage, verb) {
			t.Errorf("engine verb %q is not in the usage text", verb)
		}
	}
}

// The skill teaches the verbs an agent needs, and only ones that
// exist: a skill that names a verb the front door refuses is worse
// than none.
func TestSkillTeachesRealVerbs(t *testing.T) {
	for _, verb := range []string{"read", "send", "run", "key", "wait", "split", "window", "focus", "jump", "close-pane", "state", "watch", "blocks"} {
		if !muxVerbs[verb] {
			t.Errorf("skill verb %q is not an engine verb", verb)
		}
		if !strings.Contains(skill, "rook "+verb) {
			t.Errorf("skill does not teach %q", verb)
		}
	}
	if !strings.Contains(skill, "ROOK_MUX_PANE") {
		t.Error("skill does not say how to tell you are inside rook")
	}
	if !strings.Contains(usage, "rook --skill") {
		t.Error("usage does not point an AI at the skill")
	}
}
