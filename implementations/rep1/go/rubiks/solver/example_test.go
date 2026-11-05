package solver_test

import (
	"fmt"

	"rubiks/cube"
	"rubiks/solver"
)

func Example() {
	scramble, _ := cube.ParseMoves("R U R' U'")
	c := cube.Scrambled(scramble)

	solution, err := solver.Solve(c)
	if err != nil {
		panic(err)
	}
	fmt.Println(len(solution) <= solver.MaxMoves)

	c.ApplyAll(solution)
	fmt.Println(c.IsSolved())
	// Output:
	// true
	// true
}
