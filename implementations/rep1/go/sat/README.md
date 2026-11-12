# sat

A small, dependency-free CDCL SAT solver in Go, with a DIMACS CNF
command-line tool on top.

The solver is MiniSat-style:

- two-watched-literal unit propagation (with blocker literals);
- first-UIP conflict analysis with local (non-recursive) clause minimisation;
- VSIDS branching (double-precision activities, decay 0.95 / 0.999, rescaling)
  with phase saving (initially false), backed by a binary heap;
- Luby restarts (`100 * luby(2, i)` conflicts);
- deletion of the lower-activity half of the learnt clauses (binary ones are
  kept) after a restart once `max_learnts` is reached.

Input clauses are simplified at the root (duplicates, tautologies,
root-satisfied clauses and root-false literals removed; units propagated).

## Layout

| Path            | Purpose                                                          |
|-----------------|------------------------------------------------------------------|
| `/` (`package sat`) | The solver: `solver.go` (API, search loop), `propagate.go`, `analyze.go` (learning, VSIDS bumps), `reduce.go`, `heap.go`, `luby.go`, `lit.go` |
| `dimacs/`       | DIMACS parser/writer, `Formula`, answer formatting               |
| `cmd/sat/`      | The command-line tool                                            |

## Build

Requires Go 1.27 or newer and nothing else.

```sh
./build.sh          # produces bin/sat
go test ./...       # run the tests
```

## Command-line use

`sat` reads a DIMACS CNF file on standard input and writes the answer to
standard output; it takes no arguments (`./run.sh` just runs `bin/sat`).

```sh
$ printf 'p cnf 3 2\n1 -2 0\n2 3 0\n' | ./run.sh
SAT
-1 -2 3 0
$ printf 'p cnf 1 2\n1 0\n-1 0\n' | ./run.sh
UNSAT
```

For a satisfiable formula the output is `SAT` and then one literal per
variable (`i` for true, `-i` for false) terminated by `0`; otherwise `UNSAT`.
Exit status is 0 on both answers, and 1 (with a message on stderr) if the input
cannot be parsed.

## Library use

```go
package main

import (
	"fmt"
	"strings"

	"example.com/sat"
	"example.com/sat/dimacs"
)

func main() {
	// Build a formula clause by clause with DIMACS-style literals…
	s := sat.New()
	s.AddClause(1, -2)
	s.AddClause(2, 3)
	s.AddClause(-1, -3)
	if s.Solve() == sat.Satisfiable {
		fmt.Println(s.Model()) // Model()[i-1] is the value of variable i
	}

	// …or load DIMACS text.
	f, err := dimacs.Parse(strings.NewReader("p cnf 2 2\n1 2 0\n-1 0\n"))
	if err != nil {
		panic(err)
	}
	s = f.Solver()
	fmt.Println(s.Solve(), s.Stats().Conflicts)
}
```

`AddClause` returns `false` once the formula is trivially unsatisfiable;
`Solve` returns `sat.Satisfiable` or `sat.Unsatisfiable`. A `Solver` is not
safe for concurrent use. See the package documentation (`go doc example.com/sat`).
