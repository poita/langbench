package cardgame

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const miniDB = `
(card TST-001 (name "Bolt") (type rite) (cost 1) (keywords swift)
  (resolve (targets (any)) (damage 2 (t 1))))
(card TST-002 (name "Grunt") (type unit) (cost 1) (body 2 2))
`

func writeDB(t *testing.T, content string) string {
	t.Helper()
	p := filepath.Join(t.TempDir(), "db.spire")
	if err := os.WriteFile(p, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
	return p
}

func run(t *testing.T, src string) string {
	t.Helper()
	var out bytes.Buffer
	if err := RunString(src, &out); err != nil {
		t.Fatal(err)
	}
	return out.String()
}

func TestFatalKinds(t *testing.T) {
	db := writeDB(t, miniDB)
	bad := writeDB(t, "(card")
	cases := []struct{ src, want string }{
		{"SEED 1\nSTART\n", "FATAL bad-setup\n"},
		{"CARDS " + db + "\nSEED 1\n", "FATAL bad-setup\n"},
		{"CARDS /nonexistent/x\nSEED 1\nSTART\n", "FATAL bad-database\n"},
		{"CARDS " + bad + "\nSEED 1\nSTART\n", "FATAL bad-database\n"},
		{"CARDS " + db + "\nSEED 1\nDECK A ZZZ-999\nSTART\n", "FATAL unknown-card\n"},
		// bad-setup outranks bad-database.
		{"CARDS /nonexistent/x\nSEED 1\nSEED 2\nSTART\n", "FATAL bad-setup\n"},
	}
	for _, c := range cases {
		if got := run(t, c.src); got != c.want {
			t.Errorf("%q: got %q want %q", c.src, got, c.want)
		}
	}
}

func TestPlaysAMatch(t *testing.T) {
	db := writeDB(t, miniDB)
	src := "CARDS " + db + `
SEED 1
SPIRE 2
OPENING 0
SHUFFLE off
HAND A TST-001
# comments count towards line numbers
START
A PLAY 1 B
A PASS
B PASS
A PASS
`
	got := run(t, src)
	want := `1 GAME-START A
2 TURN 1 A
3 PHASE dawn
4 EMBER A 1 1
5 EMBER B 0 0
6 PHASE draw
7 PHASE main1
8 PLAY A ~1 #1 TST-001 B
9 PAY A ember 1
10 PASS A
11 PASS B
12 RESOLVE ~1
13 DAMAGE #1 B 2
14 SPIRE B -2 0
15 SPENT #1 TST-001
16 LOSE B spire
17 RESULT A spire
ERR 12 game-over
`
	if got != want {
		t.Errorf("got:\n%s\nwant:\n%s", got, want)
	}
}

func TestCRLFAndPending(t *testing.T) {
	db := writeDB(t, miniDB)
	got := run(t, "CARDS "+db+"\r\nSEED 1\r\nOPENING 0\r\nSTART\r\nDUMP\r\nDUMP extra\r\n")
	if !strings.Contains(got, "STATE BEGIN") || !strings.Contains(got, "ERR 6 bad-syntax") ||
		!strings.HasSuffix(got, "RESULT pending none\n") {
		t.Errorf("unexpected output:\n%s", got)
	}
}

// TestProblemSuite replays every case of the problem's test directory when
// it is available next to this project, comparing output exactly (modulo
// trailing whitespace).
func TestProblemSuite(t *testing.T) {
	root := filepath.Join("..", "problems", "cardgame")
	files, _ := filepath.Glob(filepath.Join(root, "tests", "*.in"))
	if len(files) == 0 {
		t.Skip("problem test suite not present")
	}
	wd, _ := os.Getwd()
	if err := os.Chdir(root); err != nil {
		t.Fatal(err)
	}
	defer os.Chdir(wd)
	norm := func(s string) string {
		lines := strings.Split(strings.TrimRight(s, "\n"), "\n")
		for i := range lines {
			lines[i] = strings.TrimRight(lines[i], " \t\r")
		}
		return strings.Join(lines, "\n")
	}
	for _, f := range files {
		name := filepath.Base(f)
		in, _ := os.ReadFile(filepath.Join(wd, f))
		want, err := os.ReadFile(filepath.Join(wd, strings.TrimSuffix(f, ".in")+".out"))
		if err != nil {
			t.Fatal(err)
		}
		var out bytes.Buffer
		if err := RunString(string(in), &out); err != nil {
			t.Fatal(err)
		}
		if norm(out.String()) != norm(string(want)) {
			t.Errorf("%s: output differs", name)
		}
	}
}
