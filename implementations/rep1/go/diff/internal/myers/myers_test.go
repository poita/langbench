package myers

import (
	"math/rand"
	"testing"
)

// lcsLen is a reference O(NM) LCS length, used only to check minimality.
func lcsLen(a, b []int32) int {
	prev := make([]int, len(b)+1)
	cur := make([]int, len(b)+1)
	for i := 1; i <= len(a); i++ {
		for j := 1; j <= len(b); j++ {
			switch {
			case a[i-1] == b[j-1]:
				cur[j] = prev[j-1] + 1
			case prev[j] >= cur[j-1]:
				cur[j] = prev[j]
			default:
				cur[j] = cur[j-1]
			}
		}
		prev, cur = cur, prev
	}
	return prev[len(b)]
}

func check(t *testing.T, a, b []int32) {
	t.Helper()
	del, ins := Compare(a, b)
	var ka, kb []int32
	cost := 0
	for i, d := range del {
		if d {
			cost++
		} else {
			ka = append(ka, a[i])
		}
	}
	for j, in := range ins {
		if in {
			cost++
		} else {
			kb = append(kb, b[j])
		}
	}
	if len(ka) != len(kb) {
		t.Fatalf("a=%v b=%v: kept %v vs %v", a, b, ka, kb)
	}
	for i := range ka {
		if ka[i] != kb[i] {
			t.Fatalf("a=%v b=%v: kept sequences differ: %v vs %v", a, b, ka, kb)
		}
	}
	if want := len(a) + len(b) - 2*lcsLen(a, b); cost != want {
		t.Fatalf("a=%v b=%v: cost %d, want %d", a, b, cost, want)
	}
}

func TestPaperExample(t *testing.T) {
	check(t, []int32{0, 1, 2, 0, 1, 1, 0}, []int32{2, 1, 0, 1, 0, 2})
}

func TestEdgeCases(t *testing.T) {
	cases := [][2][]int32{
		{nil, nil},
		{nil, {1}},
		{{1}, nil},
		{{1}, {1}},
		{{1}, {2}},
		{{1, 2, 3}, {1, 2, 3}},
		{{1, 2, 3}, {4, 5, 6}},
		{{1, 1, 1, 1}, {1, 1}},
		{{1, 2}, {2, 1}},
	}
	for _, c := range cases {
		check(t, c[0], c[1])
	}
}

func TestRandom(t *testing.T) {
	rng := rand.New(rand.NewSource(1))
	for iter := 0; iter < 20000; iter++ {
		alpha := int32(1 + rng.Intn(6))
		a := make([]int32, rng.Intn(25))
		b := make([]int32, rng.Intn(25))
		for i := range a {
			a[i] = rng.Int31n(alpha)
		}
		for i := range b {
			b[i] = rng.Int31n(alpha)
		}
		check(t, a, b)
	}
}

func TestRandomEdits(t *testing.T) {
	rng := rand.New(rand.NewSource(2))
	for iter := 0; iter < 200; iter++ {
		a := make([]int32, 50+rng.Intn(300))
		for i := range a {
			a[i] = rng.Int31n(40)
		}
		var b []int32
		for _, v := range a {
			switch rng.Intn(12) {
			case 0: // delete
			case 1:
				b = append(b, v, rng.Int31n(40))
			default:
				b = append(b, v)
			}
		}
		check(t, a, b)
	}
}

func BenchmarkDisjoint(b *testing.B) {
	x := make([]int32, 1500)
	y := make([]int32, 1500)
	for i := range x {
		x[i], y[i] = int32(i), int32(i+1500)
	}
	for i := 0; i < b.N; i++ {
		Compare(x, y)
	}
}
