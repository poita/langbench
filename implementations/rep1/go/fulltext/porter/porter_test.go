package porter

import (
	"bufio"
	"os"
	"path/filepath"
	"testing"
)

func TestStem(t *testing.T) {
	tests := []struct{ word, want string }{
		// Words of one or two letters are untouched.
		{"a", "a"}, {"is", "is"}, {"as", "as"},
		// Step 1a.
		{"caresses", "caress"}, {"ponies", "poni"}, {"ties", "ti"}, {"caress", "caress"}, {"cats", "cat"},
		// Step 1b selection by suffix: feed/need/bleed must not fall through to ED.
		{"feed", "feed"}, {"need", "need"}, {"bleed", "bleed"}, {"agreed", "agre"},
		{"plastered", "plaster"}, {"bled", "bled"}, {"motoring", "motor"}, {"sing", "sing"},
		{"conflated", "conflat"}, {"troubled", "troubl"}, {"sized", "size"},
		{"hopping", "hop"}, {"tanned", "tan"}, {"falling", "fall"}, {"fizzed", "fizz"},
		{"filing", "file"}, {"failing", "fail"},
		// Step 1c.
		{"happy", "happi"}, {"sky", "sky"},
		// Steps 2-4 and the two departures from the paper.
		{"relational", "relat"}, {"conditional", "condit"}, {"conformabli", "conform"},
		{"apologi", "apolog"}, {"vietnamization", "vietnam"}, {"sensibility", "sensibl"},
		{"triplicate", "triplic"}, {"formative", "form"}, {"electrical", "electr"},
		{"revival", "reviv"}, {"allowance", "allow"}, {"adoption", "adopt"},
		// Step 5.
		{"probate", "probat"}, {"rate", "rate"}, {"cease", "ceas"},
		{"controll", "control"}, {"roll", "roll"},
		// Worked stems from the specification.
		{"running", "run"}, {"runs", "run"}, {"runner", "runner"}, {"connection", "connect"},
		{"connections", "connect"}, {"connecting", "connect"}, {"cats", "cat"}, {"dogs", "dog"},
		{"happiness", "happi"}, {"happier", "happier"}, {"relativity", "rel"},
		{"national", "nation"}, {"controlled", "control"}, {"abandoned", "abandon"},
	}
	for _, tc := range tests {
		if got := Stem(tc.word); got != tc.want {
			t.Errorf("Stem(%q) = %q, want %q", tc.word, got, tc.want)
		}
	}
}

// TestVocabulary checks Porter's published vocabulary when the repository
// vendors it (../../problems/fulltext/corpus/porter); otherwise it is skipped.
func TestVocabulary(t *testing.T) {
	dir := filepath.Join("..", "..", "problems", "fulltext", "corpus", "porter")
	in, err := os.Open(filepath.Join(dir, "voc.txt"))
	if err != nil {
		t.Skip("Porter vocabulary not available")
	}
	defer in.Close()
	out, err := os.Open(filepath.Join(dir, "output.txt"))
	if err != nil {
		t.Skip("Porter vocabulary not available")
	}
	defer out.Close()
	vs, os_ := bufio.NewScanner(in), bufio.NewScanner(out)
	n := 0
	for vs.Scan() {
		if !os_.Scan() {
			t.Fatal("output.txt shorter than voc.txt")
		}
		n++
		if got := Stem(vs.Text()); got != os_.Text() {
			t.Errorf("Stem(%q) = %q, want %q", vs.Text(), got, os_.Text())
		}
	}
	t.Logf("checked %d words", n)
}

func BenchmarkStem(b *testing.B) {
	for i := 0; i < b.N; i++ {
		Stem("generalizations")
	}
}
