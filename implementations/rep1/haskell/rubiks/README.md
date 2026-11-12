# rubiks

A Rubik's cube solver in Haskell, built on Thistlethwaite's four-phase
algorithm. It is a reusable library plus a thin command-line tool.

Each phase has a small coordinate space that identifies the cube's coset of
the next subgroup in the chain `G0 > G1 > G2 > G3 > G4 = {1}`:

| phase | moves allowed                         | coordinate                                          | size      | max moves |
|-------|---------------------------------------|-----------------------------------------------------|-----------|-----------|
| 1     | all 18                                | orientation of 11 edges                             | 2,048     | 7         |
| 2     | all except `F`/`B` quarter turns (14) | 7 corner twists x E-slice edge positions            | 1,082,565 | 10        |
| 3     | `U`/`D` turns, `L2 R2 F2 B2` (10)     | corner coset mod half-turn group x M-slice edges    | 29,400    | 13        |
| 4     | the six half turns                    | corner permutation (of 96) x edge slice permutations| 1,327,104 | 15        |

At start-up each phase's distance table is filled by breadth-first search from
the goal. A scramble is then solved by greedy descent through the four tables,
with no search per cube. Every phase is optimal, so a solution has at most
7 + 10 + 13 + 15 = 45 moves (half-turn metric: `X`, `X'` and `X2` each count
as one). Building the tables takes a fraction of a second.

## Building

Requires GHC 9.14.1 and cabal 3.18.2.0.

```
./build.sh            # builds with cabal and copies the executable to bin/rubiks
cabal build           # library, executable and tests
cabal test            # runs the test suite (hspec + QuickCheck)
```

## Command-line usage

`rubiks` (or `./run.sh`) reads scrambles from standard input, one per line,
and prints one solution per line. Each scramble is applied to a freshly solved
cube; the solution is a sequence of moves that returns the cube to the solved
state. An empty line is the empty scramble and gets an empty solution line.

```
$ printf "R\n\nF R U'\n" | ./run.sh
R'

U R' F'
```

Moves are `U D L R F B`, optionally followed by `'` (counter-clockwise) or `2`
(half turn), separated by single spaces. Clockwise is as seen looking at that
face from outside the cube. Invalid input is reported on standard error with
exit status 1.

The cube model, including the sticker numbering of each face, is described in
the module documentation of `Rubiks.Facelet` and `Rubiks.Cube`.

## Library

| module                | contents                                                       |
|-----------------------|----------------------------------------------------------------|
| `Rubiks`              | re-exports the public API, plus `solveScramble`                |
| `Rubiks.Move`         | `Face`, `Turn`, `Move`, notation parsing and rendering, inverses |
| `Rubiks.Facelet`      | the 54-sticker model and the move cycles it is derived from    |
| `Rubiks.Cube`         | the cubie model: `Cube`, `applyMove`, `isSolvable`, facelet conversion |
| `Rubiks.Solver`       | `newSolver`, `solve`, `solvePhases`                            |
| `Rubiks.Internal.*`   | coordinates, phases and BFS tables (not a stable API)          |

```haskell
import Rubiks

main :: IO ()
main = do
  let Right scramble = parseMoves "R U R' U' F2 D L"
      cube = applyMoves scramble solved
      Just solution = solve newSolver cube   -- Nothing if the cube is unsolvable
  putStrLn (renderMoves solution)
  print (isSolved (applyMoves solution cube))   -- True
```

`newSolver` is a lazily built value: the distance tables are computed the first
time it is used and shared afterwards, so bind it once (e.g. at top level) and
reuse it. Cubes can also be read from a facelet colouring with
`fromFacelets`, which rejects colourings no real cube can show; `solve`
returns `Nothing` for a cube that is not solvable (twisted corner, flipped
edge, swapped pair).

## Tests

`cabal test` runs the hspec suite: the specification's sanity checks (orders
of move sequences, the superflip), agreement between the cubie and facelet
models, coordinate encode/decode round trips, agreement of each phase's
transition function with the cube, and QuickCheck properties that random
scrambles are solved within 45 moves, phase by phase.
