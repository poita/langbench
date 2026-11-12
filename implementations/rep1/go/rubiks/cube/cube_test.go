package cube

import (
	"math/rand"
	"strings"
	"testing"
)

func mustMoves(t testing.TB, s string) []Move {
	t.Helper()
	m, err := ParseMoves(s)
	if err != nil {
		t.Fatal(err)
	}
	return m
}

func apply(t testing.TB, s string) Cube {
	t.Helper()
	c := Solved()
	c.ApplyAll(mustMoves(t, s))
	return c
}

// order returns how many times seq must be applied to return to solved.
func order(t testing.TB, seq string) int {
	t.Helper()
	moves := mustMoves(t, seq)
	c := Solved()
	for n := 1; n <= 1000; n++ {
		c.ApplyAll(moves)
		if c.IsSolved() {
			return n
		}
	}
	t.Fatalf("%q has no small order", seq)
	return 0
}

func TestParseFormatRoundTrip(t *testing.T) {
	const all = "U D L R F B U' D' L' R' F' B' U2 D2 L2 R2 F2 B2"
	moves := mustMoves(t, all)
	if len(moves) != NumMoves {
		t.Fatalf("got %d moves", len(moves))
	}
	if got := FormatMoves(moves); got != all {
		t.Errorf("FormatMoves = %q, want %q", got, all)
	}
	seen := map[Move]bool{}
	for _, m := range moves {
		seen[m] = true
		if m.Inverse().Inverse() != m {
			t.Errorf("%v: double inverse differs", m)
		}
	}
	if len(seen) != NumMoves {
		t.Errorf("moves not distinct")
	}
}

func TestParseErrors(t *testing.T) {
	for _, s := range []string{"R2'", "r", "R'2", "X", "R3", "'", "RU"} {
		if _, err := ParseMoves(s); err == nil {
			t.Errorf("ParseMoves(%q) succeeded, want error", s)
		}
	}
	if m, err := ParseMoves(""); err != nil || len(m) != 0 {
		t.Errorf("ParseMoves(\"\") = %v, %v", m, err)
	}
}

func TestNewMove(t *testing.T) {
	if NewMove(R, 1) != MoveR || NewMove(R, 2) != MoveR2 || NewMove(R, -1) != MoveRPrime ||
		NewMove(B, 3) != MoveBPrime {
		t.Error("NewMove returned the wrong move")
	}
}

func TestQuarterTurnsHaveOrderFour(t *testing.T) {
	for _, f := range "UDLRFB" {
		s := string(f)
		if got := order(t, s); got != 4 {
			t.Errorf("order of %s = %d, want 4", s, got)
		}
		if got := order(t, s+"2"); got != 2 {
			t.Errorf("order of %s2 = %d, want 2", s, got)
		}
		if !apply(t, s+" "+s+"'").IsSolved() {
			t.Errorf("%s %s' is not the identity", s, s)
		}
	}
}

func TestKnownOrders(t *testing.T) {
	tests := []struct {
		seq  string
		want int
	}{
		{"R U R' U'", 6},
		{"R U", 105},
		{"U F", 105},
		{"L B", 105},
		{"U D", 4},
		{"R L", 4},
		{"F B", 4},
	}
	for _, tc := range tests {
		if got := order(t, tc.seq); got != tc.want {
			t.Errorf("order(%q) = %d, want %d", tc.seq, got, tc.want)
		}
	}
}

func TestSuperflip(t *testing.T) {
	c := apply(t, "U R2 F B R B2 R U2 L B2 R U' D' R2 F R' L B2 U2 F2")
	want := Solved()
	for i := range want.EO {
		want.EO[i] = 1
	}
	if c != want {
		t.Errorf("superflip mismatch: %+v", c)
	}
}

