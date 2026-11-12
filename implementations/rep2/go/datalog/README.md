# datalog

A Datalog engine with stratified negation, written in Go with only the
standard library. It reads a program (facts, rules, queries), rejects it if it
is unsafe or not stratifiable, computes the perfect model with bottom-up
semi-naive evaluation, and answers the queries.

## Build

Requires Go 1.27 or newer.

```
./build.sh          # builds bin/datalog (go build -o bin/datalog ./cmd/datalog)
go test ./...       # runs the tests
```

## Command-line use

The program is read from stdin; answers are written to stdout. `run.sh` is a
wrapper that works from any directory.

```
$ cat > prog.dl <<'EOT'
edge(1, 2). edge(2, 3). edge(3, 1). edge(3, 4).
path(X, Y) :- edge(X, Y).
path(X, Z) :- edge(X, Y), path(Y, Z).
?- path(4, X).
?- path(X, X).
EOT
$ ./run.sh < prog.dl
-- 0
path(1, 1)
path(2, 2)
path(3, 3)
-- 3
```

For every `?- p(...)` query, in program order, it prints each matching tuple
(sorted: integers before identifiers, integers numerically, identifiers
bytewise) as `p(v1, v2)`, followed by `-- N`. If the program has an unsafe
rule, or a cycle through negation, it prints just `error` (exit status 0).

### Language

* Facts `p(a, 1).`, rules `h(X) :- p(X, _), not q(X), X < 5.`, queries
  `?- h(X).`; `%` starts a comment.
* Constants are integers (`-?[0-9]+`) or identifiers (`[a-z][a-z0-9_]*`);
  variables start with an upper-case letter; `_` is an anonymous variable.
* Comparisons: `< <= > >= = !=` over the total order above.
* A rule is *safe* if every variable in its head, a negated atom or a
  comparison also occurs in a positive body atom. Predicates are identified
  by name and arity.

## Library

```go
package main

import (
	"fmt"

	"example.com/datalog"
)

func main() {
	db, err := datalog.Load(`
		parent(ann, bob). parent(bob, cy).
		anc(X, Y) :- parent(X, Y).
		anc(X, Z) :- parent(X, Y), anc(Y, Z).
		?- anc(ann, X).`)
	if err != nil { // errors.Is(err, datalog.ErrUnsafe / ErrNotStratifiable) or *parser.SyntaxError
		panic(err)
	}
	for _, a := range db.Answers() { // the program's own queries
		for _, t := range a.Tuples {
			fmt.Println(datalog.Format(a.Query.Pred, t))
		}
	}
	rows, _ := db.Query("anc(X, cy)") // ad hoc query against the model
	fmt.Println(len(rows))
}
```

### Layout

| package             | responsibility                                              |
|---------------------|-------------------------------------------------------------|
| `datalog` (root)    | facade: `Load`, `Evaluate`, `Run`, `DB.Query`, formatting   |
| `ast`               | syntax tree, the total order on constants                   |
| `parser`            | lexer and parser (`Parse`, `ParseAtom`, `SyntaxError`)      |
| `analysis`          | safety check, dependency graph, Tarjan SCC stratification   |
| `engine`            | relations, hash indexes, join plans, semi-naive evaluation  |
| `cmd/datalog`       | the command-line tool                                       |

### How evaluation works

Constants are interned to integer ids in the constant order, so comparisons
are integer comparisons. Each relation is a flat tuple array with a hash set;
joins use hash indexes per (predicate, bound-column set) that are only ever
extended. Strongly connected components of the predicate graph are evaluated in
dependency order. A recursive component runs each rule once, then rounds in
which every rule is run once per recursive body atom, with that atom reading
the previous round's new tuples (first in the join order; remaining atoms
chosen by most bound arguments). Recursive atoms before the delta atom read
only older tuples, so each combination is derived once.
