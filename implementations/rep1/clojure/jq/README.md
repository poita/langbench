# jq (Clojure)

An interpreter for a subset of the [jq](https://jqlang.github.io/jq/) filter
language (jq 1.7 semantics), written from scratch in Clojure with no
dependencies beyond Clojure itself: it has its own JSON parser, JSON
serializer, filter parser and evaluator. The supported language is described
in `problems/jq/SPEC.md` of the task tree.

It is a reusable library (`jq.core`) with a thin command-line tool (`jq.cli`)
on top.

## Requirements

Java 27 and the `clojure` CLI (Clojure 1.12.6).

## Build

```
./build.sh
```

AOT-compiles the CLI into `target/classes` and records the classpath in
`target/classpath`, so that `run.sh` starts quickly. (Without a build,
`run.sh` falls back to `clojure -M:run`.)

## Command-line use

```
printf '.users | map(.age) | add\n{"users":[{"age":30},{"age":12}]}\n' | ./run.sh
# 42
```

Standard input holds the **filter on the first line** and **one JSON
document** after it. Each result is printed as one line of compact JSON.
If evaluation raises an uncaught error, the results produced before it are
printed, then a line `error`. The exit status is always 0.

## Library use

```clojure
(require '[jq.core :as jq]
         '[jq.json :as json]
         '[jq.value :as v])

;; JSON text in, JSON text out
(jq/query-string ".[] | select(. > 1)" "[1,2,3]")
;=> ["2" "3"]

;; Compile once, run many times, on jq values
(def f (jq/compile "group_by(.k) | map({k: .[0].k, n: length})"))
(jq/run f (json/parse "[{\"k\":\"b\"},{\"k\":\"a\"},{\"k\":\"b\"}]"))
;=> [[{"k" "a", "n" 1.0} ...]]   ; objects are jq.value/JObj, keep key order

;; Ordinary Clojure data
(-> (jq/query ".a | map(. * 2)" (v/from-clj {:a [1 2 3]}))
    first v/to-clj)
;=> [2.0 4.0 6.0]

;; Streaming and errors: results before an error are delivered first
(try (jq/run-each (jq/compile "1, error, 2") nil println)
     (catch clojure.lang.ExceptionInfo e (v/jq-error? e)))
; prints 1.0, returns true
```

### Modules

| namespace      | responsibility                                                 |
|----------------|----------------------------------------------------------------|
| `jq.core`      | public API: `compile`, `run`, `run-each`, `query`, `query-string` |
| `jq.json`      | JSON parser and compact serializer                             |
| `jq.value`     | data model: ordered objects, total order, equality, errors, Clojure conversion |
| `jq.lexer`     | filter text to tokens                                          |
| `jq.parser`    | tokens to syntax tree (recursive descent)                      |
| `jq.interp`    | syntax tree compiled to closures; evaluation, `?`/try, `reduce`, bindings |
| `jq.ops`       | arithmetic, comparison, indexing, slicing                      |
| `jq.builtins`  | `length`, `keys`, `sort_by`, `group_by`, `add`, ...            |
| `jq.cli`       | stdin/stdout contract                                          |

Design notes: values are immutable and shared (never deep-copied); objects
are a hash map plus an insertion-ordered key vector, with the sorted key
order computed at most once per object; evaluation is push-based (each node
calls its continuation once per output), which gives jq's generator order and
lets results printed before an error survive it.

## Tests

```
clojure -M:test
```

Runs the unit, evaluation-semantics and property-based (test.check) tests
with the Cognitect test-runner. The end-to-end suite lives with the task:

```
cd .. && jq/build.sh && python3 run_tests.py jq -- jq/run.sh
```
