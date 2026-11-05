package driver_test

import (
	"os"
	"path/filepath"
	"testing"

	"linalg/internal/driver"
)

func write(t *testing.T, dir, name, content string) {
	t.Helper()
	if err := os.WriteFile(filepath.Join(dir, name), []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
}

func TestParseScript(t *testing.T) {
	cmds := driver.ParseScript("# c\n\n  add  a.mtx\tb.mtx \n\t# x\ndet a.mtx\r\n")
	if len(cmds) != 2 || cmds[0].Op != "add" || len(cmds[0].Args) != 2 || cmds[1].Op != "det" {
		t.Fatalf("cmds = %+v", cmds)
	}
}

func TestRunWorkedExample(t *testing.T) {
	in, out := t.TempDir(), t.TempDir()
	write(t, in, "commands.txt", "# two by two\nadd a.mtx b.mtx\n\ndet a.mtx\nchol s.mtx\nchol r.mtx\nbogus a.mtx\n")
	write(t, in, "a.mtx", "%%MatrixMarket matrix array real general\n2 2\n1.0\n3.0\n2.0\n4.0\n")
	write(t, in, "b.mtx", "%%MatrixMarket matrix coordinate real general\n2 2 2\n1 1 0.5\n2 2 -1.5\n")
	write(t, in, "s.mtx", "%%MatrixMarket matrix array real symmetric\n2 2\n4.0\n2.0\n5.0\n")
	write(t, in, "r.mtx", "%%MatrixMarket matrix array real general\n2 3\n1\n2\n3\n4\n5\n6\n")
	if err := driver.Run(in, out); err != nil {
		t.Fatal(err)
	}
	want := map[string]string{
		"001_add.mtx":    "%%MatrixMarket matrix array real general\n2 2\n1.5000000000e+00\n3.0000000000e+00\n2.0000000000e+00\n2.5000000000e+00\n",
		"002_det.mtx":    "%%MatrixMarket matrix array real general\n1 1\n-2.0000000000e+00\n",
		"003_chol_L.mtx": "%%MatrixMarket matrix array real general\n2 2\n2.0000000000e+00\n1.0000000000e+00\n0.0000000000e+00\n2.0000000000e+00\n",
		"004_error.txt":  "not_square\n",
		"005_error.txt":  "invalid_input\n",
	}
	entries, err := os.ReadDir(out)
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != len(want) {
		t.Errorf("%d files written, want %d", len(entries), len(want))
	}
	for name, content := range want {
		got, err := os.ReadFile(filepath.Join(out, name))
		if err != nil {
			t.Errorf("%s: %v", name, err)
		} else if string(got) != content {
			t.Errorf("%s = %q, want %q", name, got, content)
		}
	}
}
