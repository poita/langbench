# datalog

A Datalog engine with stratified negation, written in Go using only the
standard library. It reads a program (facts, rules and queries), checks that it
is safe and stratifiable, computes the perfect model by semi-naive bottom-up
evaluation, and prints the answers to every query.

## Language

```
% facts
edge(1, 2). edge(2, 3). edge(3, 1). edge(3, 4).

% rules: positive atoms, negated atoms (`not`), and comparisons
% (< <= > >= = !=)
path(X, Y) :- edge(X, Y).
path(X, Z) :- edge(X, Y), path(Y, Z).
sink(X)    :- edge(_, X), not hasout(X).
hasout(X)  :- edge(X, _).

% queries, answered in order
?- path(1, X).
?- sink(X).
```

* Constants are integers (`-5`, `0`, `42`) or identifiers (`[a-z][a-z0-9_]*`);
  variables start with an upper-case letter; `_` is an anonymous variable.
* Order of constants: all integers (numerically) before all identifiers
  (bytewise). It is used by the comparison operators and to sort output.
* A rule is *safe* if every variable in its head, in a negated atom or in a
  comparison also occurs in a positive body atom. Unsafe programs and programs
  with recursion through negation are rejected.
* Predicates are identified by name *and* arity.

For each query the matching tuples are printed one per line in ascending
order, followed by `-- N` with the count. If the program is unsafe or not
stratifiable (or malformed), the single line `error` is printed instead. The
exit status is 0 in both cases.

## Build

Requires Go 1.27 or newer; no third-party dependencies.

```
./build.sh          # builds bin/datalog (equivalent to: go build -o bin/datalog ./cmd/datalog)
go test ./...       # unit tests
```

## Command line

```
./run.sh < program.dl
```

The program is read from standard input and the answers are written to standard
output (`run.sh` works from any directory):

```
$ printf 'e(1,2). e(2,3).\np(X,Y) :- e(X,Y).\np(X,Z) :- e(X,Y), p(Y,Z).\n?- p(1, X).\n' | ./run.sh
p(1, 2)
p(1, 3)
-- 2
```

## Library

```go
package main

import (
	"fmt"
	"log"

	"datalog"
)

func main() {
	src := []byte(`
		edge(1, 2). edge(2, 3). edge(3, 4).
		path(X, Y) :- edge(X, Y).
		path(X, Z) :- edge(X, Y), path(Y, Z).
		?- path(1, X).
	`)

	prog, err := datalog.Parse(src) // syntax only
	if err != nil {
		log.Fatal(err)
	}
	model, err := prog.Eval() // checks safety + stratification, then evaluates
	if err != nil {
		log.Fatal(err) // errors.Is(err, datalog.ErrUnsafe / ErrNotStratifiable)
	}
	for i := 0; i < model.Queries(); i++ {
		res := model.Query(i)
		fmt.Print(res.Format())
	}
	for _, t := range model.Facts("edge", 2) {
		fmt.Println(t[0], t[1])
	}

	// Or, text in and text out, exactly like the command:
	out, _ := datalog.Run(src)
	fmt.Print(string(out))
}
```

## Layout

| package            | responsibility                                                    |
|--------------------|-------------------------------------------------------------------|
| `datalog` (root)   | public facade: `Parse`, `Program.Eval`, `Model`, `Run`            |
| `datalog/ast`      | syntax tree, constant ordering, comparison operators              |
| `datalog/parser`   | one-pass lexer/parser; interns predicates and constants, renumbers constants into their sort order |
| `datalog/analysis` | safety check; predicate dependency graph, Tarjan SCCs, stratification |
| `datalog/engine`   | hash-set relations, incremental hash indexes, join-plan compiler, semi-naive evaluator, query matching |
| `cmd/datalog`      | the command-line tool                                             |

## How evaluation works

Constants are interned and renumbered so that integer order equals the language
order; the evaluator only ever handles `int32` ids. Predicate dependency
components are evaluated in topological order. Within a recursive component, a
first round runs every rule, and each later round runs, for every rule and
every recursive positive body atom, a variant that scans that atom over the
tuples added in the previous round and reads the other atoms from a snapshot of
the whole relation. Relations are append-only tuple arrays with a hash set;
join steps use hash indexes built lazily per (predicate, bound columns) and
extended incrementally. New tuples found during a plan run are buffered and
inserted after it, so a relation is never modified while being scanned.
