# datalog

A small Datalog engine in Go with stratified negation and integer/symbol
comparisons. It ships as a reusable library (`github.com/example/datalog`) and
a thin command-line tool (`cmd/datalog`). It uses only the Go standard library.

Evaluation is bottom-up and semi-naive: constants are interned and renumbered
so that id order is the language's total order, relations are append-only
integer tuple arrays with a hash set, and joins are compiled to nested-loop
plans driven by lazily built, incrementally maintained hash indexes. The
predicate dependency graph is split into strongly connected components that
are evaluated in dependency order.

## Language

```prolog
edge(1, 2). edge(2, 3).                   % facts
path(X, Y) :- edge(X, Y).                 % rules
path(X, Z) :- edge(X, Y), path(Y, Z).
lonely(X) :- node(X), not edge(X, _).     % negation, anonymous variable
small(X)  :- node(X), X < a.              % comparisons: < <= > >= = !=
?- path(1, X).                            % queries
```

* Constants are integers (`-5`, `0`, `12`) or identifiers (`[a-z][a-z0-9_]*`);
  variables start with an upper-case letter; `_` is an anonymous variable.
* Predicates are identified by name and arity. `not` is reserved.
* Constants are totally ordered: integers (numerically) before identifiers
  (bytewise). This order is used by comparisons and for sorting output.
* A rule is *safe* if every variable in its head, negated atoms and
  comparisons also occurs in a positive body atom. The program must be
  *stratifiable*: no dependency cycle may contain a negation. Otherwise the
  program is rejected.
* `%` starts a comment that runs to the end of the line.

## Build

```sh
./build.sh            # produces bin/datalog (go build -o bin/datalog ./cmd/datalog)
go test ./...         # unit tests
```

Requires Go 1.27 or newer.

## Command-line use

The program reads a whole Datalog program on standard input and prints the
answer to each query, in order, on standard output. `./run.sh` runs the built
binary and works from any directory.

```sh
$ ./run.sh <<'DL'
edge(1, 2). edge(2, 3). edge(3, 1). edge(3, 4).
path(X, Y) :- edge(X, Y).
path(X, Z) :- edge(X, Y), path(Y, Z).
?- path(1, X).
?- path(4, X).
DL
path(1, 1)
path(1, 2)
path(1, 3)
path(1, 4)
-- 4
-- 0
```

Each query prints its matching tuples in ascending order followed by `-- N`,
the number of tuples. If the program is unsafe or not stratifiable the only
output is the line `error` (exit status 0). Malformed input is reported on
standard error with exit status 1.

## Library use

```go
package main

import (
	"fmt"
	"log"
	"os"

	"github.com/example/datalog"
)

func main() {
	src := `
		parent(alice, bob). parent(bob, carol). parent(carol, dave).
		ancestor(X, Y) :- parent(X, Y).
		ancestor(X, Z) :- parent(X, Y), ancestor(Y, Z).
		?- ancestor(alice, X).
	`
	prog, err := datalog.Parse([]byte(src)) // *datalog.SyntaxError on bad input
	if err != nil {
		log.Fatal(err)
	}
	model, err := prog.Solve() // datalog.ErrUnsafe / datalog.ErrNotStratifiable
	if err != nil {
		log.Fatal(err)
	}

	// Answer the program's queries and print them in the CLI format ...
	datalog.WriteAnswers(os.Stdout, model.Answers())

	// ... or inspect any relation directly.
	for _, t := range model.Relation("ancestor", 2) {
		fmt.Println(t[0], "->", t[1])
	}
}
```

### API overview

| Item | Purpose |
| --- | --- |
| `Parse([]byte) (*Program, error)` | Lex, parse and intern a program. |
| `(*Program).Check() error` | Safety, then stratification check. |
| `(*Program).Solve() (*Model, error)` | Check and compute the perfect model. |
| `(*Model).Answers() []Answer` | Evaluate the queries in program order. |
| `(*Model).Relation(name, arity)` | All tuples of a predicate, sorted. |
| `WriteAnswers(io.Writer, []Answer)` | Canonical text output. |
| `Value`, `Int`, `Sym`, `CompareTuples` | Constants and their total order. |

### Layout

| File | Responsibility |
| --- | --- |
| `lexer.go`, `parser.go`, `program.go` | Tokens, one-pass parser with interning, program representation. |
| `check.go` | Safety check; SCCs (Tarjan) and stratification check. |
| `plan.go`, `exec.go` | Compiling rules to join plans; executing them. |
| `eval.go` | Per-component semi-naive fixpoint. |
| `model.go`, `value.go` | Query answering, output, constant values and ordering. |
| `internal/store` | Relations with hash set and hash indexes. |
| `cmd/datalog` | The command-line tool. |
