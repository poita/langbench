package protocol

import (
	"bytes"
	"os"
	"strings"
	"testing"
)

func run(t *testing.T, in string) string {
	t.Helper()
	var out bytes.Buffer
	if err := Run(strings.NewReader(in), &out); err != nil {
		t.Fatal(err)
	}
	return out.String()
}

func TestGolden(t *testing.T) {
	for _, name := range []string{"spec_examples", "simulate_example"} {
		in, err := os.ReadFile("../testdata/" + name + ".in")
		if err != nil {
			t.Fatal(err)
		}
		want, err := os.ReadFile("../testdata/" + name + ".out")
		if err != nil {
			t.Fatal(err)
		}
		if got := run(t, string(in)); strings.TrimRight(got, "\n") != strings.TrimRight(string(want), "\n") {
			t.Errorf("%s:\ngot:\n%s\nwant:\n%s", name, got, want)
		}
	}
}

func TestCommandErrors(t *testing.T) {
	bad := []string{
		"sha256 ABCD", "sha256 abc", "sha256", "sha256  ", "sha256 00 00", "frobnicate 1",
		" sha256 -", "sha256\t-", "simulate now", "end", "endpoint", "secret whsec_",
		"sign abc id 007 -",
	}
	got := strings.Split(strings.TrimRight(run(t, strings.Join(bad, "\n")), "\n"), "\n")
	if len(got) != len(bad) {
		t.Fatalf("got %d lines for %d commands: %q", len(got), len(bad), got)
	}
	for i, line := range got {
		if line != "error" {
			t.Errorf("%q -> %q, want error", bad[i], line)
		}
	}
}

func TestBlankLinesAndMissingNewline(t *testing.T) {
	if got := run(t, "\n   \nsha256 -\n\nsha256 616263"); got !=
		"e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855\n"+
			"ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad\n" {
		t.Errorf("got %q", got)
	}
}

func TestLongLine(t *testing.T) {
	payload := strings.Repeat("61", 70000)
	got := run(t, "sha256 "+payload+"\n")
	if len(got) != 65 {
		t.Errorf("got %q", got)
	}
}

func TestSimulateErrors(t *testing.T) {
	ep := "endpoint a c2VjcmV0 * 200"
	tests := map[string]string{
		"no endpoints":          "simulate\nend\n",
		"eof":                   "simulate\n" + ep + "\n",
		"dup endpoint":          "simulate\n" + ep + "\n" + ep + "\nend\n",
		"endpoint after event":  "simulate\n" + ep + "\nevent e 0 t -\nendpoint b c2VjcmV0 * 200\nend\n",
		"nested simulate":       "simulate\n" + ep + "\nsimulate\nend\n",
		"bad script":            "simulate\nendpoint a c2VjcmV0 * 099\nend\n",
		"bad event type":        "simulate\n" + ep + "\nevent e 0 t/x -\nend\n",
		"trailing space on end": "simulate\n" + ep + "\nend \nend\n",
	}
	for name, in := range tests {
		if got := run(t, in); got != "error\n" {
			t.Errorf("%s: got %q", name, got)
		}
	}
	// After a bad block the next command still runs.
	if got := run(t, "simulate\nbogus\nsha256 -\nend\nsha256 -\n"); !strings.HasPrefix(got, "error\ne3b0") || strings.Count(got, "\n") != 2 {
		t.Errorf("recovery: got %q", got)
	}
}

func TestSimulateEmpty(t *testing.T) {
	if got := run(t, "simulate\n\nendpoint a c2VjcmV0 * 200\n\nend\n"); got != "sim 0 0\n" {
		t.Errorf("got %q", got)
	}
}
