package sessions

import "testing"

// Footers below are verbatim captures from real Claude Code panes
// (2026-08-19), one per state.
func TestClassify(t *testing.T) {
	cases := []struct {
		name    string
		content string
		want    AgentState
	}{
		{"working spinner bare", "❯ Run this exact shell command: sleep 20 && echo done\n✳ Billowing…\n  ⎿  Tip: Name your conversations\n❯ \n  Fable 5 ░░░░ 4%", StateWorking},
		{"working spinner with stats", "✳ Billowing… (9s · ↓ 159 tokens)\n❯ \n  ⏵⏵ auto mode on · 1 shell", StateWorking},
		{"working esc to interrupt", "· Combobulating… (1m 19s · ↓ 3.1k tokens)\nsome output (esc to interrupt)\n❯ ", StateWorking},
		{"waiting trust dialog", " Claude Code'll be able to read, edit, and execute files here.\n ❯ 1. Yes, I trust this folder\n   2. No, exit\n Enter to confirm · Esc to cancel", StateWaiting},
		{"waiting outranks working", "✳ Billowing…\nDo you want to proceed?\n❯ 1. Yes", StateWaiting},
		{"done idle prompt", "                ● high · /effort\n❯ Try \"how does <filepath> work?\"\n  Fable 5 ░░░░ 0%\n  ⏵⏵ auto mode on (shift+tab to cycle)", StateDone},
		{"done past-tense is not working", "✻ Brewed for 5s · 1 shell still running\n❯ \n  ⏵⏵ auto mode on", StateDone},
	}
	for _, c := range cases {
		if got := Classify(c.content); got != c.want {
			t.Errorf("%s: Classify = %v, want %v", c.name, got, c.want)
		}
	}
}

func TestIsAgentPane(t *testing.T) {
	cases := []struct {
		cmd, title string
		want       bool
	}{
		{"2.1.236", "✳ Rook CLI hello world", true},
		{"claude", "whatever", true},
		{"node", "✳ Claude Code", true},
		{"zsh", "Seths-MacBook-Pro-2.local", false},
		{"nvim", "main.go", false},
	}
	for _, c := range cases {
		if got := IsAgentPane(c.cmd, c.title); got != c.want {
			t.Errorf("IsAgentPane(%q, %q) = %v", c.cmd, c.title, got)
		}
	}
}

func TestStateMergePriority(t *testing.T) {
	if StateDone.merge(StateWorking) != StateWorking {
		t.Error("working must outrank done")
	}
	if StateWorking.merge(StateWaiting) != StateWaiting {
		t.Error("waiting must outrank working")
	}
	if StateWaiting.merge(StateDone) != StateWaiting {
		t.Error("merge must keep the higher state")
	}
}
