# datalog

A small Datalog engine in Clojure with stratified negation: a reusable library
plus a command-line tool. It reads a program (facts, rules and queries),
checks that it is safe and stratifiable, computes its perfect model by
bottom-up **semi-naive evaluation**, and answers the queries.

The input and output formats are defined in `problems/datalog/SPEC.md`; the
algorithms follow `problems/datalog/APPROACH.md`.

## Requirements

Clojure 1.12.6 (the `clojure` CLI, deps.edn) on a recent JDK (developed on
Java 27). The library has no dependencies beyond Clojure itself.

## Build

```
./build.sh
```

AOT-compiles the command-line tool into `classes/` (this only speeds up
start-up; the project also runs straight from source).

## Command line

```
./run.sh < program.dl
```

The whole program is read from stdin. For every query `?- p(...)` the matching
tuples are printed in ascending order, one `p(v1, v2)` per line, followed by
`-- N` with the number of tuples. An unsafe or unstratifiable program prints
just `error`. The exit status is 0 in both cases; unparsable input is
reported on stderr with status 2.

```
$ ./run.sh <<'EOF'
edge(1, 2). edge(2, 3). edge(3, 1). edge(3, 4).
path(X, Y) :- edge(X, Y).
path(X, Z) :- edge(X, Y), path(Y, Z).
?- path(1, X).
?- path(X, X).
EOF
path(1, 1)
path(1, 2)
path(1, 3)
path(1, 4)
-- 4
path(1, 1)
path(2, 2)
path(3, 3)
-- 3
```

Language summary: constants are integers or lowercase identifiers, variables
start with an uppercase letter, `_` is anonymous; bodies may contain
negated atoms (`not p(X)`) and comparisons (`< <= > >= = !=`); `%` starts a
comment. Integers sort before identifiers, identifiers by ASCII order.

## Library

```clojure
(require '[datalog.core :as dl])

(def model
  (dl/solve "edge(1, 2). edge(2, 3). edge(3, 4).
             path(X, Y) :- edge(X, Y).
             path(X, Z) :- edge(X, Y), path(Y, Z).
             unreach(X) :- node(X), not path(1, X).
             node(1). node(2). node(3). node(4). node(5)."))

(dl/query model "path(1, X)")      ;=> [[1 2] [1 3] [1 4]]
(dl/query model "unreach(X)")      ;=> [[1] [5]]
(dl/query model "path(X, X)")      ;=> []
```

Constants come back as `Long`s (integers) and `Keyword`s (identifiers). A
program can also be given as data (see `datalog.syntax`) instead of text:

```clojure
(dl/solve {:rules [{:head {:pred "p" :args [1]} :body []}
                   {:head {:pred "q" :args ['X]}
                    :body [{:op :pos :atom {:pred "p" :args ['X]}}]}]})
```

Public API (`datalog.core`):

| function | purpose |
|---|---|
| `parse-program`, `parse-atom` | text -> program / atom data |
| `solve` | check safety and stratification, compute the model |
| `query` | tuples of a model matching an atom (sorted) |
| `run-program`, `format-answers` | the CLI pipeline: text -> answers -> output text |
| `error?` | is an exception an unsafe / unstratifiable program? |

`solve` throws `ex-info` with `:type` `:datalog/unsafe-rule` or
`:datalog/not-stratifiable`; the parser throws `:datalog/parse-error`.

## Layout

| namespace | responsibility |
|---|---|
| `datalog.syntax` | data model of programs, constant ordering, formatting |
| `datalog.parser` | lexer and recursive-descent parser |
| `datalog.analysis` | safety check, dependency graph, Tarjan SCCs / stratification |
| `datalog.storage` | relations (flat `int[]` rows, dedup hash set) and hash indexes with delta tracking |
| `datalog.join` | compiled-plan executor: indexed nested-loop join |
| `datalog.plan` | rule -> join plan (delta atom first, most-bound-first ordering, filters placed early) |
| `datalog.eval` | stratum-by-stratum semi-naive fixpoint; builds the model |
| `datalog.query` | answering queries against a model |
| `datalog.core` | public API |
| `datalog.main` | command-line tool |

Design notes: constants are interned to their rank in the global order, so
comparisons and sorting work on plain integers. Each relation keeps one hash
index per access pattern, each updated once per tuple over the whole run.
A recursive rule is run once per recursive body atom, reading that atom from
the previous round's delta.

## Tests

```
clojure -M:test
```

Runs the Cognitect test-runner over `test/`: unit tests per module, the
specification's examples, and a `test.check` property comparing the engine
with a brute-force reference evaluator on random stratified programs. The
end-to-end suite is run with `python3 run_tests.py datalog -- datalog/run.sh`
from the repository root.
