package host

import "testing"

func TestParseReviewHunks(t *testing.T) {
	// two files, an edit and a brand-new file (--- /dev/null)
	diff := []byte(`diff --git a/a.txt b/a.txt
index 111..222 100644
--- a/a.txt
+++ b/a.txt
@@ -1,3 +1,4 @@
 keep
-old
+new
+extra
@@ -10,2 +11,2 @@ func foo()
-gone
+here
diff --git a/new.txt b/new.txt
new file mode 100644
index 000..333
--- /dev/null
+++ b/new.txt
@@ -0,0 +1,2 @@
+alpha
+beta
`)
	hunks := parseReviewHunks(diff)
	if len(hunks) != 3 {
		t.Fatalf("want 3 hunks, got %d: %+v", len(hunks), hunks)
	}
	if hunks[0].path != "a.txt" || hunks[0].newStart != 1 || hunks[0].newCount != 4 {
		t.Errorf("hunk0 = %+v", hunks[0])
	}
	// body carries the +/- and context lines, not the @@ header
	if want := " keep\n-old\n+new\n+extra"; hunks[0].body != want {
		t.Errorf("hunk0 body = %q, want %q", hunks[0].body, want)
	}
	if hunks[1].path != "a.txt" || hunks[1].newStart != 11 {
		t.Errorf("hunk1 = %+v", hunks[1])
	}
	// the added file resolves its path from +++ (not /dev/null)
	if hunks[2].path != "new.txt" || hunks[2].newStart != 1 || hunks[2].newCount != 2 {
		t.Errorf("hunk2 = %+v", hunks[2])
	}
}

func TestReviewBlocking(t *testing.T) {
	cases := map[string]bool{
		reviewStateProposed: true,  // unreviewed blocks
		reviewStateRejected: true,  // wants change blocks
		reviewStatePending:  true,  // conversation open blocks
		reviewStateApproved: false, // the two cleared verdicts
		reviewStateDeferred: false,
	}
	for state, want := range cases {
		if got := reviewBlocking(state); got != want {
			t.Errorf("reviewBlocking(%q) = %v, want %v", state, got, want)
		}
	}
}

func TestGitDiffPath(t *testing.T) {
	for in, want := range map[string]string{
		"a/foo.go":  "foo.go",
		"b/foo.go":  "foo.go",
		"/dev/null": "",
		"weird":     "weird",
	} {
		if got := gitDiffPath(in); got != want {
			t.Errorf("gitDiffPath(%q) = %q, want %q", in, got, want)
		}
	}
}
