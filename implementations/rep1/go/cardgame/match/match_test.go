package match

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/spiremark/cardgame/cards"
	"github.com/spiremark/cardgame/engine"
)

func normalise(s string) string {
	lines := strings.Split(strings.ReplaceAll(s, "\r\n", "\n"), "\n")
	for i, l := range lines {
		lines[i] = strings.TrimRight(l, " \t")
	}
	return strings.TrimRight(strings.Join(lines, "\n"), "\n")
}

func fixtureLoader(t *testing.T) func(string) (*cards.Database, error) {
	t.Helper()
	db, err := cards.Load("../testdata/mini.spire")
	if err != nil {
		t.Fatal(err)
	}
	return func(string) (*cards.Database, error) { return db, nil }
}

func run(t *testing.T, input string) string {
	t.Helper()
	var out bytes.Buffer
	if err := Run(strings.NewReader(input), &out, Options{Load: fixtureLoader(t)}); err != nil {
		t.Fatal(err)
	}
	return out.String()
}

// TestGolden runs the worked examples of the specification (testdata/golden).
func TestGolden(t *testing.T) {
	inputs, err := filepath.Glob("../testdata/golden/*.in")
	if err != nil || len(inputs) == 0 {
		t.Fatalf("no golden inputs: %v", err)
	}
	for _, in := range inputs {
		name := strings.TrimSuffix(filepath.Base(in), ".in")
		t.Run(name, func(t *testing.T) {
			src, _ := os.ReadFile(in)
			want, _ := os.ReadFile(strings.TrimSuffix(in, ".in") + ".out")
			if got := run(t, string(src)); normalise(got) != normalise(string(want)) {
				t.Errorf("output differs\n--- got\n%s\n--- want\n%s", got, want)
			}
		})
	}
}

// TestConformanceSuite runs every test of the original problem directory when
// it is present next to the project (it is skipped otherwise).
func TestConformanceSuite(t *testing.T) {
	dir := os.Getenv("CARDGAME_PROBLEM_DIR")
	if dir == "" {
		dir = "../../problems/cardgame"
	}
	inputs, _ := filepath.Glob(filepath.Join(dir, "tests", "*.in"))
	if len(inputs) == 0 {
		t.Skip("problem directory not found; set CARDGAME_PROBLEM_DIR")
	}
	abs, _ := filepath.Abs(dir)
	t.Chdir(abs)
	for _, in := range inputs {
		in := in
		t.Run(strings.TrimSuffix(filepath.Base(in), ".in"), func(t *testing.T) {
			src, _ := os.ReadFile(in)
			want, _ := os.ReadFile(strings.TrimSuffix(in, ".in") + ".out")
			var out bytes.Buffer
			if err := Run(bytes.NewReader(src), &out, Options{}); err != nil {
				t.Fatal(err)
			}
			if normalise(out.String()) != normalise(string(want)) {
				t.Errorf("output differs from %s", filepath.Base(in))
			}
		})
	}
}

func TestFatalLines(t *testing.T) {
	cases := map[string]string{
		"missing CARDS":    "SEED 1\nSTART\n",
		"missing SEED":     "CARDS x\nSTART\n",
		"missing START":    "CARDS x\nSEED 1\n",
		"duplicate SEED":   "CARDS x\nSEED 1\nSEED 2\nSTART\n",
		"negative seed":    "CARDS x\nSEED -1\nSTART\n",
		"huge spire":       "CARDS x\nSEED 1\nSPIRE 1000001\nSTART\n",
		"unknown word":     "CARDS x\nSEED 1\nBOGUS\nSTART\n",
		"START with arg":   "CARDS x\nSEED 1\nSTART now\n",
		"bad trace":        "CARDS x\nSEED 1\nTRACE all\nSTART\n",
		"entry count":      "CARDS x\nSEED 1\nDECK A CIN-001*1001\nSTART\n",
		"entry no id":      "CARDS x\nSEED 1\nDECK A *3\nSTART\n",
		"deck without ids": "CARDS x\nSEED 1\nDECK A\nSTART\n",
		"cap twice":        "CARDS x\nSEED 1\nCAP A 1\nCAP A 2\nSTART\n",
	}
	for name, in := range cases {
		if got := run(t, in); got != "FATAL bad-setup\n" {
			t.Errorf("%s: got %q", name, got)
		}
	}
	if got := run(t, "CARDS x\nSEED 1\nDECK A NOP-000\nSTART\n"); got != "FATAL unknown-card\n" {
		t.Errorf("unknown card: %q", got)
	}
	var out bytes.Buffer
	failing := Options{Load: func(string) (*cards.Database, error) { return nil, cards.ErrBadDatabase }}
	if err := Run(strings.NewReader("CARDS x\nSEED 1\nSTART\n"), &out, failing); err != nil {
		t.Fatal(err)
	}
	if out.String() != "FATAL bad-database\n" {
		t.Errorf("bad database: %q", out.String())
	}
}

