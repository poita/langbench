# datalog

A small Datalog engine for Clojure: stratified negation, comparison
built-ins, bottom-up **semi-naive** evaluation with hash-indexed relations and
planned indexed nested-loop joins.  It ships as a library (`datalog.core`) and a
thin command-line tool (`datalog.main`) that reads a program on stdin and prints
the answers to its queries.

Requires Clojure 1.12 on a recent JDK (developed against Clojure 1.12.6 and
Java 27); it depends on nothing but `org.clojure/clojure`.

## Language

```
edge(1, 2). edge(2, 3).                  % facts
path(X, Y) :- edge(X, Y).                % rules
path(X, Z) :- edge(X, Y), path(Y, Z).
lonely(X)  :- node(X), not path(X, _).   % negation (must be stratifiable)
old(X)     :- age(X, N), N >= 18.        % < <= > >= = != on constants
?- path(1, X).                           % queries
```

* Constants are integers (`-5`, `42`) or identifiers (`alice`); variables start
  with an upper-case letter; `_` is an anonymous variable.
* Total order on constants: integers (numerically) < identifiers (ASCII order).
* A rule is *safe* if every variable in its head, in a negated atom or in a
  comparison also occurs in a positive body atom.  Programs must be safe and
  *stratifiable* (no recursion through negation); otherwise the CLI prints
  `error`.
* Predicates are identified by name **and** arity.

The complete specification of the input and output format is in
`problems/datalog/SPEC.md` of the surrounding repository.

## Build and run

```
./build.sh                       # resolves dependencies, AOT-compiles the CLI
./run.sh < program.dl            # or: clojure -M:run < program.dl
```

Example:

```
$ printf 'edge(a,b). edge(b,c). p(X,Y) :- edge(X,Y). p(X,Z) :- edge(X,Y), p(Y,Z). ?- p(a, X).' | ./run.sh
p(a, b)
p(a, c)
-- 2
```

Each query prints its matching tuples in ascending order followed by a
`-- N` count line.  An unsafe or unstratifiable program prints just `error`.
The exit status is 0 in both cases (1 only for syntactically malformed input).

## Tests

```
clojure -X:test
```

Uses the Cognitect test-runner with `clojure.test`; the property tests use
`org.clojure/test.check`.

## Library

```clojure
(require '[datalog.core :as dl])

;; One shot: program text in, CLI output out.
(dl/run-string "p(1). q(X) :- p(X). ?- q(X).")
;; => "q(1)\n-- 1\n"

;; Keep the model and query it from Clojure.
(def model
  (dl/solve (dl/parse "edge(a, b). edge(b, c).
                       path(X, Y) :- edge(X, Y).
                       path(X, Z) :- edge(X, Y), path(Y, Z).")))

(dl/query model "path" ["a" 'X])   ; integer = Long, identifier = String,
;; => [["a" "b"] ["a" "c"]]        ; variable = Symbol

(dl/check (dl/parse "p(X) :- q(Y)."))
;; => {:error :unsafe, :rules [...]}
```

Public API (`datalog.core`): `parse`, `check`, `solve`, `query`,
`query-clauses`, `run-string`.

## Design

| namespace            | responsibility                                                    |
|----------------------|-------------------------------------------------------------------|
| `datalog.parser`     | tokeniser and recursive-descent parser → clauses                  |
| `datalog.analysis`   | safety check; dependency graph; Tarjan SCCs → strata              |
| `datalog.constants`  | total order on constants; interning constants as integer ranks    |
| `datalog.relation`   | mutable tuple sets with incrementally maintained hash indexes     |
| `datalog.plan`       | join ordering and compilation of rule variants to closures        |
| `datalog.eval`       | semi-naive fixpoint per stratum                                   |
| `datalog.query`      | matching, sorting and formatting query answers                    |
| `datalog.core`       | public facade                                                     |
| `datalog.main`       | command-line entry point                                          |

Constants are interned once as their rank in the total order, so joins,
comparisons and output sorting all work on integers.  Each relation keeps its
rows, a hash set, and one hash index per access pattern; an index absorbs new
rows lazily and is never rebuilt, so index maintenance is linear in the size of
the relation over the whole run.  Within a recursive stratum, round *k* runs one
variant of each rule per recursive body atom, reading that atom from the rows
added in round *k−1* and joining the rest (delta atom first, then the atom with
the most bound arguments) against the relations as they stood at the start of
the round.
