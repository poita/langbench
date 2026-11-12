package solver

import (
	"math/rand"
	"sync"
	"testing"

	"example.com/rubiks/cube"
)

var (
	once sync.Once
	slv  *Solver
)

func testSolver() *Solver {
	once.Do(func() { slv = New() })
	return slv
}

func TestPhaseDepths(t *testing.T) {
	got := testSolver().PhaseDepths()
	want := [4]int{7, 10, 13, 15}
	if got != want {
		t.Errorf("PhaseDepths = %v, want %v", got, want)
	}
}

func TestMoveSetSizes(t *testing.T) {
	sizes := [4]int{len(phase1Moves), len(phase2Moves), len(phase3Moves), len(phase4Moves)}
	if want := [4]int{18, 14, 10, 6}; sizes != want {
		t.Errorf("move set sizes = %v, want %v", sizes, want)
	}
}

func TestCornerGroup(t *testing.T) {
	g := newCornerGroup()
	if len(g.elems) != 96 {
		t.Fatalf("|H| = %d", len(g.elems))
	}
	id := cube.Solved().CP
	if g.coset[permRank(id[:])] != g.coset[permRank(g.elems[17][:])] {
		t.Error("elements of H are in different cosets")
	}
}

func TestPermRankRoundTrip(t *testing.T) {
	var p [8]uint8
	for r := 0; r < nPerm8; r += 7 {
		permUnrank(r, 8, p[:])
		if permRank(p[:]) != r {
			t.Fatalf("rank %d did not round trip", r)
		}
	}
}

func checkSolve(t *testing.T, scramble []cube.Move) {
	t.Helper()
	c := cube.Solved()
	c.ApplyAll(scramble)
	sol, err := testSolver().Solve(c)
	if err != nil {
		t.Fatalf("Solve(%s): %v", cube.FormatMoves(scramble), err)
	}
	if len(sol) > MaxSolutionLength {
		t.Errorf("solution has %d moves, more than %d", len(sol), MaxSolutionLength)
	}
	c.ApplyAll(sol)
	if !c.IsSolved() {
		t.Errorf("solution %s does not solve %s", cube.FormatMoves(sol), cube.FormatMoves(scramble))
	}
}

func TestSolveRandom(t *testing.T) {
	rng := rand.New(rand.NewSource(42))
	n := 300
	if testing.Short() {
		n = 30
	}
	for i := 0; i < n; i++ {
		scramble := make([]cube.Move, 25+rng.Intn(1000))
		for j := range scramble {
			scramble[j] = cube.Move(rng.Intn(cube.NumMoves))
		}
		checkSolve(t, scramble)
	}
}

func TestSolveSpecial(t *testing.T) {
	for _, s := range []string{
		"",
		"R",
		"R'",
		"R2",
		"F R U'",
		"R U R' U' R U R' U' R U R' U' R U R' U' R U R' U' R U R' U'",
		// superflip
		"U R2 F B R B2 R U2 L B2 R U' D' R2 F R' L B2 U2 F2",
		// checkerboard
		"U2 D2 R2 L2 F2 B2",
	} {
		scramble, err := cube.ParseMoves(s)
		if err != nil {
			t.Fatal(err)
		}
		checkSolve(t, scramble)
	}
}

func TestSolveRandomStates(t *testing.T) {
	// Random cubes built from random permutations/orientations, not scrambles.
	rng := rand.New(rand.NewSource(7))
	for i := 0; i < 100; i++ {
		c := cube.Solved()
		rng.Shuffle(8, func(a, b int) { c.CP[a], c.CP[b] = c.CP[b], c.CP[a] })
		rng.Shuffle(12, func(a, b int) { c.EP[a], c.EP[b] = c.EP[b], c.EP[a] })
		sum := 0
		for j := 0; j < 7; j++ {
			c.CO[j] = uint8(rng.Intn(3))
			sum += int(c.CO[j])
		}
		c.CO[7] = uint8((3 - sum%3) % 3)
		sum = 0
		for j := 0; j < 11; j++ {
			c.EO[j] = uint8(rng.Intn(2))
			sum += int(c.EO[j])
		}
		c.EO[11] = uint8(sum % 2)
		if c.Validate() != nil {
			// fix parity with a swap of two edges
			c.EP[0], c.EP[1] = c.EP[1], c.EP[0]
		}
		sol, err := testSolver().Solve(c)
		if err != nil {
			t.Fatal(err)
		}
		c.ApplyAll(sol)
		if !c.IsSolved() || len(sol) > MaxSolutionLength {
			t.Fatalf("bad solution of length %d", len(sol))
		}
	}
}

func TestSolveRejectsInvalid(t *testing.T) {
	c := cube.Solved()
	c.CO[0] = 1
	if _, err := testSolver().Solve(c); err == nil {
		t.Error("Solve accepted an unsolvable cube")
	}
}

func BenchmarkSolve(b *testing.B) {
	s := testSolver()
	rng := rand.New(rand.NewSource(1))
	cubes := make([]cube.Cube, 64)
	for i := range cubes {
		cubes[i] = cube.Solved()
		for j := 0; j < 25; j++ {
			cubes[i].Apply(cube.Move(rng.Intn(cube.NumMoves)))
		}
	}
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		if _, err := s.Solve(cubes[i%len(cubes)]); err != nil {
			b.Fatal(err)
		}
	}
}

func BenchmarkNew(b *testing.B) {
	for i := 0; i < b.N; i++ {
		New()
	}
}
