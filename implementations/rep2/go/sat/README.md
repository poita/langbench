# sat

A CDCL SAT solver for DIMACS CNF, written in Go using only the standard
library. It is a reusable library with a thin command-line tool on top.

The solver is MiniSat-style: two watched literals, first-UIP clause learning
with local minimisation, VSIDS branching on an indexed heap, phase saving,
Luby restarts, and periodic learnt-clause reduction. The search is fully
deterministic.

## Layout

| Path          | Purpose                                                        |
|---------------|----------------------------------------------------------------|
| `solver/`     | The CDCL solver (`New`, `AddClause`, `Solve`, `Model`).        |
| `dimacs/`     | DIMACS CNF parser and result writer.                           |
| `cmd/sat/`    | The command-line tool (stdin → stdout).                        |
| `build.sh`    | Builds `bin/sat`.                                              |
| `run.sh`      | Runs `bin/sat`; works from any directory.                      |

## Build

    ./build.sh          # or: go build -o bin/sat ./cmd/sat

Requires Go 1.27.1. Run the unit tests with `go test ./...`.

## Command-line use

    ./run.sh < formula.cnf

Input is a DIMACS CNF file on standard input. Output on standard output is
either

    UNSAT

or

    SAT
    1 -2 3 0

where the second line has one literal per variable `1..V` (positive if the
variable is true) followed by `0`. The exit status is 0 in both cases; a
malformed input prints an error on stderr and exits 1.

## Library use

```go
package main

import (
	"fmt"

	"github.com/example/sat/dimacs"
	"github.com/example/sat/solver"
)

func main() {
	// Build a formula directly...
	s := solver.New(3)
	s.AddClause(1, -2) // x1 ∨ ¬x2
	s.AddClause(2, 3)  // x2 ∨ x3
	if s.Solve() == solver.Sat {
		fmt.Println(s.Model()) // model[i] is the value of variable i+1
	}

	// ...or parse DIMACS text.
	f, err := dimacs.Parse([]byte("p cnf 2 2\n1 2 0\n-1 0\n"))
	if err != nil {
		panic(err)
	}
	t := solver.New(f.NumVars)
	for _, c := range f.Clauses {
		t.AddClause(c...)
	}
	fmt.Println(t.Solve()) // SAT
}
```

Literals are non-zero DIMACS integers. `AddClause` removes duplicate literals,
ignores tautologies, and returns `false` once the formula is known to be
unsatisfiable. Clauses may be added between calls to `Solve`.
