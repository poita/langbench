package driver

import (
	"os"
	"path/filepath"
	"reflect"
	"sort"
	"testing"
)

func write(t *testing.T, dir, name, content string) {
	t.Helper()
	if err := os.WriteFile(filepath.Join(dir, name), []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
}

func TestParseScript(t *testing.T) {
	cmds := ParseScript("  # c\n\n\tadd  a.mtx\tb.mtx \r\n#x\ndet a.mtx\n")
	want := []Command{{"add", []string{"a.mtx", "b.mtx"}}, {"det", []string{"a.mtx"}}}
	if !reflect.DeepEqual(cmds, want) {
		t.Errorf("got %v", cmds)
	}
}

// TestRunWorkedExample is the whole-run example of the specification.
func TestRunWorkedExample(t *testing.T) {
	in, out := t.TempDir(), t.TempDir()
	write(t, in, "commands.txt", "# a two by two example\nadd a.mtx b.mtx\n\ndet a.mtx\nchol s.mtx\nchol r.mtx\n")
	write(t, in, "a.mtx", "%%MatrixMarket matrix array real general\n2 2\n1.0\n3.0\n2.0\n4.0\n")
	write(t, in, "b.mtx", "%%MatrixMarket matrix coordinate real general\n2 2 2\n1 1 0.5\n2 2 -1.5\n")
	write(t, in, "s.mtx", "%%MatrixMarket matrix array real symmetric\n2 2\n4.0\n2.0\n5.0\n")
	write(t, in, "r.mtx", "%%MatrixMarket matrix array real general\n2 3\n1\n2\n3\n4\n5\n6\n")
	if err := Run(in, out); err != nil {
		t.Fatal(err)
	}
	want := map[string]string{
		"001_add.mtx": "%%MatrixMarket matrix array real general\n2 2\n" +
			"1.5000000000e+00\n3.0000000000e+00\n2.0000000000e+00\n2.5000000000e+00\n",
		"002_det.mtx": "%%MatrixMarket matrix array real general\n1 1\n-2.0000000000e+00\n",
		"003_chol_L.mtx": "%%MatrixMarket matrix array real general\n2 2\n" +
			"2.0000000000e+00\n1.0000000000e+00\n0.0000000000e+00\n2.0000000000e+00\n",
		"004_error.txt": "not_square\n",
	}
	entries, err := os.ReadDir(out)
	if err != nil {
		t.Fatal(err)
	}
	var names []string
	for _, e := range entries {
		names = append(names, e.Name())
	}
	sort.Strings(names)
	if len(names) != len(want) {
		t.Fatalf("output files = %v", names)
	}
	for name, content := range want {
		got, err := os.ReadFile(filepath.Join(out, name))
		if err != nil || string(got) != content {
			t.Errorf("%s: got %q (%v)", name, got, err)
		}
	}
}

func TestRunAllOperations(t *testing.T) {
	in, out := t.TempDir(), t.TempDir()
	write(t, in, "commands.txt", "lu a\ninv a\nsolve a a\nqr a\neig s\nsvd a\nlstsq a a\n"+
		"norm1 a\nnorminf a\nnormfro a\ncond a\ntranspose a\nmul a a\n")
	write(t, in, "a", "%%MatrixMarket matrix array real general\n2 2\n2\n1\n1\n3\n")
	write(t, in, "s", "%%MatrixMarket matrix array real symmetric\n2 2\n2\n1\n3\n")
	if err := Run(in, out); err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{
		"001_lu_P.mtx", "001_lu_L.mtx", "001_lu_U.mtx", "002_inv.mtx", "003_solve.mtx",
		"004_qr_Q.mtx", "004_qr_R.mtx", "005_eig_w.mtx", "005_eig_V.mtx",
		"006_svd_U.mtx", "006_svd_S.mtx", "006_svd_V.mtx", "007_lstsq.mtx",
		"008_norm1.mtx", "009_norminf.mtx", "010_normfro.mtx", "011_cond.mtx",
		"012_transpose.mtx", "013_mul.mtx",
	} {
		if _, err := os.Stat(filepath.Join(out, name)); err != nil {
			t.Errorf("missing %s", name)
		}
	}
}
