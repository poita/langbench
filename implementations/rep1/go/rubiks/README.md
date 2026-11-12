# rubiks

A Rubik's cube solver in Go, using only the standard library.

It solves any 3x3x3 cube with Thistlethwaite's four-phase algorithm. Each phase
has an exact distance table over its own coordinate space, built once by
breadth-first search from the goal. A solution is found by greedy descent
through the tables, with no search per cube, so every phase is optimal and a
solution has at most 7 + 10 + 13 + 15 = 45 moves (half-turn metric).

| Phase | Moves | Coordinate | Values | Max depth |
|-------|-------|------------|--------|-----------|
| 1 | all 18 | orientation of 11 edges | 2,048 | 7 |
| 2 | no F/B quarter turns (14) | 7 corner orientations x E-slice edge positions | 2,187 x 495 | 10 |
| 3 | U/D turns, L2 R2 F2 B2 (10) | corner permutation class mod the 96 half-turn corner permutations x M-slice edge positions | 420 x 70 | 13 |
| 4 | six half turns | half-turn corner permutation x permutation of each edge slice | 96 x 24^3 | 15 |

## Layout

- `cube/` - cube model: moves and their notation, the cubie-level `Cube`
  type, conversion to and from 54-sticker facelet strings, validation.
- `solver/` - coordinates, distance tables and the `Solver`.
- `cmd/rubiks/` - the command-line tool.

## Build

Requires Go 1.27 or later.

```
./build.sh          # writes bin/rubiks
go test ./...       # run the tests
```

## Command line

`rubiks` reads scrambles from standard input, one per line, and writes one
solution per line to standard output. Moves are `U D L R F B`, each optionally
followed by `'` (anticlockwise) or `2` (half turn), separated by single spaces;
an empty line is the solved cube and gets an empty solution line.

```
$ printf 'F R U\x27\n\nR\n' | ./run.sh
U R' F F2

R R2
```

(Solutions are valid but not minimal: each phase is optimal, the concatenation is not.) Face
turns are clockwise as seen looking at the face; the facelet numbering and
sticker layout are documented in the `cube` package. The exit status is 0 on
success, 1 if the input contains an invalid token.

## Library

```go
package main

import (
	"fmt"

	"example.com/rubiks/cube"
	"example.com/rubiks/solver"
)

func main() {
	scramble, err := cube.ParseMoves("U R2 F B R B2 R U2 L B2 R U' D' R2 F R' L B2 U2 F2")
	if err != nil {
		panic(err)
	}
	c := cube.Solved()
	c.ApplyAll(scramble)

	s := solver.New() // builds the distance tables once; reuse it
	solution, err := s.Solve(c)
	if err != nil {
		panic(err)
	}
	fmt.Println(cube.FormatMoves(solution))

	c.ApplyAll(solution)
	fmt.Println(c.IsSolved()) // true
}
```

A cube can also be built from a 54-letter facelet string with
`cube.FromFacelets` (order U1..U9, R1..R9, F1..F9, D1..D9, L1..L9, B1..B9) and
checked with `Cube.Validate` before solving. `Solver` is immutable after
`solver.New` and safe for concurrent use.
