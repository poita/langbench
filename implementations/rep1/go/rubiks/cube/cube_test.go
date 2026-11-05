package cube

import (
	"math/rand"
	"strings"
	"testing"
)

func mustParse(t testing.TB, s string) []Move {
	t.Helper()
	m, err := ParseMoves(s)
	if err != nil {
		t.Fatal(err)
	}
	return m
}

func repeat(s string, n int) string {
	return strings.TrimSpace(strings.Repeat(s+" ", n))
}

func TestNewIsSolved(t *testing.T) {
	c := New()
	if !c.IsSolved() {
		t.Fatal("New() is not solved")
	}
	if got := c.Facelets(); got != SolvedFacelets {
		t.Fatalf("Facelets() = %q", got)
	}
	if err := c.Verify(); err != nil {
		t.Fatal(err)
	}
}

func TestQuarterTurnHasOrderFour(t *testing.T) {
	for m := Move(0); m < NumMoves; m++ {
		c := New()
		for i := 0; i < 4; i++ {
			c.Apply(NewMove(m.Face(), m.Turns()))
		}
		if !c.IsSolved() {
			t.Errorf("%v applied 4 times is not the identity", m)
		}
	}
}

func TestMoveInverse(t *testing.T) {
	for m := Move(0); m < NumMoves; m++ {
		c := New()
		c.Apply(m)
		c.Apply(m.Inverse())
		if !c.IsSolved() {
			t.Errorf("%v followed by its inverse is not the identity", m)
		}
	}
}

func TestPrimeIsThreeQuarterTurns(t *testing.T) {
	for f := Face(0); f < NumFaces; f++ {
		a := Scrambled([]Move{NewMove(f, 1), NewMove(f, 1), NewMove(f, 1)})
		b := Scrambled([]Move{NewMove(f, 3)})
		if a != b {
			t.Errorf("%v' != %v^3", f, f)
		}
		h := Scrambled([]Move{NewMove(f, 1), NewMove(f, 1)})
		if h != Scrambled([]Move{NewMove(f, 2)}) {
			t.Errorf("%v2 != %v^2", f, f)
		}
	}
}

// order returns the order of the permutation made by repeating moves.
func order(moves []Move) int {
	c := Scrambled(moves)
	x := c
	for n := 1; n < 2000; n++ {
		if x.IsSolved() {
			return n
		}
		x = Compose(&x, &c)
	}
	return -1
}

func TestKnownOrders(t *testing.T) {
	tests := []struct {
		seq  string
		want int
	}{
		{"R U R' U'", 6},
		{"R U", 105},
		{"U D", 4},
		{"R L", 4},
		{"F B'", 4},
		{"R2 L2", 2},
		{"U R2 F B R B2 R U2 L B2 R U' D' R2 F R' L B2 U2 F2", 2},
	}
	for _, tc := range tests {
		if got := order(mustParse(t, tc.seq)); got != tc.want {
			t.Errorf("order(%s) = %d, want %d", tc.seq, got, tc.want)
		}
	}
}

func TestUMoveFacelets(t *testing.T) {
	// After U, F1-F3 show the colour of R, L1-L3 that of F, B1-B3 that of L
	// and R1-R3 that of B.
	c := Scrambled(mustParse(t, "U"))
	got := c.Facelets()
	// Faces in URFDLB order, 9 stickers each.
	face := func(f int) string { return got[f*9 : f*9+9] }
	if face(0) != "UUUUUUUUU" || face(3) != "DDDDDDDDD" {
		t.Errorf("U/D faces changed: %q", got)
	}
	if face(2) != "RRRFFFFFF" || face(4) != "FFFLLLLLL" || face(5) != "LLLBBBBBB" || face(1) != "BBBRRRRRR" {
		t.Errorf("unexpected facelets after U: %q", got)
	}
}

func TestSuperflip(t *testing.T) {
	c := Scrambled(mustParse(t, "U R2 F B R B2 R U2 L B2 R U' D' R2 F R' L B2 U2 F2"))
	want := New()
	for i := range want.EO {
		want.EO[i] = 1
	}
	if c != want {
		t.Fatalf("superflip mismatch: %+v", c)
	}
}

func TestEdgeOrientationConvention(t *testing.T) {
	// Only quarter turns of F and B flip edges.
	for m := Move(0); m < NumMoves; m++ {
		flips := 0
		for _, o := range MoveCube(m).EO {
			flips += int(o)
		}
		wantFlip := (m.Face() == F || m.Face() == B) && !m.IsHalfTurn()
		if (flips != 0) != wantFlip {
			t.Errorf("%v flips %d edges", m, flips)
		}
	}
}

