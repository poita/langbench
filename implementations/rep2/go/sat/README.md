# sat

A small CDCL SAT solver in Go, with a DIMACS CNF command-line tool. It is
MiniSat-style and uses only the standard library:

- two-watched-literal unit propagation (with blocking literals),
- first-UIP conflict analysis with local clause minimisation,
- VSIDS branching (double-precision activities, a binary heap) with phase saving
  (initially false),
- Luby restarts (`100·luby(2, i)` conflicts),
- activity-based deletion of the lower half of the learnt clauses after a
  restart, keeping binary clauses.

## Layout

| Path          | Contents                                                   |
|---------------|------------------------------------------------------------|
| `*.go` (root) | package `sat`: the solver (`solver.go`, `propagate.go`, `analyze.go`, `reduce.go`, `heap.go`, `lit.go`) |
| `dimacs/`     | package `dimacs`: DIMACS parser and result writer          |
| `cmd/sat/`    | the command-line tool                                      |

## Build

```
./build.sh          # or: go build -o bin/sat ./cmd/sat
```

Run the tests with `go test ./...`.

## Command line

```
sat [file] < formula.cnf
```

Reads a DIMACS CNF formula from standard input (or from `file`) and prints
either

```
SAT
1 -2 3 0
```

(one literal per variable, then `0`) or `UNSAT`. The exit status is 0 for both
answers; malformed input prints a message on stderr and exits non-zero.
`./run.sh` runs the built binary from any directory.

## Library

```go
package main

import (
	"fmt"

	"example.com/sat"
)

func main() {
	s := sat.NewSolver()
	a, b := s.NewVar(), s.NewVar()
	s.AddClause(sat.MkLit(a, false), sat.MkLit(b, false)) // a ∨ b
	s.AddClause(sat.MkLit(a, true))                       // ¬a

	if s.Solve() == sat.Satisfiable {
		fmt.Println(s.Model()) // [false true]
	}
}
```

Variables are numbered from 0; `sat.FromDIMACS(k)` builds a literal from a
DIMACS integer. `AddClause` simplifies at the root level (duplicates,
tautologies, satisfied clauses, false literals) and returns false once the
formula is known to be unsatisfiable. Clauses may be added between `Solve`
calls. To load DIMACS text, use `dimacs.Parse` and `(*dimacs.CNF).Solver`; a
`Solver` is not safe for concurrent use.
