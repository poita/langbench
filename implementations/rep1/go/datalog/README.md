# datalog

A small Datalog engine in Go with **stratified negation**, integer and symbol
constants, and comparison built-ins. It is a reusable library plus a thin
command-line tool, and uses only the Go standard library.

Evaluation is bottom-up and **semi-naive**: the predicate dependency graph is
split into strongly connected components (Tarjan), which are evaluated in
dependency order. Each recursive component runs to a fixpoint in rounds, where
every rule gets one variant per recursive body atom that reads that atom from
the previous round's new tuples. Relations are flat tuple stores with hash
sets for deduplication and incrementally maintained hash indexes, one per
access pattern; rules are compiled to indexed nested-loop join plans (delta
atom first, then the atom with the most bound arguments).

## Build

Requires Go 1.27 or newer.

```
./build.sh            # writes bin/datalog
go test ./...         # runs the test suite
```

`run.sh` runs the built binary (`./run.sh < program.dl`).

## Command line

```
datalog < program.dl
```

The whole of standard input is one program of facts, rules and queries:

```
edge(1, 2). edge(2, 3). edge(3, 1). edge(3, 4).
path(X, Y) :- edge(X, Y).
path(X, Z) :- edge(X, Y), path(Y, Z).
unreachable(X) :- node(X), not path(1, X).     % negation
?- path(1, X).
```

For each query the tool prints the matching tuples, one per line in ascending
order, followed by `-- N` with their count. Queries are answered in input
order after the whole program has been evaluated.

If a rule is *unsafe* (a variable in the head, a negated atom or a comparison
that does not occur in a positive body atom) or the program is not
*stratifiable* (negation on a recursive cycle), the only output is `error`.
Both exit with status 0; the reason is written to standard error. A syntax
error is reported on standard error with exit status 1.

### Language

* Constants are integers (`-12`, `0`) or identifiers (`alice`, `n_1`);
  variables start with an upper-case letter; `_` is an anonymous variable.
* A predicate is identified by name *and* arity.
* Body literals: `p(...)`, `not p(...)`, and comparisons `= != < <= > >=`.
  Integers sort before identifiers; integers compare numerically, identifiers
  bytewise. Comparisons never bind variables.
* `%` starts a comment to end of line. Queries are written `?- p(X, a).`

## Library

```go
package main

import (
	"fmt"
	"os"

	"example.com/datalog"
)

func main() {
	prog, err := datalog.Parse(`
		parent(tom, bob). parent(bob, ann).
		anc(X, Y) :- parent(X, Y).
		anc(X, Z) :- parent(X, Y), anc(Y, Z).`)
	if err != nil {
		panic(err)
	}
	model, err := datalog.Evaluate(prog) // safety + stratification checks
	if err != nil {
		panic(err) // *datalog.UnsafeError or *datalog.NotStratifiableError
	}
	query, _ := datalog.Parse("?- anc(tom, X).")
	for _, t := range model.Query(query.Queries[0]) {
		fmt.Println(t.Format("anc")) // anc(tom, ann), anc(tom, bob)
	}

	// Or do everything for a source text, in the CLI's output format:
	results, _ := datalog.Run("p(1). ?- p(X).")
	datalog.WriteResults(os.Stdout, results)
}
```

### Packages

| package                    | responsibility                                              |
|----------------------------|-------------------------------------------------------------|
| `example.com/datalog`      | public API: `Parse`, `Evaluate`, `Model.Query`, `Run`       |
| `.../ast`                  | constants and their total order, terms, atoms, rules        |
| `.../parser`               | lexer and recursive-descent parser                          |
| `.../analysis`             | safety check, dependency graph, SCCs / stratification       |
| `.../engine`               | relations, indexes, join planning, semi-naive evaluation    |
| `.../cmd/datalog`          | the command-line tool                                       |

## Tests

`go test ./...` runs unit tests for each package, golden tests
(`testdata/*.in` / `.out`), a CLI test, and a randomized cross-check of the
engine against a naive evaluator.
