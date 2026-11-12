# sat

A conflict-driven clause-learning (CDCL) SAT solver for DIMACS CNF, written in
Haskell using only GHC's bundled libraries. It is a library plus a thin
command-line tool.

The solver follows the MiniSat design:

- two watched literals (with blocker literals) for unit propagation;
- first-UIP conflict analysis with local (non-recursive) clause minimisation;
- VSIDS branching (double-precision activities, decay 0.95 for variables and
  0.999 for clauses) with phase saving, initial phase false;
- Luby restarts (`100 * luby(2, i)` conflicts);
- learnt-clause deletion after restarts once `max_learnts` is reached
  (initially `max(inputClauses / 3, 2000)`, times 1.1 per reduction): the
  less active half is dropped, binary clauses are kept;
- root simplification of the input (duplicates, tautologies, satisfied
  clauses, falsified literals, unit propagation at level 0).

## Build

Requires GHC 9.14 and cabal 3.18.

```
./build.sh            # or: cabal build
cabal test            # unit and property tests (hspec + QuickCheck)
```

## Command-line use

`sat` reads a DIMACS CNF file on standard input and writes the answer to
standard output; the exit status is 0 for both SAT and UNSAT.

```
$ printf 'p cnf 3 2\n1 -2 0\n2 3 0\n' | ./run.sh
SAT
-1 -2 3 0
$ printf 'p cnf 2 4\n1 2 0 -1 2 0 -1 -2 0 1 -2 0\n' | ./run.sh
UNSAT
```

For a satisfiable formula the second line lists one literal per variable
`1..V` in order, followed by `0`. Any model may be printed. Comments
(`c ...`), blank lines and clauses spanning several lines are accepted.
Malformed input is reported on stderr with a non-zero exit status.

## Library use

```haskell
import Sat

main :: IO ()
main = do
  -- (x1 or not x2) and (x2 or x3) and (not x1 or not x3)
  let cnf = CNF 3 [[1, -2], [2, 3], [-1, -3]]
  case solve cnf of
    Unsat -> putStrLn "unsatisfiable"
    Sat m -> do
      print (modelLiterals m)        -- e.g. [-1,-2,3]
      print (satisfies m cnf)        -- True
```

Parsing and printing DIMACS:

```haskell
import qualified Data.ByteString.Char8 as BS
import qualified Data.ByteString.Builder as B
import Sat

solveText :: BS.ByteString -> Either String B.Builder
solveText txt = renderResult . solve <$> parseDimacs txt
```

### Modules

| Module            | Contents                                                     |
|-------------------|--------------------------------------------------------------|
| `Sat`             | Convenient re-exports: `solve`, `solveWith`, types, DIMACS   |
| `Sat.Types`       | `CNF`, `Result`, `Model`, model evaluation helpers           |
| `Sat.Dimacs`      | `parseDimacs`, `renderCNF`, `renderResult`                   |
| `Sat.Solver`      | The CDCL engine: pure `solveCNF`, mutable `ST` interface (`newSolver`, `addClause`, `solve`, `solverModel`), `Config`, `Stats` |
| `Sat.Luby`        | The Luby restart sequence                                    |

Literals follow DIMACS: `k` is variable `k` true, `-k` false, variables are
`1..V`. The internal modules (`Sat.Internal.*`: growable vectors and the
activity heap) are not exported.

## Layout

```
src/      library        app/   command-line tool        test/   test suite
```
