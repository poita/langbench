# sat

A CDCL SAT solver in Go: a reusable library plus a small command-line tool
that reads DIMACS CNF and prints a satisfying assignment or `UNSAT`. Standard
library only.

The solver is MiniSat-style: two watched literals, first-UIP clause learning
with local minimisation, VSIDS branching (indexed binary heap), phase saving,
Luby restarts (unit 100 conflicts) and activity-based learnt-clause
reduction. It is fully deterministic.

## Layout

| File | Responsibility |
|------|----------------|
| `doc.go` | package documentation |
| `cnf.go` | `CNF` type, DIMACS parser, model checking, `Solve` convenience |
| `solver.go` | the `Solver`: clause database, propagation, analysis, search, reduction |
| `heap.go` | indexed max-heap for VSIDS |
| `luby.go` | Luby restart sequence |
| `output.go` | `SAT`/`UNSAT` result writer |
| `cmd/sat` | the command-line tool |

## Build

```
./build.sh          # or: go build -o bin/sat ./cmd/sat
go test ./...       # unit tests
```

## Command line

```
./run.sh < formula.cnf
```

Reads a DIMACS CNF formula on stdin. Prints either

```
SAT
1 -2 3 0
```

(one literal per variable, in order, then `0`) or `UNSAT`. Exit status is 0
for both answers; a malformed input prints an error on stderr and exits 1.

## Library

```go
package main

import (
	"fmt"

	"github.com/example/sat"
)

func main() {
	s := sat.NewSolver(3)
	s.AddClause(1, -2)
	s.AddClause(2, 3)
	switch s.Solve() {
	case sat.Satisfiable:
		fmt.Println("SAT", s.Model()) // Model()[i] is variable i+1
	case sat.Unsatisfiable:
		fmt.Println("UNSAT")
	}
}
```

Or from DIMACS text:

```go
cnf, err := sat.ParseDIMACS(r)
status, model := sat.Solve(cnf)
sat.WriteResult(os.Stdout, status, model)
```

`AddClause` may be called again after `Solve` to solve incrementally.
