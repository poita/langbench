package textbuffer

import (
	"fmt"
	"math/rand"
	"slices"
	"testing"
)

func storeLines(s *lineStore) []string {
	var out []string
	for i := 0; i < s.count(); i++ {
		out = append(out, string(s.at(i)))
	}
	return out
}

func TestLineStoreReplaceMatchesSlice(t *testing.T) {
	rng := rand.New(rand.NewSource(1))
	var model []string
	s := newLineStore(nil)
	for step := 0; step < 2000; step++ {
		a := rng.Intn(len(model) + 1)
		k := 0
		if a < len(model) {
			k = rng.Intn(min(4, len(model)-a) + 1)
		}
		n := rng.Intn(4)
		var repl [][]byte
		var mrepl []string
		for i := 0; i < n; i++ {
			l := fmt.Sprint(step, ".", i)
			repl = append(repl, []byte(l))
			mrepl = append(mrepl, l)
		}
		s.replace(a, k, repl)
		model = slices.Concat(model[:a], mrepl, model[a+k:])
		if got := storeLines(&s); !slices.Equal(got, model) {
			t.Fatalf("step %d: got %q want %q", step, got, model)
		}
	}
}

func TestLineStoreSet(t *testing.T) {
	s := newLineStore([][]byte{[]byte("a"), []byte("b"), []byte("c")})
	s.replace(1, 1, [][]byte{[]byte("x"), []byte("y")}) // a x y c, gap moved
	s.set(0, []byte("A"))
	s.set(3, []byte("C"))
	if got := storeLines(&s); !slices.Equal(got, []string{"A", "x", "y", "C"}) {
		t.Fatalf("got %q", got)
	}
}
