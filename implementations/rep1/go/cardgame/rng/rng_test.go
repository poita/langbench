package rng

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
	for i := 0; i < 4; i++ {
		if a.Next() != b.Next() {
			t.Fatal("zero seed must equal the fixed constant")
		}
	}
}

func TestShuffleSmallConsumesNothing(t *testing.T) {
	r := New(7)
	r.Shuffle(0, func(i, j int) { t.Fatal("swap called") })
	r.Shuffle(1, func(i, j int) { t.Fatal("swap called") })
	if r.Next() != 15130880334998875822 {
		t.Fatal("randomness was consumed")
	}
}

func TestShuffleSpecExample(t *testing.T) {
	// SPEC 26.12: the first player's shuffle of eight cards under seed 7.
	l := []int{1, 2, 3, 4, 5, 6, 7, 8}
	New(7).Shuffle(len(l), func(i, j int) { l[i], l[j] = l[j], l[i] })
	want := []int{6, 8, 5, 2, 4, 1, 3, 7}
	for i := range l {
		if l[i] != want[i] {
			t.Fatalf("got %v want %v", l, want)
		}
	}
}
