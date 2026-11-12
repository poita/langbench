package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestRun(t *testing.T) {
	in := "19970902T090000 FREQ=WEEKLY;INTERVAL=2;WKST=MO;BYDAY=TU,SU;COUNT=4 4\n" +
		"20260101T000000 FREQ=YEARLY;BYMONTH=2;BYMONTHDAY=30;COUNT=5 10"
	want := "19970902T090000 19970907T090000 19970916T090000 19970921T090000\n\n"
	var out strings.Builder
	if err := run(strings.NewReader(in), &out); err != nil {
		t.Fatal(err)
	}
	if out.String() != want {
		t.Errorf("got %q, want %q", out.String(), want)
	}
}

func TestRunErrors(t *testing.T) {
	for _, in := range []string{"garbage\n", "19970902T090000 FREQ=NOPE 3\n", "19970902T090000 FREQ=DAILY 0\n"} {
		if err := run(strings.NewReader(in), &strings.Builder{}); err == nil {
			t.Errorf("run(%q) succeeded, want error", in)
		}
	}
}

// TestCorpus runs the problem's test corpus when it is present next to the
// project (problems/rrule/tests).
func TestCorpus(t *testing.T) {
	dir := filepath.Join("..", "..", "..", "problems", "rrule", "tests")
	files, _ := filepath.Glob(filepath.Join(dir, "*.in"))
	if len(files) == 0 {
		t.Skip("corpus not found")
	}
	for _, f := range files {
		t.Run(filepath.Base(f), func(t *testing.T) {
			in, err := os.Open(f)
			if err != nil {
				t.Fatal(err)
			}
			defer in.Close()
			want, err := os.ReadFile(strings.TrimSuffix(f, ".in") + ".out")
			if err != nil {
				t.Fatal(err)
			}
			var out strings.Builder
			if err := run(in, &out); err != nil {
				t.Fatal(err)
			}
			if norm(out.String()) != norm(string(want)) {
				t.Error("output mismatch")
			}
		})
	}
}

func norm(s string) string {
	lines := strings.Split(s, "\n")
	for i := range lines {
		lines[i] = strings.TrimRight(lines[i], " \t\r")
	}
	return strings.TrimRight(strings.Join(lines, "\n"), "\n")
}
