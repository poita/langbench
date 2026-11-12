# rubiks

A Rubik's cube solver in C++20. It implements Thistlethwaite's four-phase
algorithm with an exact distance table per phase, so every cube is solved in at
most 7 + 10 + 13 + 15 = 45 moves by a pure table descent (no search per cube).
It uses only the standard library; GoogleTest is needed only for the tests.

The project is a reusable library (`rubiks::rubiks`) plus a thin command-line
tool that reads scrambles from stdin and prints solutions.

## Layout

| Path | Responsibility |
| --- | --- |
| `include/rubiks/move.hpp` | the 18 moves, parsing and formatting of notation |
| `include/rubiks/facelet.hpp` | 54-sticker cube model (the reference definition of the moves) |
| `include/rubiks/cubie.hpp` | cubie model (permutation + orientation), validity check, conversion to/from stickers |
| `include/rubiks/solver.hpp` | `Solver` / `Solution` |
| `include/rubiks/rubiks.hpp` | umbrella header |
| `src/coordinates.*` | (private) phase coordinates and their move tables |
| `src/phase_tables.*` | (private) the four phases and their BFS distance tables |
| `cli/main.cpp` | the command-line tool |
| `tests/` | GoogleTest unit tests |
| `examples/solve_one.cpp` | minimal library usage |

## Algorithm

| Phase | Moves | Coordinate | Size | Worst case |
| --- | --- | --- | --- | --- |
| 1 | all 18 | orientation of 11 edges | 2,048 | 7 |
| 2 | no F/B quarter turns (14) | 7 corner orientations x E-slice edge positions | 2,187 x 495 | 10 |
| 3 | U/D turns, L2 R2 F2 B2 (10) | corner coset mod the 96 half-turn corner permutations x M-slice edge positions | 420 x 70 | 13 |
| 4 | the six half turns | corner permutation in that group x permutation of each edge slice | 96 x 24^3 | 15 |

At start-up each phase's table is filled by breadth-first search from its goal
(well under a second in total). Solving a scramble applies it to a solved cube
and then, phase by phase, repeatedly takes a move whose successor is one step
closer to the goal.

## Build

Requires a C++20 compiler and CMake >= 3.20; GoogleTest is optional (tests are
skipped with a warning if it is not found).

```sh
./build.sh                      # Release build into ./build
# or by hand
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release && cmake --build build
ctest --test-dir build          # run the unit tests
```

## Command line

`./run.sh` (or `build/rubiks`) reads N scrambles on stdin, one per line, each
a space-separated list of moves from `U D L R F B`, optionally suffixed with
`'` (counter-clockwise) or `2` (half turn). For each scramble it prints one
line: a move sequence (not necessarily optimal; adjacent moves of one face
are not merged, e.g. `F F2`) that returns a cube scrambled that way to solved. An
empty line is a solved cube and yields an empty line.

```console
$ printf 'F R U'"'"'\n\nR U R'"'"' U'"'"'\n' | ./run.sh
U R' F F2

U R U' R R2
```

Notation and the cube model (face orientation, sticker numbering, move
definitions) follow `problems/rubiks/SPEC.md`. A line with an invalid token
makes the program exit with status 1.

## Library example

```cpp
#include <iostream>
#include "rubiks/rubiks.hpp"

int main() {
  rubiks::Solver solver;                          // builds the tables once

  auto scramble = rubiks::parseMoves("R U F' D2 L B'");
  rubiks::Solution s = solver.solve(*scramble);   // at most 45 moves
  std::cout << rubiks::toString(s.moves) << '\n';

  // Verify at sticker level, independently of the solver's model:
  rubiks::FaceletCube cube;
  cube.apply(*scramble);
  cube.apply(s.moves);
  std::cout << (cube.isSolved() ? "solved" : "not solved") << '\n';
}
```

Link with the `rubiks::rubiks` target (`target_link_libraries(app PRIVATE rubiks::rubiks)`
after `add_subdirectory(rubiks)`). Cubes supplied as stickers can be converted
with `CubieCube::fromFacelets`; `Solver::solve` throws `std::invalid_argument`
for an unreachable state (`CubieCube::isValid()` checks this).
