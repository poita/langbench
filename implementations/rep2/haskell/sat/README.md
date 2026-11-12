# cdcl-sat

A conflict-driven clause-learning (CDCL) SAT solver for DIMACS CNF, written in
Haskell using only GHC's bundled packages (`base`, `array`, `bytestring`).
It ships as a library plus a small command-line tool.

The solver follows the MiniSat design:

- two-watched-literal unit propagation with blocking literals;
- first-UIP conflict analysis with local clause minimisation;
- VSIDS branching (activity decay 0.95, rescaling) on an indexed binary heap,
  with phase saving (initial phase: false);
- Luby restarts (`100 * luby(2, i)` conflicts);
- learnt-clause deletion after a restart once `max_learnts` is reached
  (halving by activity, binary clauses kept, `max_learnts` grows by 1.1×);
- root-level simplification of input clauses (duplicates, tautologies,
  satisfied clauses, false literals, unit propagation).

## Build

Requires GHC 9.14.1 and cabal 3.18.2.0.

```sh
./build.sh          # cabal build, then copies the executable to bin/sat
cabal test          # runs the hspec/QuickCheck suite
```

## Command-line use

`run.sh` (or `bin/sat`) reads a DIMACS CNF on standard input:

```sh
$ printf 'p cnf 3 2\n1 -2 0\n2 3 0\n' | ./run.sh
SAT
-1 -2 3 0
$ printf 'p cnf 1 2\n1 0\n-1 0\n' | ./run.sh
UNSAT
```

Output is `UNSAT`, or `SAT` followed by one line with a literal for every
variable `1..V` in order and a terminating `0`. Exit status is 0 for both
answers; a malformed input prints a message on stderr and exits with 2.

## Library use

```haskell
import qualified Data.ByteString.Char8 as BS
import Sat

main :: IO ()
main = do
  -- Build a formula directly: (x1 ∨ ¬x2) ∧ (x2 ∨ x3)
  case solve (CNF 3 [[1, -2], [2, 3]]) of
    Satisfiable m -> print (modelLiterals m)      -- e.g. [-1,-2,3]
    Unsatisfiable -> putStrLn "unsatisfiable"

  -- Or parse DIMACS text and render the standard output format
  case parseDimacs (BS.pack "p cnf 1 2\n1 0\n-1 0\n") of
    Left err  -> putStrLn err
    Right cnf -> putStr (show (solve cnf))         -- Unsatisfiable
```

### Modules

| Module | Purpose |
| --- | --- |
| `Sat` | Convenience re-export of everything below |
| `Sat.Types` | `Lit`, `Clause`, `CNF`, `Model`, `Result`, model queries (`satisfies`, `modelLiterals`) |
| `Sat.Dimacs` | `parseDimacs` (strict, returns `Either String CNF`) and `renderResult` |
| `Sat.Solver` | pure `solve`; and the `ST`-based `newSolver` / `addClause` / `solveSolver` |

Literals are DIMACS integers: `k` is variable `k` true, `-k` false (`1 <= k <= V`).
Models always assign every variable `1..V`, including unused ones.
`Sat.Solver` internals live in `Sat.Internal.*` and are not exported.

## Layout

```
src/Sat/…      library
app/Main.hs    command-line tool
test/Spec.hs   hspec + QuickCheck tests (parser, renderer, solver, brute-force cross-check)
build.sh, run.sh
```
