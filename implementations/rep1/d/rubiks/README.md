# rubiks

A Rubik's cube solver written in D, as a reusable library plus a thin
command-line tool. It implements Thistlethwaite's four-phase algorithm with an
exact distance table per phase, so every solution has at most
7 + 10 + 13 + 15 = **45 moves** (half-turn metric) and solving a scramble is a
short greedy descent with no search.

## How it works

The cube group is descended through the chain
`G0 = <U,D,L,R,F,B> > G1 = <U,D,L,R,F2,B2> > G2 = <U,D,L2,R2,F2,B2> >
G3 = <U2,D2,L2,R2,F2,B2> > {1}`. Each phase has a coordinate that identifies
the cube's coset of the next subgroup; a breadth-first search from the goal
(run once at start-up, about half a second in total) gives the exact distance
of every coordinate value:

| phase | moves | coordinate | values |
|-------|-------|------------|--------|
| 1 | all 18 | orientation of 11 edges | 2,048 |
| 2 | no F/B quarter turns (14) | orientation of 7 corners x E-slice edge positions | 2,187 x 495 |
| 3 | U/D turns + L2 R2 F2 B2 (10) | corner permutation class mod the 96 half-turn permutations x M-slice edges among the 8 U/D-layer positions | 420 x 70 |
| 4 | the six half turns | half-turn corner permutation x permutation of each edge slice | 96 x 24^3 |

Cubie-level moves are derived at compile time from the facelet cycles that
define the cube (`source/rubiks/facelets.d`), so there are no hand-written
move tables to get wrong.

## Building

Requires LDC 1.41 and dub 1.40.

```sh
./build.sh          # same as: dub build -b release --compiler=ldc2
dub test --compiler=ldc2
```

The build produces the `rubiks` executable in the project root.

## Command-line usage

`rubiks` reads scrambles from standard input, one per line, and prints one
solution per line on standard output. Tokens are `U D L R F B`, optionally
followed by `'` (counter-clockwise) or `2` (half turn). An empty line is an
already-solved cube and yields an empty solution line.

```console
$ printf "F R U'\n\nR U R' U'\n" | ./run.sh
U R' F F2

U R U' R R2
```

(The exact solution printed may differ; any sequence that returns the cube to
the solved state within 52 moves is valid.) A malformed token makes the tool
print the offending line number to standard error and exit with status 1.

Faces are numbered as in the unfolded-cube net of the problem statement
(`U` above `F`, `L F R B` in a strip, `D` below); moves turn a face clockwise
as seen from outside the cube.

## Library usage

Add the package as a dependency (`dependency "rubiks" path="../rubiks"`) and
`import rubiks;`.

```d
import std.stdio : writeln;
import rubiks;

void main()
{
    auto solver = new Solver;                  // builds the tables once
    auto scramble = parseMoves("R U2 F' D L B2");
    auto solution = solver.solve(scramble);

    writeln(formatMoves(solution));
    assert(CubieCube.fromMoves(scramble ~ solution).isSolved);
}
```

Modules (all re-exported by `import rubiks;`):

| module | responsibility |
|--------|----------------|
| `rubiks.move` | `Move`, `Face`, parsing and formatting of move notation |
| `rubiks.facelets` | the sticker model: indexing, move cycles, corner and edge facelets |
| `rubiks.cubie` | `CubieCube`: cubie permutation/orientation model, move application, legality check |
| `rubiks.coords` | coordinates with move tables (orientations, slice positions, permutation classes) |
| `rubiks.phase` | one phase: composite coordinate, BFS distance table, greedy descent |
| `rubiks.solver` | `Solver`: the four phases chained together |
| `rubiks.io` | line splitting and the scramble-per-line text format used by the CLI |

## Tests

Tests are D `unittest` blocks next to the code, run with
`dub test --compiler=ldc2`. They check, among other things, that the cubie
model agrees with an independent facelet simulation, the group-theory sanity
checks from the specification (order of `R U` is 105, superflip, ...), the
exact table sizes, reachable-state counts and maximum depths of each phase
(7, 10, 13, 15), and that thousands of random scrambles are solved in at most
45 moves.

## License

MIT, see `LICENSE`.
