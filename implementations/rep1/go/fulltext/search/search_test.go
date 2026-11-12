package search

import (
	"math"
	"reflect"
	"sort"
	"strings"
	"testing"

	"fulltext/analysis"
	"fulltext/index"
)

func newSearcher(docs map[string]string) *Searcher {
	an := analysis.NewAnalyzer()
	b := index.NewBuilder(an)
	for id, text := range docs {
		b.Add(id, text)
	}
	return New(b.Build(), an)
}

func ids(hits []Hit) []string {
	out := []string{}
	for _, h := range hits {
		out = append(out, h.DocID)
	}
	return out
}

func TestWorkedExample(t *testing.T) {
	s := newSearcher(map[string]string{"note": "The quick brown fox jumps over the lazy dog.\n"})
	hits := s.Search("fox", 10)
	if len(hits) != 1 {
		t.Fatalf("hits = %v", hits)
	}
	if want := math.Log(4.0 / 3.0); math.Abs(hits[0].Score-want) > 1e-12 {
		t.Errorf("score = %v, want %v", hits[0].Score, want)
	}
	if hits[0].Snippet != "The quick brown fox jumps over the lazy dog" {
		t.Errorf("snippet = %q", hits[0].Snippet)
	}
	if got := s.Search("quick brown", 10)[0].Score; math.Abs(got-2*math.Log(4.0/3.0)) > 1e-12 {
		t.Errorf("two-atom score = %v", got)
	}
	if got := s.Search(`"lazy dog"`, 10); len(got) != 1 {
		t.Errorf(`"lazy dog" hits = %v`, got)
	}
	if got := s.Search("cat", 10); len(got) != 0 {
		t.Errorf("cat hits = %v", got)
	}
}

func TestTieBreakAndFrequency(t *testing.T) {
	s := newSearcher(map[string]string{
		"copy1": "alpha beta gamma", "copy2": "alpha beta gamma", "copy3": "alpha beta gamma",
		"other": "alpha alpha beta",
	})
	hits := s.Search("alpha", 10)
	if want := []string{"other", "copy1", "copy2", "copy3"}; !reflect.DeepEqual(ids(hits), want) {
		t.Fatalf("order = %v, want %v", ids(hits), want)
	}
	if got := s.Search("alpha", 2); len(got) != 2 {
		t.Errorf("k=2 gave %d hits", len(got))
	}
	if got := s.Search("alpha", 0); len(got) != 0 {
		t.Errorf("k=0 gave %d hits", len(got))
	}
}

func TestBoolean(t *testing.T) {
	s := newSearcher(map[string]string{
		"1": "cat dog", "2": "cat bird", "3": "dog", "4": "fish",
	})
	tests := []struct {
		q    string
		want []string
	}{
		{"cat dog", []string{"1"}},
		{"cat AND dog", []string{"1"}},
		{"cat OR dog", []string{"1", "2", "3"}},
		{"cat NOT dog", []string{"2"}},
		{"NOT cat", []string{"3", "4"}},
		{"NOT NOT cat", []string{"1", "2"}},
		{"(cat OR dog) NOT bird", []string{"1", "3"}},
		{"the", nil},
		{"()", nil},
		{"zebra", nil},
		{"cat OR zebra", []string{"1", "2"}},
		{"NOT zebra", []string{"1", "2", "3", "4"}},
	}
	for _, tc := range tests {
		got := ids(s.Search(tc.q, 10))
		sort.Strings(got) // this test checks the matched set, not the ranking
		if tc.want == nil {
			tc.want = []string{}
		}
		if !reflect.DeepEqual(got, tc.want) {
			t.Errorf("%q = %v, want %v", tc.q, got, tc.want)
		}
	}
	// A match with no positive atom scores exactly zero.
	for _, h := range s.Search("NOT cat", 10) {
		if h.Score != 0 {
			t.Errorf("NOT cat scored %v", h.Score)
		}
	}
}

