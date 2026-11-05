package fulltext

import (
	"bytes"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func build(docs map[string]string) *Index {
	b := NewBuilder()
	for id, text := range docs {
		b.Add(id, []byte(text))
	}
	return b.Build()
}

func ids(hits []Hit) string {
	var s []string
	for _, h := range hits {
		s = append(s, h.DocID)
	}
	return strings.Join(s, ",")
}

func TestWorkedExample(t *testing.T) {
	ix := build(map[string]string{"note": "The quick brown fox jumps over the lazy dog.\n"})
	st := ix.Stats()
	if st.Documents != 1 || st.Tokens != 9 || st.Terms != 8 || st.AvgDocLen != 9 {
		t.Fatalf("stats %+v", st)
	}
	if got := st.String(); got != "documents 1\ntokens 9\nterms 8\navgdl 9.0000\n" {
		t.Fatalf("stats string %q", got)
	}
	var out bytes.Buffer
	qs := ParseQueryFile("fox\nquick brown\ncat\n\"lazy dog\"\n")
	if err := ix.WriteResults(&out, qs); err != nil {
		t.Fatal(err)
	}
	snip := "The quick brown fox jumps over the lazy dog"
	want := "QUERY 1 fox\nHITS 1\n1\tnote\t0.2877\t" + snip + "\n" +
		"QUERY 2 quick brown\nHITS 1\n1\tnote\t0.5754\t" + snip + "\n" +
		"QUERY 3 cat\nHITS 0\n" +
		"QUERY 4 \"lazy dog\"\nHITS 1\n1\tnote\t0.2877\t" + snip + "\n"
	if out.String() != want {
		t.Fatalf("got\n%s\nwant\n%s", out.String(), want)
	}
}

func TestTieBreakAndFrequency(t *testing.T) {
	ix := build(map[string]string{
		"copy1": "alpha beta gamma", "copy2": "alpha beta gamma", "copy3": "alpha beta gamma",
		"other": "alpha alpha beta",
	})
	hits := ix.Search("alpha", 10)
	if got := ids(hits); got != "other,copy1,copy2,copy3" {
		t.Fatalf("order %s", got)
	}
	if s := fmt.Sprintf("%.4f %.4f", hits[0].Score, hits[1].Score); s != "0.1449 0.1054" {
		t.Fatalf("scores %s", s)
	}
	if got := ids(ix.Search("alpha", 2)); got != "other,copy1" {
		t.Fatalf("k=2 gave %s", got)
	}
}

func TestBooleanSemantics(t *testing.T) {
	ix := build(map[string]string{
		"a": "cat dog", "b": "cat bird", "c": "dog bird", "d": "fish",
	})
	cases := map[string]string{
		"cat dog":            "a",
		"cat OR dog":         "a,b,c",
		"cat NOT dog":        "b",
		"NOT cat":            "c,d",
		"NOT NOT cat":        "a,b",
		"(cat OR dog) bird":  "b,c",
		"cat AND NOT (dog)":  "b",
		"":                   "",
		"the":                "",
		"NOT the":            "",
		"unicorn":            "",
		"NOT unicorn":        "a,b,c,d",
		"cat OR unicorn":     "a,b",
		"cat ) dog":          "a,b",
		`"cat dog"`:          "a",
		`"dog cat"`:          "",
		"cats":               "a,b", // stemmed
		"CAT":                "a,b", // folded
		"fish NOT (cat dog)": "d",
	}
	for q, want := range cases {
		if got := ids(ix.Search(q, 10)); got != want {
			t.Errorf("Search(%q) = %q, want %q", q, got, want)
		}
	}
}

func TestPhraseOverlapAndStopWords(t *testing.T) {
	ix := build(map[string]string{"x": "aa aa aa aa", "y": "to be or not to be", "z": "be to"})
	if got := ids(ix.Search(`"aa aa"`, 10)); got != "x" {
		t.Fatalf("got %q", got)
	}
	if got := ids(ix.Search(`"to be or not to be"`, 10)); got != "y" {
		t.Fatalf("got %q", got)
	}
	// A lone stop word is an empty atom, but stop words inside phrases count.
	if got := ids(ix.Search(`"to be"`, 10)); got != "y" {
		t.Fatalf("got %q", got)
	}
	if got := ids(ix.Search(`to`, 10)); got != "" {
		t.Fatalf("got %q", got)
	}
}

func TestSnippetWindow(t *testing.T) {
	var words []string
	for i := 0; i < 100; i++ {
		words = append(words, fmt.Sprintf("w%d", i))
	}
	words[60] = "needle"
	words[61] = "thread"
	text := strings.Join(words, " \t\n ")
	ix := build(map[string]string{"d": text, "short": "needle   thread"})
	hits := ix.Search("needle thread", 10)
	if len(hits) != 2 {
		t.Fatalf("hits %v", hits)
	}
	for _, h := range hits {
		switch h.DocID {
		case "d":
			// Earliest window containing both needle (60) and thread (61)
			// that starts at the lowest s: s = 61+1-30 = 32.
			if !strings.HasPrefix(h.Snippet, "w32 w33") || !strings.HasSuffix(h.Snippet, "thread") {
				t.Errorf("snippet %q", h.Snippet)
			}
			if strings.ContainsAny(h.Snippet, "\t\n") || strings.Contains(h.Snippet, "  ") {
				t.Errorf("whitespace not collapsed: %q", h.Snippet)
			}
		case "short":
			if h.Snippet != "needle thread" {
				t.Errorf("snippet %q", h.Snippet)
			}
		}
	}
}

func TestSnippetPrefersDistinctAtoms(t *testing.T) {
	// "rare" appears once, "common" many times elsewhere; the window with both
	// beats a window with more occurrences of one atom.
	var w []string
	for i := 0; i < 120; i++ {
		w = append(w, "filler")
	}
	for i := 0; i < 5; i++ {
		w[10+i] = "common"
	}
	w[100] = "common"
	w[101] = "rare"
	ix := build(map[string]string{"d": strings.Join(w, " ")})
	h := ix.Search("rare common", 1)[0]
	if !strings.Contains(h.Snippet, "rare") || !strings.Contains(h.Snippet, "common") {
		t.Fatalf("snippet %q", h.Snippet)
	}
}

func TestEmptyCorpusAndDocs(t *testing.T) {
	ix := NewBuilder().Build()
	if got := ix.Stats().String(); got != "documents 0\ntokens 0\nterms 0\navgdl 0.0000\n" {
		t.Fatalf("%q", got)
	}
	if len(ix.Search("NOT cat", 10)) != 0 {
		t.Fatal("hits in empty corpus")
	}
	ix = build(map[string]string{"e": "", "f": "...!"})
	hits := ix.Search("NOT cat", 10)
	if len(hits) != 2 || hits[0].Score != 0 || hits[0].Snippet != "" {
		t.Fatalf("hits %+v", hits)
	}
}

func TestParseQueryFile(t *testing.T) {
	data := "# comment\n\n  first one  \n%k 2\nsecond\n%k\t\t5 \n%k x\nthird\n%k 3"
	got := ParseQueryFile(data)
	want := []QueryLine{
		{1, "first one", 10}, {2, "second", 2}, {3, "%k x", 5}, {4, "third", 5},
	}
	if len(got) != len(want) {
		t.Fatalf("got %+v", got)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Errorf("line %d: got %+v want %+v", i, got[i], want[i])
		}
	}
}

