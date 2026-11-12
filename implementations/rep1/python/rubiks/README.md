# rubiks

A Rubik's cube solver in pure Python (standard library only). It reads
scrambles, one per line, and prints for each a move sequence that solves the
cube, using **Thistlethwaite's four-phase algorithm** with an exact distance
table per phase. Every solution has at most 7 + 10 + 13 + 15 = 45 moves
(half-turn metric).

## How it works

The cube is walked down the subgroup chain `G0 > G1 > G2 > G3 > {1}`. Each
phase has a small coordinate identifying the cube's coset of the next
subgroup, and a table of exact distances to the goal coordinate built once by
breadth-first search. Solving is a greedy descent: repeatedly take an allowed
move that decreases the table distance. No per-scramble search is done.

| Phase | Coordinate | Size | Moves |
|-------|------------|------|-------|
| 1 | orientation of 11 edges | 2,048 | all 18 |
| 2 | 7 corner twists x E-slice edge positions | 1,082,565 | 14 (no `F`/`B` quarter turns) |
| 3 | corner class mod the 96 half-turn corner permutations x M-slice positions among the 8 U/D-layer edge slots | 29,400 | `U` `D` turns + `L2 R2 F2 B2` |
| 4 | corner permutation (96) x permutation of each edge slice (24^3) | 1,327,104 | the six half turns |

Tables are built lazily (about a second in total) and shared by all scrambles
in a run.

## Layout

```
src/rubiks/
  model.py      facelets, cubie slots and the 18 moves (derived from the facelet cycles)
  notation.py   parse / format / invert move sequences
  cube.py       Cube: cubie-level state, move application, facelet export
  coords.py     the four phase coordinate spaces and their move tables
  tables.py     breadth-first distance tables
  solver.py     Solver: greedy descent through the four phases
  cli.py        stdin/stdout command-line tool
tests/          pytest suite
build.sh run.sh pyproject.toml
```

## Build

```
./build.sh          # byte-compiles src/ (no dependencies, no install step)
```

The project can also be installed in the usual way with `pip install .`
(Python >= 3.10); this provides a `rubiks` console script.

## Command line

```
./run.sh < scrambles.txt > solutions.txt
# or, without run.sh:
PYTHONPATH=src python3 -m rubiks < scrambles.txt
```

Each input line is a scramble of space-separated tokens from
`U D L R F B`, optionally followed by `'` or `2` (an empty line is the
already-solved cube). Each output line is a solution to the corresponding
scramble, in the same notation (empty for a solved cube). A final newline in
the input is optional; `R\n\n` is two scrambles. Moves follow the facelet
model in `problems/rubiks/SPEC.md`. An invalid token makes the tool print an
error to stderr and exit with status 1.

```
$ echo "F R U'" | ./run.sh
U R' F F2
```

## Library

```python
from rubiks import Cube, Solver, solve, invert_moves

# One-shot: uses a shared, lazily built solver.
print(" ".join(solve("R U R' U' F2")))

# Explicit control
solver = Solver()                      # tables built on first use (or solver.build_all())
cube = Cube.from_moves("F R U' B2 L")  # a solved cube with moves applied
solution = solver.solve(cube)          # list of tokens; cube is not modified
cube.apply_moves(solution)
assert cube.is_solved()

print(cube.to_facelets())              # 54 chars, faces in U R F D L B order
```

Public names: `Cube` (`from_moves`, `apply`, `apply_moves`, `copy`,
`is_solved`, `to_facelets`, attributes `cp co ep eo`), `Solver` (`solve`,
`solve_scramble`, `build_all`), `solve`, `default_solver`, `parse_moves`,
`format_moves`, `invert_moves`.

## Tests

```
python3 -m pytest            # uses pythonpath = src from pyproject.toml
```

The suite cross-checks the cubie model against an independent facelet-level
simulator, checks move orders and the superflip from the specification,
verifies phase table sizes and depths (7 / 10 / 13 / 15), and solves known and
random scrambles (including a 1000-move one) and exercises the CLI.
