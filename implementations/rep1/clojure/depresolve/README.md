# depresolve

A package dependency resolver in Clojure. Given a registry (every version of
every package with its requirements) and a root manifest, it picks one version
of every needed package so that all requirements are satisfied, using a fixed,
fully specified search: depth-first, newest version first, chronological
backtracking. Every correct implementation therefore prints the same
resolution. When none exists it prints `unsatisfiable`.

The search is iterative (explicit choice-point stack, no recursion), does not
copy state at choice points (a trail of choice points plus a shared linked list
of pending requirements), and finds each requirement's candidates as a
precomputed index range found by binary search. It handles chains of thousands
of packages and millions of search steps in seconds. Only the Clojure standard
library is used.

## Requirements

Clojure 1.12.6 (the `clojure` CLI) on a recent JDK.

## Build

```
./build.sh
```

AOT-compiles the command-line tool into `target/classes` for fast startup.
(`./run.sh` also works without building, just more slowly.)

## Command-line usage

`./run.sh` reads the whole input on stdin and writes the resolution on stdout.

```
$ printf 'a 1.0.0: c ^1.0.0\nb 1.0.0: c ~1.2.0\nc 1.1.0:\nc 1.2.5:\nc 1.3.0:\nroot: a *, b *\n' | ./run.sh
a 1.0.0
b 1.0.0
c 1.2.5
```

Input format: zero or more registry lines `name MAJOR.MINOR.PATCH: req, req`
followed by one final `root: req, req` line; a requirement is `name range`,
where a range is `*`, an exact version, `^X.Y.Z`, `~X.Y.Z`, or one to three
space-separated comparators (`<`, `<=`, `>`, `>=`) that must all hold. Caret and
tilde follow npm semantics. Output is one `name version` line per chosen
package, sorted by name, or the single line `unsatisfiable`. The exit status is
0 either way. The full format and search definition are in
`problems/depresolve/SPEC.md`.

## Library usage

```clojure
(require '[depresolve.core :as dr])

;; From the text format:
(dr/resolve-text "a 1.0.0: b ^1.0.0\nb 1.2.0:\nb 2.0.0:\nroot: a *\n")
;=> "a 1.0.0\nb 1.2.0\n"

;; From data:
(dr/resolve-problem
 {:registry [{:name "a" :version [1 0 0]
              :requirements [{:name "b" :range "^1.0.0"}]}
             {:name "b" :version [1 2 0] :requirements []}
             {:name "b" :version [2 0 0] :requirements []}]
  :root [{:name "a" :range "*"}]})
;=> {"a" [1 0 0], "b" [1 2 0]}      ; nil when unsatisfiable
```

### Public API (`depresolve.core`)

| function | description |
|---|---|
| `(parse-input text)` | parse the text format into a problem map |
| `(resolve-problem problem)` | sorted map of name -> `[major minor patch]`, or `nil` if unsatisfiable (`{}` for an empty root) |
| `(format-resolution resolution)` | CLI output string for a resolution (or `nil`) |
| `(resolve-text text)` | parse, resolve and format in one step |

Ranges in requirements may be strings (`"^1.0.0"`) or the parsed maps produced
by `depresolve.range/parse`.

### Modules

| namespace | responsibility |
|---|---|
| `depresolve.version` | version vectors, ordering, order-preserving `long` encoding |
| `depresolve.range` | range parsing to half-open intervals, `accepts?` |
| `depresolve.input` | parser for the registry/manifest text |
| `depresolve.index` | compiles a problem into arrays: interned names, sorted versions, requirement candidate ranges |
| `depresolve.search` | the iterative backtracking search |
| `depresolve.core` | the public API |
| `depresolve.cli` | the stdin/stdout tool |

## Tests

```
clojure -M:test
```

Runs the unit tests with the Cognitect test-runner, including a test.check
property that compares the optimised search against a direct transcription of
the specification's recursive algorithm on random small registries.
