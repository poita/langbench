package typeset

import (
	"bytes"
	"os"
	"path/filepath"
	"sort"
	"testing"
	"testing/fstest"
)

// TestGolden runs every case under testdata: testdata/<name>/input holds the
// document (and settings), testdata/<name>/expected the expected files.
func TestGolden(t *testing.T) {
	cases, err := filepath.Glob("testdata/*/input")
	if err != nil || len(cases) == 0 {
		t.Fatalf("no golden cases found: %v", err)
	}
	data := os.DirFS("data")
	for _, in := range cases {
		dir := filepath.Dir(in)
		t.Run(filepath.Base(dir), func(t *testing.T) {
			out, err := Typeset(os.DirFS(in), data)
			if err != nil {
				t.Fatal(err)
			}
			expDir := filepath.Join(dir, "expected")
			entries, err := os.ReadDir(expDir)
			if err != nil {
				t.Fatal(err)
			}
			var want []string
			for _, e := range entries {
				want = append(want, e.Name())
				exp, err := os.ReadFile(filepath.Join(expDir, e.Name()))
				if err != nil {
					t.Fatal(err)
				}
				got, ok := out.Files[e.Name()]
				if !ok {
					t.Fatalf("missing output %s", e.Name())
				}
				if !bytes.Equal(bytes.TrimRight(got, "\n"), bytes.TrimRight(exp, "\n")) {
					t.Errorf("%s differs from expected", e.Name())
				}
			}
			var have []string
			for name := range out.Files {
				have = append(have, name)
			}
			sort.Strings(have)
			sort.Strings(want)
			if len(have) != len(want) {
				t.Errorf("files %v, want %v", have, want)
			}
		})
	}
}

func TestMissingDocument(t *testing.T) {
	out, err := Typeset(fstest.MapFS{}, os.DirFS("data"))
	if err != nil {
		t.Fatal(err)
	}
	if got := string(out.Files["error.txt"]); got != "-:0:0: missing-document\n" || len(out.Files) != 1 {
		t.Errorf("got %q", got)
	}
}

func TestEmptyDocument(t *testing.T) {
	in := fstest.MapFS{"document.cdx": {Data: nil}}
	out, err := Typeset(in, os.DirFS("data"))
	if err != nil {
		t.Fatal(err)
	}
	if got := string(out.Files["layout.txt"]); got != "layout 1\npages 0\n" {
		t.Errorf("layout %q", got)
	}
}

func TestSettingsErrorBeatsDocumentError(t *testing.T) {
	in := fstest.MapFS{
		"document.cdx": {Data: []byte("@bogus\n")},
		"settings.cfg": {Data: []byte("tolerance = x\n")},
	}
	out, _ := Typeset(in, os.DirFS("data"))
	if out.Err == nil || out.Err.File != "settings.cfg" {
		t.Errorf("err = %v", out.Err)
	}
}

func TestOneLine(t *testing.T) {
	in := fstest.MapFS{
		"document.cdx": {Data: []byte("The quick brown fox.\n")},
		"settings.cfg": {Data: []byte("page-width = 200pt\npage-height = 120pt\nmargin-top = 20pt\nmargin-bottom = 20pt\nmargin-left = 20pt\nmargin-right = 20pt\n")},
	}
	out, err := Typeset(in, os.DirFS("data"))
	if err != nil {
		t.Fatal(err)
	}
	want := "layout 1\npages 1\npage 1 1 200000 120000 20000 20000 160000 80000\n" +
		"  text body serif 10000 38000 27310 15630 \"The\"\n" +
		"  text body serif 10000 56170 27310 22240 \"quick\"\n" +
		"  text body serif 10000 80950 27310 25140 \"brown\"\n" +
		"  text body serif 10000 108630 27310 15810 \"fox.\"\n"
	if got := string(out.Files["layout.txt"]); got != want {
		t.Errorf("layout:\n%s", got)
	}
}
