package cube_test

import (
	"fmt"

	"rubiks/cube"
)

func ExampleParseMoves() {
	moves, err := cube.ParseMoves("R U R' U'")
	if err != nil {
		panic(err)
	}
	fmt.Println(len(moves), cube.FormatMoves(cube.InverseMoves(moves)))
	// Output: 4 U R U' R'
}

func ExampleCube_Facelets() {
	c := cube.New()
	c.Apply(cube.NewMove(cube.U, 1))
	fmt.Println(c.Facelets())
	// Output: UUUUUUUUUBBBRRRRRRRRRFFFFFFDDDDDDDDDFFFLLLLLLLLLBBBBBB
}

func ExampleSimplify() {
	moves, _ := cube.ParseMoves("R R U U' R")
	fmt.Println(cube.FormatMoves(cube.Simplify(moves)))
	// Output: R'
}
