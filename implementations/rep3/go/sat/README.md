# sat

A CDCL SAT solver in Go, usable as a library and as a command-line tool. It
decides satisfiability of CNF formulas in DIMACS format and prints a
satisfying assignment when one exists. Standard library only.

The solver uses two watched literals, first-UIP clause learning with local
minimisation, VSIDS branching (indexed heap, phase saving), Luby restarts and
periodic deletion of low-activity learnt clauses. Search is deterministic.

## Layout

| Path            | Purpose                                                     |
|-----------------|-------------------------------------------------------------|
| `solver/`       | The CDCL solver (`heap.go`, `propagate.go`, `analyze.go`, `reduce.go`, `solver.go`) |
| `dimacs/`       | DIMACS CNF parser and result writer                         |
| `cmd/sat/`      | The command-line tool                                       |
| `build.sh`      | Builds `bin/sat`                                            |
| `run.sh`        | Runs `bin/sat` (works from any directory)                   |

## Build

```
./build.sh          # or: go build -o bin/sat ./cmd/sat
go test ./...       # unit tests
```

Requires Go 1.27 or newer.

## Command line

`sat` takes no arguments. It reads a DIMACS CNF on standard input and writes
the answer to standard output, exiting 0 for both SAT and UNSAT.

```
$ printf 'p cnf 3 2\n1 -2 0\n2 3 0\n' | ./run.sh
SAT
-1 -2 3 0
$ printf 'p cnf 1 2\n1 0\n-1 0\n' | ./run.sh
UNSAT
```

For a satisfiable formula the second line has one literal per variable
`1..V` in order, followed by `0`. Malformed input produces a message on
stderr and exit status 1.

## Library

```go
package main

import (
	"fmt"
	"os"

	"github.com/example/sat/dimacs"
	"github.com/example/sat/solver"
)

func main() {
	// Build a formula directly: (x1 ∨ ¬x2) ∧ (x2 ∨ x3)
	s := solver.New(3)
	s.AddClause(1, -2)
	s.AddClause(2, 3)
	if s.Solve() == solver.Sat {
		fmt.Println(s.Model()) // [false false true]
	}

	// Or parse DIMACS text and print in the CLI's format.
	f, err := dimacs.Parse([]byte("p cnf 2 2\n1 2 0\n-1 0\n"))
	if err != nil {
		panic(err)
	}
	t := solver.New(f.NumVars)
	for _, c := range f.Clauses {
		if !t.AddClause(c...) {
			break
		}
	}
	res := t.Solve()
	dimacs.WriteResult(os.Stdout, res == solver.Sat, t.Model())
}
```

API summary:

- `solver.New(n)`, `(*Solver).NewVar()`, `NumVars()`
- `AddClause(lits ...int) bool` — DIMACS literals; `false` means the formula is
  already known to be unsatisfiable
- `Solve() Result` (`solver.Sat` / `solver.Unsat`), `Model() []bool`,
  `Value(v int) bool`, `Stats()`
- `dimacs.Parse([]byte) (*Formula, error)`, `dimacs.WriteResult(w, sat, model)`

Call `Solve` once, after all clauses have been added.
