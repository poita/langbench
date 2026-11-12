package sat

import "testing"

func TestLuby(t *testing.T) {
	want := []float64{1, 1, 2, 1, 1, 2, 4, 1, 1, 2, 1, 1, 2, 4, 8}
	for i, w := range want {
		if got := luby(2, i); got != w {
			t.Errorf("luby(2, %d) = %v, want %v", i, got, w)
		}
	}
}
