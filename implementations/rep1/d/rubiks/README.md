# rubiks

A Rubik's cube solver written in D. It implements Thistlethwaite's four-phase
algorithm: each phase has a small integer coordinate and an exact distance table
built by breadth-first search at start-up, and solving a cube is greedy descent
on those tables. Solutions are never longer than 7 + 10 + 13 + 15 = 45 moves (adjacent
moves of the same face at phase boundaries are merged),
and building the tables takes well under a second.

The project has two parts:

* **`rubiks` library** (`source/rubiks/`): move notation, the facelet and cubie
  models of the cube, the phase coordinates, and the `Solver`.
* **`rubiks` command-line tool** (`source/app.d`): reads one scramble per line
  on standard input, writes one solution per line on standard output.

Only the D standard library is used.

## Building

Requires LDC (tested with 1.41.0) and dub (1.40.0).

```sh
./build.sh      # same as: dub build -b release --compiler=ldc2
```

This produces `bin/rubiks`. `./run.sh` runs it from any directory.

## Command-line use

Each input line is a scramble applied to a solved cube: zero or more move
tokens separated by single spaces. The tokens are `U D L R F B`, each with an
optional `'` (counter-clockwise) or `2` (half turn). Faces and stickers follow
the unfolded-net layout in the problem statement. An empty line is a cube that
is already solved. For each line the tool prints a move sequence that returns
the cube to the solved state, using at most 45 moves; an already-solved cube
gets an empty line.

```console
$ printf "F R U'\n\nU R2 F B R B2 R U2 L B2 R U' D' R2 F R' L B2 U2 F2\n" | ./run.sh
U R' F'

F U R D B L' F U' R U' R F2 L2 D' R' U F2 U' L2 U' R2 U2 B2 D2 F2 R2 D2 L2 U2
```

(Any valid solution is acceptable, so the exact moves you see may differ.) An
invalid token makes the tool print a message on standard error and exit with
status 1.

## Library use

Add the package as a dub dependency (use the `library` configuration if you do
not want the CLI built) and import `rubiks`:

```d
import std.stdio : writeln;
import rubiks;

void main()
{
    auto solver = new Solver;                         // builds the tables once

    // From a scramble given as text...
    Move[] solution = solver.solve("R U R' U' F2 D L'");
    writeln(formatMoves(solution));

    // ...or from a cube state built by hand.
    CubieCube cube;
    cube.apply(parseMoves("B2 L F'"));
    cube.apply(solver.solve(cube));
    assert(cube.isSolved);

    // The sticker view of the same cube.
    writeln(cube.toFacelets);       // 54 letters, faces in the order U R F D L B
}
```

### Modules

| Module | Purpose |
| --- | --- |
| `rubiks.moves` | `Face`, `Move`, token parsing (`parseMove`, `parseMoves`, `MoveRange`) and formatting |
| `rubiks.facelet` | `FaceletCube`, the 54-sticker model defined by the 4-cycles of each move |
| `rubiks.cubie` | `CubieCube` (corner/edge permutation and orientation), conversions, solvability test |
| `rubiks.coord` | Phase coordinates, Lehmer and subset ranking, the half-turn corner group |
| `rubiks.movetables` | Per-component move tables (`value x move -> value`) |
| `rubiks.phases` | The four phase spaces and the BFS that fills their distance tables |
| `rubiks.solver` | `Solver` and `UnsolvableException` |

`import rubiks;` re-exports the moves, facelet, cubie and solver modules.

## Design

| Phase | Moves | Coordinate | Values |
| --- | --- | --- | --- |
| 1 | all 18 | orientation of 11 edges | 2,048 |
| 2 | no `F`/`B` quarter turns (14) | orientation of 7 corners x positions of the 4 E-slice edges | 1,082,565 |
| 3 | `U`, `D` and half turns of `L R F B` (10) | corner permutation modulo the 96 half-turn permutations (420 classes) x positions of the M-slice edges (70) | 29,400 |
| 4 | the six half turns | index of the corner permutation among the 96 x permutation of each slice (24^3) | 1,327,104 |

The cubie-level moves are not hard-coded: they are derived at compile time
from the facelet cycles. Edge orientation is defined so that only `F`/`B`
quarter turns flip edges, and corner orientation by the position of the U/D
sticker. The distance tables are flat byte arrays; BFS transitions are lookups in
per-component move tables, so no cube is built or ranked per edge. Solving
applies the scramble with one 20-element composition per move, then descends
phase by phase.

## Tests

```sh
dub test --compiler=ldc2
```

The unit tests live in `tests/`, separate from the library source. They check
the move model against the sanity checks of the specification (move orders,
superflip), compare the cubie model with the facelet model on random
sequences, verify every move table against "apply the move, then re-encode",
and check that the solver solves random, long and special scrambles within 45
moves.