func TestPhrases(t *testing.T) {
	s := newSearcher(map[string]string{
		"a": "aa aa aa aa",
		"b": "to be or not to be",
		"c": "be to",
	})
	if got := ids(s.Search(`"aa aa"`, 10)); !reflect.DeepEqual(got, []string{"a"}) {
		t.Errorf("overlap: %v", got)
	}
	// Three overlapping occurrences: tf 3 beats a single-occurrence match.
	m := matchAtom(s.ix, []string{"aa", "aa"})
	if !reflect.DeepEqual(m.Positions(0), []int32{0, 1, 2}) {
		t.Errorf("positions = %v", m.Positions(0))
	}
	if got := ids(s.Search(`"to be or not to be"`, 10)); !reflect.DeepEqual(got, []string{"b"}) {
		t.Errorf("stop-word phrase: %v", got)
	}
	if got := ids(s.Search(`"be to"`, 10)); !reflect.DeepEqual(got, []string{"c"}) {
		t.Errorf("be to: %v", got)
	}
	// Phrases do not span documents and missing terms match nothing.
	if m := matchAtom(s.ix, []string{"be", "zzz"}); m.Len() != 0 {
		t.Errorf("unexpected match %+v", m)
	}
}

func TestBestWindow(t *testing.T) {
	filler := func(n int) string { return strings.Repeat("x ", n) }
	// 40 filler words, then "needle", then 40 more: the window must hold it.
	text := filler(40) + "needle " + filler(40)
	s := newSearcher(map[string]string{"d": text})
	h := s.Search("needle", 1)[0]
	if !strings.Contains(h.Snippet, "needle") {
		t.Errorf("snippet lacks needle: %q", h.Snippet)
	}
	if n := len(strings.Fields(h.Snippet)); n != WindowSize {
		t.Errorf("snippet has %d tokens, want %d", n, WindowSize)
	}
	// Ties on both criteria go to the smallest start: the needle at position 0
	// puts the window at 0 even though later windows would also contain others.
	s = newSearcher(map[string]string{"d": "needle " + filler(60)})
	if h := s.Search("needle", 1)[0]; !strings.HasPrefix(h.Snippet, "needle") {
		t.Errorf("snippet = %q", h.Snippet)
	}
}

func TestBestWindowDistinctBeatsTotal(t *testing.T) {
	// Window A has two occurrences of one atom; window B has one of each of two.
	a := occurrences{starts: []int32{0, 1, 100}, n: 1}
	b := occurrences{starts: []int32{101}, n: 1}
	if got := bestWindow(200, []occurrences{a, b}); got != 72 { // first start covering 100 and 101
		t.Errorf("bestWindow = %d, want 72", got)
	}
	// Overlong atoms never count; with nothing else the window is 0.
	if got := bestWindow(100, []occurrences{{starts: []int32{50}, n: 31}}); got != 0 {
		t.Errorf("overlong atom: %d", got)
	}
	if got := bestWindow(10, []occurrences{{starts: []int32{5}, n: 1}}); got != 0 {
		t.Errorf("short doc: %d", got)
	}
}

func TestSnippetWhitespace(t *testing.T) {
	s := newSearcher(map[string]string{"d": "\n\n  alpha\t\u00a0 beta\r\n\r\ngamma...  \n"})
	if got := s.Search("alpha", 1)[0].Snippet; got != "alpha beta gamma" {
		t.Errorf("snippet = %q", got)
	}
}

func TestEmptyDocumentAndCorpus(t *testing.T) {
	s := newSearcher(map[string]string{"e": ""})
	if got := ids(s.Search("NOT cat", 10)); !reflect.DeepEqual(got, []string{"e"}) {
		t.Errorf("hits = %v", got)
	}
	if h := s.Search("NOT cat", 10)[0]; h.Snippet != "" || h.Score != 0 {
		t.Errorf("hit = %+v", h)
	}
	if got := newSearcher(nil).Search("NOT cat", 10); len(got) != 0 {
		t.Errorf("empty corpus hits = %v", got)
	}
}