func TestLoadDir(t *testing.T) {
	dir := t.TempDir()
	if err := os.MkdirAll(filepath.Join(dir, "docs"), 0o755); err != nil {
		t.Fatal(err)
	}
	os.WriteFile(filepath.Join(dir, "docs", "b.txt"), []byte("beta"), 0o644)
	os.WriteFile(filepath.Join(dir, "docs", "a.txt"), []byte("alpha"), 0o644)
	os.WriteFile(filepath.Join(dir, "docs", "skip.md"), []byte("gamma"), 0o644)
	ix, err := LoadDir(dir)
	if err != nil {
		t.Fatal(err)
	}
	if ix.NumDocs() != 2 || ix.DocID(0) != "a" || ix.DocLen(1) != 1 {
		t.Fatalf("unexpected index: %d docs", ix.NumDocs())
	}
	empty, err := LoadDir(t.TempDir())
	if err != nil || empty.NumDocs() != 0 {
		t.Fatalf("missing docs dir: %v", err)
	}
}

func ExampleIndex_Search() {
	b := NewBuilder()
	b.Add("note", []byte("The quick brown fox jumps over the lazy dog."))
	b.Add("other", []byte("A slow green turtle."))
	ix := b.Build()
	for _, h := range ix.Search(`fox OR "lazy dog"`, 10) {
		fmt.Printf("%s %.4f %s\n", h.DocID, h.Score, h.Snippet)
	}
	// Output: note 1.1978 The quick brown fox jumps over the lazy dog
}

func TestPhraseOccurrencesOverlap(t *testing.T) {
	ix := build(map[string]string{"x": "aa aa aa aa", "y": "aa bb aa"})
	r := ix.resolve([]string{"aa", "aa"})
	if len(r.occ.docs) != 1 || fmt.Sprint(r.occ.positions(0)) != "[0 1 2]" {
		t.Fatalf("occurrences %+v", r.occ)
	}
}
