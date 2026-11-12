# jq (Clojure)

A small interpreter for a subset of the [`jq`](https://jqlang.github.io/jq/)
filter language (semantics of jq 1.7, `jq -c`), written in Clojure with no
dependencies beyond the standard library. The JSON reader, the JSON writer, the
filter parser and the evaluator are all implemented here.

It is organised as a reusable library (`jq.core` is the public API) with a thin
command-line tool (`jq.main`) on top.

## Supported language

Identity, field/index/slice/iterate (`.a`, `.[0]`, `.[1:]`, `.[]`) with the
two meanings of `?`; literals; `|`, `,`; arithmetic (`+ - * / %`) and
comparisons; `and`/`or`/`not`; `if/elif/else`; `as $x |` bindings; `reduce`;
array and object construction; and the builtins `empty error length keys has
type add select map sort sort_by group_by unique reverse min max tostring
tonumber`. Streams are lazy and ordered exactly as the specification
(`problems/jq/SPEC.md`) describes, e.g. `[(1,2) + (10,20)]` is `[11,12,21,22]`.

## Build

Requires Java and the Clojure CLI (`clojure`), Clojure 1.12.

```sh
./build.sh        # AOT-compiles the CLI into classes/
```

## Command line

The first line of stdin is the filter, the rest is one JSON document. Every
result is printed as a line of compact JSON; if evaluation fails, the results
produced so far are printed followed by a line `error`. The exit code is 0.

```sh
$ printf '%s\n%s' '.users | map(select(.age >= 30)) | sort_by(.age) | map(.name)' \
    '{"users":[{"name":"ann","age":31},{"name":"bob","age":25},{"name":"cy","age":30}]}' | ./run.sh
["cy","ann"]
```

`run.sh` works from any directory.

## Library

```clojure
(require '[jq.core :as jq])

;; text in, text out
(jq/query ".a | map(. * 2)" "{\"a\":[1,2,3]}")
;=> ["[2,4,6]"]

;; compile once, run many times; a compiled filter is (fn [input emit])
(def f (jq/compile-filter ".[] | select(. > 1)"))
(jq/run f (jq/parse-json "[1,2,3]"))
;=> [2.0 3.0]

;; streaming: outputs are pushed as they are produced
(f (jq/parse-json "[1,2,3]") println)

;; errors carry the outputs produced before them
(try (jq/run (jq/compile-filter "1, error, 2") nil)
     (catch clojure.lang.ExceptionInfo e
       (when (jq/error? e) (:outputs (ex-data e)))))
;=> [1.0]
```

### Public API (`jq.core`)

| Function | Purpose |
|---|---|
| `(compile-filter src)` | parse + compile a filter; returns `(fn [input emit])` |
| `(run f input)` | all outputs as a vector; throws on a jq error |
| `(error? e)` | is `e` a jq runtime error |
| `(parse-json s)` / `(write-json v)` | JSON text ⇄ jq value |
| `(query filter-src json-src)` | convenience: results as JSON strings |

Values: `nil`, booleans, `Double`s, strings, persistent vectors, and
`jq.value/Obj` (an immutable, insertion-ordered object; use
`jq.value/->clj` and `jq.value/clj->` to convert to and from plain Clojure
data).

### Modules

| Namespace | Responsibility |
|---|---|
| `jq.value` | data model, ordering/equality, insertion-ordered `Obj` |
| `jq.json` | JSON reader and compact writer |
| `jq.lexer`, `jq.parser` | filter text → syntax tree |
| `jq.ops` | arithmetic and comparison operators |
| `jq.access` | field/index/slice/iteration |
| `jq.builtins` | builtin function table |
| `jq.eval` | compiles the tree to closures `(fn [env input emit])` |
| `jq.error` | runtime error representation |
| `jq.core` | public API |
| `jq.main` | command-line tool |

### Design notes

Values are immutable and shared, never copied; objects are built in O(k) and
their sorted key list is computed at most once. Sorting is a stable comparison
sort with one key evaluation per element. Evaluation is push-based
(continuation-passing): each node calls its downstream `emit` per output, which
yields lazy ordered streams, partial output before an error, and O(1) overhead
per generator step. `try` distinguishes errors raised inside its body from
errors raised downstream by wrapping the latter while they unwind through it.

## Tests

```sh
clojure -X:test
```

Runs unit tests, `test.check` properties, and — if `../problems/jq/tests`
exists — the smaller conformance cases of the shared suite.