func TestSetupDefaultsAndEntries(t *testing.T) {
	lines := splitLines("# comment\n\nCARDS data/x.spire\nSEED 007\nCAP B 3\nDECK A CIN-001*2 TID-001\nDECK A TOK-001\nFIRST B\nSHUFFLE off\nSTART\nDUMP\n")
	s, err := ParseSetup(lines)
	if err != nil {
		t.Fatal(err)
	}
	c := s.Config
	if s.CardsPath != "data/x.spire" || c.Seed != 7 || c.Cap[engine.B] != 3 || c.First != engine.B || c.Shuffle {
		t.Errorf("config: %+v", s)
	}
	if c.Spire != 25 || c.Opening != 5 || c.MaxCap != 10 || c.HandMax != 7 || c.TurnLimit != 200 {
		t.Errorf("defaults: %+v", c)
	}
	if got := c.Deck[engine.A]; len(got) != 3 || got[0].Count != 2 || got[2].ID != "TOK-001" {
		t.Errorf("deck: %+v", got)
	}
	if s.ScriptStart != 10 {
		t.Errorf("script start %d", s.ScriptStart)
	}
}

func TestParseAction(t *testing.T) {
	good := []string{
		"A PASS", "B CONCEDE", "A PLAY 1", "A PLAY 007 A B #3 ~2", "A ACT #4 2", "A ACT #4 1 #5",
		"A ATTACK", "A ATTACK #1 #2", "B BLOCK", "B BLOCK #1:#2 #3:#2",
	}
	for _, s := range good {
		if _, ok := ParseAction(strings.Fields(s)); !ok {
			t.Errorf("%q should parse", s)
		}
	}
	bad := []string{
		"X PASS", "A", "A JUMP", "A PASS 1", "A PLAY", "A PLAY -1", "A PLAY +1", "A PLAY 1 C",
		"A PLAY 1 #", "A PLAY 99999999999999999999", "A ACT 4 1", "A ACT #4", "A ATTACK 1",
		"B BLOCK #1", "B BLOCK #1:", "B BLOCK #1:#2:#3",
	}
	for _, s := range bad {
		if _, ok := ParseAction(strings.Fields(s)); ok {
			t.Errorf("%q should not parse", s)
		}
	}
}

func TestSyntaxErrorsAndDirectives(t *testing.T) {
	in := "CARDS x\nSEED 1\nOPENING 0\nSHUFFLE off\nSTART\nDUMP x\nCARD\nCARD a b\nCARD CIN-001\n# note\nHELLO\nA PASS extra\n"
	out := run(t, in)
	for _, want := range []string{"ERR 6 bad-syntax", "ERR 7 bad-syntax", "ERR 8 bad-syntax", "ERR 11 bad-syntax", "ERR 12 bad-syntax", "CARD BEGIN CIN-001"} {
		if !strings.Contains(out, want) {
			t.Errorf("missing %q in\n%s", want, out)
		}
	}
	if !strings.HasSuffix(out, "RESULT pending none\n") {
		t.Errorf("output must end with the result line:\n%s", out)
	}
}

func TestCRLFInput(t *testing.T) {
	lf := "CARDS x\nSEED 1\nOPENING 0\nSHUFFLE off\nSTART\nVAULT\n"
	crlf := strings.ReplaceAll(lf, "\n", "\r\n")
	if run(t, lf) != run(t, crlf) {
		t.Error("CRLF input must behave like LF input")
	}
}

func TestTrace(t *testing.T) {
	in := "CARDS x\nSEED 1\nOPENING 0\nSHUFFLE off\nTRACE legal\nHAND A CIN-003\nSTART\nA PASS\nA PASS\n"
	out := run(t, in)
	if strings.Count(out, "LEGAL BEGIN B priority") != 1 || strings.Contains(out, "ERR 9") == false {
		t.Errorf("unexpected trace output:\n%s", out)
	}
}
