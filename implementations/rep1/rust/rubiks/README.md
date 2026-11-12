# rubiks

A Rubik's cube solver in Rust, using Thistlethwaite's four-phase algorithm.
It is a reusable library (`rubiks`) plus a thin command-line tool of the same
name. It depends only on the standard library.

Every solution has at most 45 moves (half-turn metric: `X`, `X'`, `X2` each
count as one).

## How it works

The solver walks down the subgroup chain
`G0 = <U D L R F B> ⊃ G1 = <U D L R F2 B2> ⊃ G2 = <U D L2 R2 F2 B2> ⊃ G3 = <U2 D2 L2 R2 F2 B2> ⊃ {1}`.
Each phase maps the cube to a small coordinate identifying its coset of the
next subgroup:

| phase | goal                                | coordinate                                        | states    | moves | max depth |
|-------|-------------------------------------|---------------------------------------------------|-----------|-------|-----------|
| 1     | all edges oriented                  | edge orientation                                  | 2,048     | 18    | 7         |
| 2     | corners oriented, E-slice edges home | corner twist × E-slice edge positions            | 1,082,565 | 14    | 10        |
| 3     | corners in half-turn orbit, M-slice edges home | corner class (mod 96) × M-slice positions | 29,400   | 10    | 13        |
| 4     | solved                              | corner in half-turn group × 3 slice permutations  | 1,327,104 | 6     | 15        |

At start-up each phase fills an exact distance table by breadth-first search
from its goal; solving a cube is then only a greedy descent of those tables
(no per-scramble search). Building the tables takes well under a second.

## Build

```
./build.sh          # or: cargo build --release
```

Needs Rust 1.96 or newer (edition 2021); no external crates.

## Command line

```
./run.sh < scrambles.txt > solutions.txt
```

Input: one scramble per line, each a (possibly empty) list of space-separated
moves from `U D L R F B`, optionally followed by `'` (counter-clockwise) or
`2` (half turn). Scrambles are applied to a solved cube. Output: one line per
scramble containing a solution (at most 45 moves) that returns the cube to
solved; an already-solved cube gives an empty line. A final line without a
newline still counts as a scramble; `R\n\n` is two scrambles. On a malformed
token the tool reports the line on stderr and exits with status 1.

```
$ printf "R\nF R U'\n" | ./run.sh
R'
U R' F'
```

(Solutions are not canonical; any valid one may be printed.)

(Move names and the facelet layout follow `SPEC.md`.)

## Library

```rust
use rubiks::{format_moves, parse_moves, CubieCube, Solver};

let scramble = parse_moves("R U2 F' D L2 B").unwrap();
let cube = CubieCube::SOLVED.apply_all(&scramble);

let solver = Solver::new(); // builds the distance tables once; reuse it
let solution = solver.solve(&cube).unwrap();
assert!(cube.apply_all(&solution).is_solved());
println!("{}", format_moves(&solution));
```

Modules:

- `moves` – `Face`, `Move`, parsing and formatting of move sequences.
- `facelet` – `FaceletCube`, the 54-sticker model defined by the spec's net;
  the cubie-level move tables are derived from it.
- `cubie` – `CubieCube`, permutation/orientation of 8 corners and 12 edges,
  with validation (`verify`) and conversion to/from facelets.
- `perm`, `coord` – permutation/subset ranking and the phase coordinates.
- `phase` – the four phases (`Phase` trait: coordinate, move table, distance
  table, greedy `solve`).
- `solver` – `Solver`, chaining the phases.

## Tests

```
cargo test --release
```

Unit tests cover the helpers; integration tests (`tests/`) check the cube model
against the spec's sanity properties (move orders, superflip), cross-check the
cubie and facelet models, verify table sizes and depths (7/10/13/15), solve
thousands of random scrambles and uniformly random states, and exercise the
CLI's input/output rules. Randomness comes from a small built-in xorshift
generator, so tests are deterministic.