func TestFaceletsMatchSpecCycles(t *testing.T) {
	// Apply the moves directly to a facelet array and compare with the cubie
	// model for random sequences.
	rng := rand.New(rand.NewSource(1))
	cycles := make([][][]int, NumFaces)
	for f := range cycles {
		for _, part := range strings.Split(strings.Trim(moveCycles[f], "()"), ")(") {
			cycles[f] = append(cycles[f], faceletList(strings.Fields(part)...))
		}
	}
	for trial := 0; trial < 200; trial++ {
		state := []byte(SolvedFacelets)
		c := New()
		for i := 0; i < 30; i++ {
			m := Move(rng.Intn(NumMoves))
			for k := 0; k < m.Turns(); k++ {
				prev := append([]byte(nil), state...)
				for _, cy := range cycles[m.Face()] {
					for j, a := range cy {
						state[cy[(j+1)%len(cy)]] = prev[a]
					}
				}
			}
			c.Apply(m)
		}
		if got := c.Facelets(); got != string(state) {
			t.Fatalf("trial %d: cubie model gives %s, facelet model %s", trial, got, state)
		}
	}
}

func TestFaceletRoundTrip(t *testing.T) {
	rng := rand.New(rand.NewSource(2))
	for trial := 0; trial < 200; trial++ {
		moves := make([]Move, 40)
		for i := range moves {
			moves[i] = Move(rng.Intn(NumMoves))
		}
		c := Scrambled(moves)
		back, err := FromFacelets(c.Facelets())
		if err != nil {
			t.Fatal(err)
		}
		if back != c {
			t.Fatalf("round trip mismatch: %+v vs %+v", back, c)
		}
	}
}

func TestFromFaceletsErrors(t *testing.T) {
	good := Scrambled(mustParse(t, "R U F")).Facelets()
	swap := func(s string, i, j int) string {
		b := []byte(s)
		b[i], b[j] = b[j], b[i]
		return string(b)
	}
	cases := map[string]string{
		"short":        good[:53],
		"bad char":     strings.Replace(good, "U", "x", 1),
		"moved centre": swap(good, 4, 13),
		// Swapping two edge stickers of different edges gives an impossible
		// or inconsistent cube.
		"twisted edge":   swap(SolvedFacelets, 5, 10),
		"single corner":  swap(SolvedFacelets, 8, 9),
		"duplicate":      strings.Replace(SolvedFacelets, "UUUUUUUUU", "UUUUUUUUR", 1),
		"edge flip only": swap(SolvedFacelets, 7, 19),
	}
	for name, s := range cases {
		if _, err := FromFacelets(s); err == nil {
			t.Errorf("%s: expected an error", name)
		}
	}
}

func TestVerify(t *testing.T) {
	c := New()
	c.EO[0] = 1
	if c.Verify() == nil {
		t.Error("single flipped edge accepted")
	}
	c = New()
	c.CO[0] = 1
	if c.Verify() == nil {
		t.Error("single twisted corner accepted")
	}
	c = New()
	c.EP[0], c.EP[1] = c.EP[1], c.EP[0]
	if c.Verify() == nil {
		t.Error("parity violation accepted")
	}
	c = New()
	c.CP[1] = 0
	if c.Verify() == nil {
		t.Error("non-permutation accepted")
	}
}

func TestInverse(t *testing.T) {
	rng := rand.New(rand.NewSource(3))
	for trial := 0; trial < 100; trial++ {
		moves := make([]Move, 25)
		for i := range moves {
			moves[i] = Move(rng.Intn(NumMoves))
		}
		c := Scrambled(moves)
		inv := c.Inverse()
		if r := Compose(&c, &inv); !r.IsSolved() {
			t.Fatal("c * c^-1 is not solved")
		}
		c.ApplyAll(InverseMoves(moves))
		if !c.IsSolved() {
			t.Fatal("inverse move sequence does not undo scramble")
		}
	}
}

func TestThenDoesNotMutate(t *testing.T) {
	c := New()
	d := c.Then(NewMove(R, 1))
	if !c.IsSolved() || d.IsSolved() {
		t.Error("Then mutated its receiver or did nothing")
	}
}

func TestRepeatHelper(t *testing.T) {
	if got := order(mustParse(t, repeat("R", 1))); got != 4 {
		t.Errorf("order(R) = %d", got)
	}
}
