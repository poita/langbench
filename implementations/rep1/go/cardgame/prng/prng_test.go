package prng

import "testing"

func TestSeed7Sequence(t *testing.T) {
	want := []uint64{
		15130880334998875822,
		17123930943180875438,
		1648209070578717474,
		1985375592982671918,
		6908966637734145041,
	}
	r := New(7)
	for i, w := range want {
		if got := r.Next(); got != w {
			t.Fatalf("value %d: got %d want %d", i, got, w)
		}
	}
}

func TestZeroSeed(t *testing.T) {
	a, b := New(0), New(multiplier)
	for i := 0; i < 5; i++ {
		if a.Next() != b.Next() {
			t.Fatal("zero seed must behave as the constant")
		}
	}
}

func TestShuffleSmallConsumesNothing(t *testing.T) {
	r := New(5)
	r.Shuffle(0, func(i, j int) { t.Fatal("swap on empty") })
	r.Shuffle(1, func(i, j int) { t.Fatal("swap on single") })
	if r.Next() != New(5).Next() {
		t.Fatal("randomness was consumed")
	}
}

func TestShuffleIsPermutation(t *testing.T) {
	xs := []int{0, 1, 2, 3, 4, 5, 6, 7}
	New(7).Shuffle(len(xs), func(i, j int) { xs[i], xs[j] = xs[j], xs[i] })
	seen := map[int]bool{}
	for _, x := range xs {
		seen[x] = true
	}
	if len(seen) != 8 {
		t.Fatalf("not a permutation: %v", xs)
	}
	// Spec 26.12: A's shuffle of 1..8 under seed 7 gives #6 #8 #5 #2 #4 #1 #3 #7.
	want := []int{5, 7, 4, 1, 3, 0, 2, 6}
	for i := range want {
		if xs[i] != want[i] {
			t.Fatalf("got %v want %v", xs, want)
		}
	}
}
