package gitrepo_test

import (
	"bytes"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"gitrepo"
	"gitrepo/query"
)

// TestCorpus replays the example repositories of the problem statement, when
// they are present next to this project (problems/gitrepo/tests), and compares
// every command's output with the recorded one.
func TestCorpus(t *testing.T) {
	root := filepath.Join("..", "problems", "gitrepo", "tests")
	cases, err := filepath.Glob(filepath.Join(root, "*", "input", "commands.txt"))
	if err != nil || len(cases) == 0 {
		t.Skip("no corpus found at " + root)
	}
	for _, cmdFile := range cases {
		input := filepath.Dir(cmdFile)
		name := filepath.Base(filepath.Dir(input))
		t.Run(name, func(t *testing.T) {
			raw, err := os.ReadFile(cmdFile)
			if err != nil {
				t.Fatal(err)
			}
			lines := strings.Split(strings.TrimSuffix(string(raw), "\n"), "\n")
			repo, err := gitrepo.Open(filepath.Join(input, "repo"))
			if err != nil {
				t.Fatal(err)
			}
			for i, line := range lines {
				want, err := os.ReadFile(filepath.Join(filepath.Dir(input), "expected", fileName(i+1)))
				if err != nil {
					t.Fatal(err)
				}
				got, err := query.Execute(repo, line)
				if err != nil {
					got = []byte(query.ErrorOutput)
				}
				if !bytes.Equal(trim(got), trim(want)) {
					t.Errorf("line %d %q:\ngot  %q\nwant %q", i+1, line, clip(got), clip(want))
				}
			}
		})
	}
}

func fileName(k int) string { return fmt.Sprintf("%03d.out", k) }

func trim(b []byte) []byte { return bytes.TrimRight(b, "\n ") }

func clip(b []byte) []byte {
	if len(b) > 200 {
		return b[:200]
	}
	return b
}
