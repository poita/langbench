# rubiks

A Rubik's cube solver in Clojure, using Thistlethwaite's four-phase algorithm.
It is a small library plus a command-line tool: scrambles go in, one solution
of at most 45 moves per scramble comes out.

There is no search while solving. Each phase has an *exact* distance table,
built once per run by breadth-first search from the goal over a coordinate
space; solving a phase is a greedy descent on that table.

| phase | allowed moves                    | goal                                        | coordinate space     | worst case |
|-------|----------------------------------|---------------------------------------------|----------------------|-----------:|
| 1     | all 18                           | all edges oriented                          | 2,048                | 7 moves    |
| 2     | all but quarter turns of F and B | corners oriented, E-slice edges in the slice | 2,187 × 495          | 10 moves   |
| 3     | U, D turns and L2 R2 F2 B2       | corner class in the half-turn group, M-slice edges in the slice | 420 × 70 | 13 moves |
| 4     | the six half turns               | solved                                      | 96 × 24³             | 15 moves   |

The tables are built in about a second (the four phases in parallel); after
that a scramble costs a few milliseconds.

## Requirements

Java and the [Clojure CLI](https://clojure.org/guides/install_clojure)
(`clojure`), Clojure 1.12.6. Nothing but the standard library is used; the
tests additionally use `org.clojure/test.check` and the Cognitect test runner.

## Build

```
./build.sh
```

AOT-compiles the command-line tool into `classes/` (a start-up speed-up only;
everything also works straight from the sources).

## Command-line use

```
./run.sh < scrambles.txt > solutions.txt
```

Input: one scramble per line, each a space-separated list of the eighteen
tokens `U D L R F B`, `U' D' L' R' F' B'`, `U2 D2 L2 R2 F2 B2` (an empty line is
a cube that is already solved). Output: one line per scramble, a solution in
the same notation with at most 45 moves; an empty line for a solved cube. The
scramble is applied to a solved cube, then the solution to that.

```
$ printf 'R\n\nF R U\x27\n' | ./run.sh
R'

U R' F'
```

A malformed token makes the program print `error: ...` to standard error and
exit with status 1; otherwise the exit status is 0.

The conventions are those of the problem statement: `U R F D L B` are the six
faces, a bare letter is a clockwise quarter turn seen from outside that face,
and facelets are numbered 1-9 in reading order on the standard unfolded net
(`U` above `F`, `L F R B` in a row, `D` below).

## Library use

```clojure
(require '[rubiks.cubie :as cubie]
         '[rubiks.moves :as moves]
         '[rubiks.solver :as solver])

;; the cube after a scramble (a map of cubie positions and orientations)
(def cube (cubie/scramble (moves/parse "F R U' L2 B D'")))

(def solution (solver/solve cube))
;; => ["D" "B'" ...]  a vector of tokens, at most 45 long

(cubie/solved? (cubie/apply-moves cube solution))   ;; => true

;; shortcut from a scramble, and printing
(moves/unparse (solver/solve-scramble ["R" "U"]))   ;; => "U' R'"

;; per-phase solutions, and explicit tables if you want to control when they
;; are built
(def tables (rubiks.tables/build))
(solver/solve-phases tables cube)                   ;; => [[..] [..] [..] [..]]

;; facelet strings (U R F D L B, nine stickers each) convert both ways
(cubie/->facelets cube)
(solver/solve (cubie/from-facelets "UUUUUUUUURRRRRRRRRFFFFFFFFFDDDDDDDDDLLLLLLLLLBBBBBBBBB"))
```

### Modules

| namespace         | responsibility                                                            |
|-------------------|---------------------------------------------------------------------------|
| `rubiks.moves`    | move tokens and ids, parsing/printing, inversion, simplification          |
| `rubiks.facelet`  | the specification's 54-sticker model; slow reference implementation       |
| `rubiks.cubie`    | cubie model (`:cp :co :ep :eo`), move application, conversion, solvability |
| `rubiks.coords`   | the small coordinates (orientation, slice positions, corner classes, ...) |
| `rubiks.phases`   | the four phases: move sets and the coordinates making up each             |
| `rubiks.tables`   | breadth-first distance tables, `build`, `default-tables`                  |
| `rubiks.solver`   | `solve`, `solve-phases`, `solve-scramble`                                 |
| `rubiks.cli`      | the command-line tool                                                     |

The cubie move effects are derived from the facelet cycle definitions when the
library loads, so the specification's tables are the only hand-typed model.

## Tests

```
clojure -M:test                       # all tests
clojure -M:test -n rubiks.solver-test # one namespace
```

They cover the specification's sanity checks (move orders, superflip), the
agreement of the cubie and facelet models, every coordinate transition against
real cube moves, the exact table depths (7, 10, 13, 15), solver properties on
random scrambles (checked on the independent facelet model), and the
command-line parsing edge cases.
