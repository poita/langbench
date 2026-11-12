package batch

import (
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

func TestParseQueries(t *testing.T) {
	in := "# comment\n\n  fox  \n%k 3\ncat dog\n%k\t 5 \n\u00a0bird\u00a0\n%k x\n%k5\nlast"
	want := []Query{
		{1, "fox", 10},
		{2, "cat dog", 3},
		{3, "bird", 5},
		{4, "%k x", 5},
		{5, "%k5", 5},
		{6, "last", 5},
	}
	if got := ParseQueries(in); !reflect.DeepEqual(got, want) {
		t.Errorf("got %+v\nwant %+v", got, want)
	}
	if got := ParseQueries(""); len(got) != 0 {
		t.Errorf("empty input gave %v", got)
	}
}

func write(t *testing.T, path, content string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
}

func TestRun(t *testing.T) {
	in, out := t.TempDir(), filepath.Join(t.TempDir(), "out")
	write(t, filepath.Join(in, "docs", "note.txt"), "The quick brown fox jumps over the lazy dog.\n")
	write(t, filepath.Join(in, "docs", "ignored.md"), "fox")
	write(t, filepath.Join(in, "queries.txt"), "fox\nquick brown\ncat\n\"lazy dog\"\n")
	if err := Run(in, out); err != nil {
		t.Fatal(err)
	}
	const body = "The quick brown fox jumps over the lazy dog"
	wantResults := "QUERY 1 fox\nHITS 1\n1\tnote\t0.2877\t" + body + "\n" +
		"QUERY 2 quick brown\nHITS 1\n1\tnote\t0.5754\t" + body + "\n" +
		"QUERY 3 cat\nHITS 0\n" +
		"QUERY 4 \"lazy dog\"\nHITS 1\n1\tnote\t0.2877\t" + body + "\n"
	check := func(name, want string) {
		got, err := os.ReadFile(filepath.Join(out, name))
		if err != nil {
			t.Fatal(err)
		}
		if string(got) != want {
			t.Errorf("%s:\n%s\nwant:\n%s", name, got, want)
		}
	}
	check("results.txt", wantResults)
	check("stats.txt", "documents 1\ntokens 9\nterms 8\navgdl 9.0000\n")
}

func TestRunNoDocs(t *testing.T) {
	in, out := t.TempDir(), t.TempDir()
	write(t, filepath.Join(in, "queries.txt"), "NOT cat\n")
	if err := Run(in, out); err != nil {
		t.Fatal(err)
	}
	got, _ := os.ReadFile(filepath.Join(out, "stats.txt"))
	if string(got) != "documents 0\ntokens 0\nterms 0\navgdl 0.0000\n" {
		t.Errorf("stats = %q", got)
	}
	got, _ = os.ReadFile(filepath.Join(out, "results.txt"))
	if string(got) != "QUERY 1 NOT cat\nHITS 0\n" {
		t.Errorf("results = %q", got)
	}
}
