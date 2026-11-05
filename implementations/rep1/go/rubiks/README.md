# rubiks

A Rubik's cube library and command-line solver in Go, standard library only.
It solves any 3x3x3 cube with Thistlethwaite's four-phase algorithm: exact
distance tables per phase, built by breadth-first search at start-up, and
greedy descent through them. Solutions have at most 45 moves (7 + 10 + 13 + 15)
in the half-turn metric, and a solve takes microseconds once the tables exist
(building them takes about 0.1 s).

## Layout

| Path            | Contents                                                              |
|-----------------|-----------------------------------------------------------------------|
| `cube/`         | Cube model: `Move` notation, cubie-level `Cube`, facelet conversion.  |
| `solver/`       | Thistlethwaite solver: coordinates, move tables, BFS tables, descent. |
| `cmd/rubiks/`   | Command-line tool (reads scrambles on stdin, writes solutions).       |
| `build.sh`      | Builds `bin/rubiks`.                                                  |
| `run.sh`        | Runs the built binary from any directory.                             |

## Build and test

Requires Go 1.27.1 or newer.

```
./build.sh          # or: go build -o bin/rubiks ./cmd/rubiks
go test ./...
```

## Command-line use

`rubiks` reads scrambles from standard input, one per line, and prints one
solution per line. Each scramble is applied to a solved cube; it consists of
zero or more space-separated tokens from `U D L R F B`, each optionally
followed by `'` (counter-clockwise) or `2` (half turn). An empty line is the
solved cube and gets an empty solution line.

```
$ printf "R\n\nF R U'\n" | ./run.sh
R'

U R' F'
```

(Any valid solution may be printed, so the second and third lines of your
output can differ from the above.) Invalid input makes the program exit with a
message on stderr and status 1.

## Library use

```go
package main

import (
	"fmt"

	"rubiks/cube"
	"rubiks/solver"
)

func main() {
	scramble, err := cube.ParseMoves("R U2 F' D L2 B")
	if err != nil {
		panic(err)
	}
	c := cube.Scrambled(scramble) // a solved cube with the scramble applied

	solution, err := solver.Solve(c)
	if err != nil {
		panic(err) // only for unreachable cubes
	}
	fmt.Println(cube.FormatMoves(solution))

	c.ApplyAll(solution)
	fmt.Println(c.IsSolved()) // true
}
```

### API summary

Package `cube`:

- `Move`, `Face`, `NewMove`, `ParseMove`, `ParseMoves`, `FormatMoves`,
  `InverseMoves`, `Simplify` — move notation and sequences.
- `Cube` — cubie state (`CP`, `CO`, `EP`, `EO`); `New`, `Scrambled`,
  `Apply`, `ApplyAll`, `Then`, `Compose`, `Inverse`, `IsSolved`, `Verify`.
- `Cube.Facelets` / `FromFacelets` — convert to and from the 54-character
  sticker string (faces in order `U R F D L B`, stickers numbered 1-9 in
  reading order of the standard unfolded net; see the package docs).

Package `solver`:

- `Solver` (`New`, `Prepare`, `Solve`) and the package-level `Solve` using a
  shared default solver. Tables are built lazily on first use; a `Solver` is
  safe for concurrent use.

## Design notes

The cube is held as corner and edge permutation/orientation. The move cubies
are derived at start-up from the facelet cycles that define the six turns, so
the facelet and cubie models cannot disagree (the tests also cross-check them
on random sequences). Each phase coordinate is a pair of small components, each
with a precomputed move table:

| Phase | Moves | Coordinate                                         | Size      |
|-------|-------|----------------------------------------------------|-----------|
| 1     | 18    | edge orientation                                   | 2,048     |
| 2     | 14    | corner twist x E-slice edge positions              | 1,082,565 |
| 3     | 10    | corner coset (mod half-turn group) x M-slice edges | 29,400    |
| 4     | 6     | half-turn corner index x slice permutations        | 1,327,104 |
