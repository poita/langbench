package linebreak

import (
	"math/big"
	"testing"

	"typeset/hlist"
)

func TestBadnessRatio(t *testing.T) {
	cases := []struct{ d, y, want int64 }{
		{11020, 6350, 522}, {3890, 5100, 44}, {30950, 5080, 10000}, {3110, 3400, 76}, {1, 1, 100},
	}
	for _, c := range cases {
		if got := badnessRatio(c.d, c.y); got != c.want {
			t.Errorf("badnessRatio(%d,%d) = %d, want %d", c.d, c.y, got, c.want)
		}
	}
}

func TestBadnessRatioLarge(t *testing.T) {
	// Values whose cubes need more than 64 bits agree with big integers.
	for _, y := range []int64{1 << 22, 3_000_000, 123_456_789} {
		for _, d := range []int64{y / 3, y / 2, y, 2 * y, 4 * y} {
			n := new(big.Int).Exp(big.NewInt(d), big.NewInt(3), nil)
			n.Mul(n, big.NewInt(100))
			n.Div(n, new(big.Int).Exp(big.NewInt(y), big.NewInt(3), nil))
			want := n.Int64()
			if want > 10000 {
				want = 10000
			}
			if got := badnessRatio(d, y); got != want {
				t.Errorf("badnessRatio(%d,%d) = %d, want %d", d, y, got, want)
			}
		}
	}
}

func TestClassify(t *testing.T) {
	L := int64(142000)
	cases := []struct {
		m    hlist.LineMeasure
		bad  int64
		fit  int
		kind lineKind
	}{
		{hlist.LineMeasure{W: 142000, Y: 1270, Z: 850}, 0, decent, kindOK},
		{hlist.LineMeasure{W: 130980, Y: 6350, Z: 4250}, 522, veryLoose, kindOK},
		{hlist.LineMeasure{W: 145890, Y: 7620, Z: 5100}, 44, tight, kindOK},
		{hlist.LineMeasure{W: 111050, Y: 5080, Z: 3400}, 10000, veryLoose, kindOK},
		{hlist.LineMeasure{W: 164800, Y: 8890, Z: 5950}, 10000, tight, kindOverfull},
		{hlist.LineMeasure{W: 15630}, 10000, veryLoose, kindUnstretchable},
		{hlist.LineMeasure{W: 15630, Inf: true}, 0, decent, kindOK},
	}
	for i, c := range cases {
		bad, fit, kind := classify(c.m, L)
		if bad != c.bad || fit != c.fit || kind != c.kind {
			t.Errorf("case %d: got %d,%d,%d want %d,%d,%d", i, bad, fit, kind, c.bad, c.fit, c.kind)
		}
	}
}
