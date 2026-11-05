# datalog

A Datalog engine with stratified negation, written in Go using only the
standard library. It reads a program (facts, rules and queries), checks that it
is safe and stratifiable, computes its perfect model with semi-naive bottom-up
evaluation, and answers the queries.

## Features

- Facts, rules, `not` atoms, and the comparisons `< <= > >= = !=`
  over a total order of constants (integers numerically, then identifiers
  bytewise).
- Safety and stratification checks (`ErrUnsafe`, `ErrNotStratifiable`).
- Semi-naive evaluation per strongly connected component, with non-linear
  recursion, interned integer constants, a hash set per relation and lazily
  built hash indexes extended incrementally.

## Build

```sh
./build.sh        # produces bin/datalog (go build ./cmd/datalog)
go test ./...     # unit tests
```

Requires Go 1.27 or newer; there are no dependencies.

## Command-line use

`datalog` reads one program on standard input and writes the answers to
standard output (`run.sh` is a thin wrapper around the binary):

```sh
$ cat prog.dl
edge(1, 2). edge(2, 3). edge(3, 1). edge(3, 4).
path(X, Y) :- edge(X, Y).
path(X, Z) :- edge(X, Y), path(Y, Z).
?- path(4, X).
?- path(X, X).
$ ./run.sh < prog.dl
-- 0
path(1, 1)
path(2, 2)
path(3, 3)
-- 3
```

For each query the matching tuples are printed in ascending order, one
`pred(v1, v2, ...)` per line, followed by `-- N` with the count. Queries are
answered in program order after the whole program has been evaluated.

If a rule is unsafe (a head, negated or comparison variable does not occur in a
positive body atom) or the program is not stratifiable (a dependency cycle
contains a negation), the only output is `error`, with exit status 0. Malformed
input is reported on standard error with exit status 2.

## Library use

```go
package main

import (
	"fmt"
	"os"

	"github.com/example/datalog"
)

func main() {
	prog, err := datalog.Parse([]byte(`
		parent(tom, bob). parent(bob, ann).
		anc(X, Y) :- parent(X, Y).
		anc(X, Z) :- parent(X, Y), anc(Y, Z).
		?- anc(tom, X).`))
	if err != nil {
		panic(err) // *datalog.SyntaxError
	}
	model, err := datalog.Evaluate(prog) // datalog.ErrUnsafe / ErrNotStratifiable
	if err != nil {
		panic(err)
	}

	// Programmatic access ...
	for _, t := range model.Relation("anc", 2) {
		fmt.Println(t[0], "is an ancestor of", t[1])
	}
	// ... or the textual output of the CLI.
	model.WriteAnswers(os.Stdout)
}
```

`datalog.Solve(src, w)` / `SolveString` do parse + evaluate + `WriteAnswers` in
one call.

## Layout

| file | responsibility |
|------|----------------|
| `lexer.go`, `parser.go`, `ast.go` | tokens, parser, program representation; constants are renumbered so id order is the constant order |
| `check.go` | safety, dependency graph, Tarjan SCCs, stratification |
| `relation.go` | append-only tuple store, hash set, incremental hash indexes |
| `plan.go` | compiles a rule into a join plan (delta atom first, then most-bound atom; filters attached as early as possible) |
| `eval.go` | per-component evaluation; semi-naive rounds with round-start snapshots |
| `query.go` | query matching, sorting, output formatting, `Solve` |
| `cmd/datalog` | the command-line tool |
