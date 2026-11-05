package script

import (
	"bytes"
	"os"
	"path/filepath"
	"testing"
)

// TestProblemSuite runs the suite shipped with the problem statement when it
// is available next to the project; it is skipped otherwise.
func TestProblemSuite(t *testing.T) {
	files, _ := filepath.Glob("../../../problems/textbuffer/tests/*.in")
	if len(files) == 0 {
		t.Skip("problem test suite not found")
	}
	for _, in := range files {
		name := filepath.Base(in)
		if len(name) > 3 && name[:3] >= "030" {
			continue // large inputs are exercised by run_tests.py
		}
		t.Run(name, func(t *testing.T) {
			input, _ := os.ReadFile(in)
			want, err := os.ReadFile(in[:len(in)-3] + ".out")
			if err != nil {
				t.Skip("no expected output")
			}
			var out bytes.Buffer
			if err := Run(input, &out); err != nil {
				t.Fatal(err)
			}
			if !bytes.Equal(bytes.TrimRight(out.Bytes(), "\n"), bytes.TrimRight(want, "\n")) {
				t.Error("output differs from expected")
			}
		})
	}
}
