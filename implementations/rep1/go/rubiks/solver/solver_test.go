package solver

import (
	"math/rand"
	"sync"
	"testing"

	"rubiks/cube"
)

var shared = New()

func randomMoves(rng *rand.Rand, n int) []cube.Move {
	moves := make([]cube.Move, n)
	for i := range moves {
		moves[i] = cube.Move(rng.Intn(cube.NumMoves))
	}
	return moves
}

func checkSolves(t *testing.T, c cube.Cube) []cube.Move {
	t.Helper()
	sol, err := shared.Solve(c)
	if err != nil {
		t.Fatalf("Solve: %v", err)
	}
	if len(sol) > MaxMoves {
		t.Errorf("solution has %d moves, more than %d", len(sol), MaxMoves)
	}
	d := c
	d.ApplyAll(sol)
	if !d.IsSolved() {
		t.Errorf("solution %s does not solve the cube", cube.FormatMoves(sol))
	}
	return sol
}

func TestSolved(t *testing.T) {
	if sol := checkSolves(t, cube.New()); len(sol) != 0 {
		t.Errorf("solved cube needs %d moves", len(sol))
	}
}

func TestSingleMoves(t *testing.T) {
	for m := cube.Move(0); m < cube.NumMoves; m++ {
		sol := checkSolves(t, cube.Scrambled([]cube.Move{m}))
		if len(sol) != 1 {
			t.Errorf("single move %v solved in %d moves", m, len(sol))
		}
	}
}

func TestSuperflip(t *testing.T) {
	moves, _ := cube.ParseMoves("U R2 F B R B2 R U2 L B2 R U' D' R2 F R' L B2 U2 F2")
	checkSolves(t, cube.Scrambled(moves))
}

func TestRandomScrambles(t *testing.T) {
	rng := rand.New(rand.NewSource(42))
	for i := 0; i < 300; i++ {
		checkSolves(t, cube.Scrambled(randomMoves(rng, 25+rng.Intn(1000))))
	}
}

func TestRandomStates(t *testing.T) {
	// Uniformly random legal states, built directly from random cubie data.
	rng := rand.New(rand.NewSource(7))
	for i := 0; i < 300; i++ {
		c := cube.New()
		for j := 7; j > 0; j-- {
			k := rng.Intn(j + 1)
			c.CP[j], c.CP[k] = c.CP[k], c.CP[j]
		}
		for j := 11; j > 0; j-- {
			k := rng.Intn(j + 1)
			c.EP[j], c.EP[k] = c.EP[k], c.EP[j]
		}
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
		c.EO[11] = uint8(sum & 1)
		if c.Verify() != nil { // fix parity with a swap of two edges
			c.EP[0], c.EP[1] = c.EP[1], c.EP[0]
		}
		checkSolves(t, c)
	}
}

func TestInvalidCube(t *testing.T) {
	c := cube.New()
	c.EO[0] = 1
	if _, err := shared.Solve(c); err == nil {
		t.Error("expected an error for a cube with one flipped edge")
	}
}

func TestConcurrentUse(t *testing.T) {
	s := New()
	var wg sync.WaitGroup
	for g := 0; g < 4; g++ {
		wg.Add(1)
		go func(seed int64) {
			defer wg.Done()
			rng := rand.New(rand.NewSource(seed))
			for i := 0; i < 20; i++ {
				c := cube.Scrambled(randomMoves(rng, 30))
				sol, err := s.Solve(c)
				if err != nil {
					t.Error(err)
					return
				}
				c.ApplyAll(sol)
				if !c.IsSolved() {
					t.Error("not solved")
					return
				}
			}
		}(int64(g))
	}
	wg.Wait()
}

func TestPackageLevelSolve(t *testing.T) {
	c := cube.Scrambled([]cube.Move{cube.NewMove(cube.R, 1), cube.NewMove(cube.U, 3)})
	sol, err := Solve(c)
	if err != nil {
		t.Fatal(err)
	}
	c.ApplyAll(sol)
	if !c.IsSolved() {
		t.Error("not solved")
	}
}