func TestSpecExampleU(t *testing.T) {
	// After U on a solved cube, F1 F2 F3 show R, L1 L2 L3 show F,
	// B1 B2 B3 show L and R1 R2 R3 show B.
	f := apply(t, "U").Facelets()
	check := func(face Face, want byte) {
		t.Helper()
		for n := 0; n < 3; n++ {
			if got := f[int(face)*9+n]; got != want {
				t.Errorf("%v%d = %c, want %c", face, n+1, got, want)
			}
		}
	}
	check(F, 'R')
	check(L, 'F')
	check(B, 'L')
	check(R, 'B')
}

func TestOrientationConventions(t *testing.T) {
	flipsEdges := map[string]bool{"F": true, "B": true}
	for _, f := range []string{"U", "D", "L", "R", "F", "B"} {
		c := apply(t, f)
		flipped := false
		for _, o := range c.EO {
			flipped = flipped || o != 0
		}
		if flipped != flipsEdges[f] {
			t.Errorf("%s: edges flipped = %v", f, flipped)
		}
		if f == "F" || f == "B" {
			if apply(t, f+"2").EO != Solved().EO {
				t.Errorf("%s2 flips edges", f)
			}
		}
	}
}

func TestFaceletsMatchSpecCycles(t *testing.T) {
	// The R move cycles (F3 U3 B7 D3): the sticker at F3 moves to U3.
	f := apply(t, "R").Facelets()
	if f[facelet("U3")] != 'F' || f[facelet("B7")] != 'U' || f[facelet("D3")] != 'B' || f[facelet("F3")] != 'D' {
		t.Errorf("R facelets wrong: %s", f)
	}
}

func TestFaceletsRoundTrip(t *testing.T) {
	const solved = "UUUUUUUUURRRRRRRRRFFFFFFFFFDDDDDDDDDLLLLLLLLLBBBBBBBBB"
	s := Solved()
	if got := s.Facelets(); got != solved {
		t.Fatalf("solved facelets = %s", got)
	}
	rng := rand.New(rand.NewSource(1))
	for i := 0; i < 200; i++ {
		c := Solved()
		for j := 0; j < 30; j++ {
			c.Apply(Move(rng.Intn(NumMoves)))
		}
		back, err := FromFacelets(c.Facelets())
		if err != nil || back != c {
			t.Fatalf("round trip failed: %v", err)
		}
		if err := c.Validate(); err != nil {
			t.Fatalf("reachable cube invalid: %v", err)
		}
	}
}

func TestFromFaceletsErrors(t *testing.T) {
	if _, err := FromFacelets("UUU"); err == nil {
		t.Error("short string accepted")
	}
	bad := strings.Repeat("U", 54)
	if _, err := FromFacelets(bad); err == nil {
		t.Error("all-U cube accepted")
	}
	s := Solved()
	f := []byte(s.Facelets())
	f[0] = 'X'
	if _, err := FromFacelets(string(f)); err == nil {
		t.Error("bad letter accepted")
	}
}

func TestValidateRejectsImpossibleStates(t *testing.T) {
	twist := Solved()
	twist.CO[0] = 1
	flip := Solved()
	flip.EO[0] = 1
	swap := Solved()
	swap.EP[0], swap.EP[1] = swap.EP[1], swap.EP[0]
	dup := Solved()
	dup.CP[1] = 0
	for name, c := range map[string]Cube{"twist": twist, "flip": flip, "parity": swap, "duplicate": dup} {
		if c.Validate() == nil {
			t.Errorf("%s: Validate accepted invalid cube", name)
		}
	}
}

func TestInvertMoves(t *testing.T) {
	rng := rand.New(rand.NewSource(2))
	for i := 0; i < 50; i++ {
		seq := make([]Move, 40)
		for j := range seq {
			seq[j] = Move(rng.Intn(NumMoves))
		}
		c := Solved()
		c.ApplyAll(seq)
		c.ApplyAll(InvertMoves(seq))
		if !c.IsSolved() {
			t.Fatal("sequence followed by its inverse is not the identity")
		}
	}
}
