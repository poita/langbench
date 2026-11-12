# depresolve

A deterministic package dependency resolver in Clojure. Given a registry (every
version of every package with its requirements) and a root manifest, it picks
one version per needed package using a fully specified search — depth-first,
newest version first, chronological backtracking — so every run prints the same
resolution, or `unsatisfiable` when none exists.

The project is a small library (`depresolve.*`) with a thin command-line tool on
top. The search is iterative (explicit stacks, a trail instead of copies), so
dependency chains thousands of packages deep are fine and a search step is O(1)
plus the requirements it adds.

## Requirements

Clojure 1.12.6 (the `clojure` CLI) on a recent JDK (developed on Java 27).
No libraries are needed beyond Clojure itself; the tests use `test.check` and
the Cognitect test-runner.

## Build

```sh
./build.sh
```

AOT-compiles the CLI into `classes/` and records the classpath in `.classpath`.
`build.sh` and `run.sh` work from any directory.

## Command-line usage

```sh
./run.sh < input.txt
```

Input (stdin) is registry lines followed by one `root:` line:

```
a 1.0.0: c ^1.0.0
b 1.0.0: c ~1.2.0
c 1.1.0:
c 1.2.5:
c 1.3.0:
root: a *, b *
```

Output is one `name version` line per chosen package, sorted by name:

```
a 1.0.0
b 1.0.0
c 1.2.5
```

or the single line `unsatisfiable`. The exit status is 0 in both cases.
Ranges are `*`, `1.2.3`, `^1.2.3`, `~1.2.3` (npm semantics) or space-separated
comparators (`>=1.0.0 <2.0.0`). Without building you can also use
`clojure -M:run < input.txt`.

## Library usage

```clojure
(require '[depresolve.core :as dr])

(def registry
  {"a" {"1.0.0" [["c" "^1.0.0"]]}
   "b" {"1.0.0" [["c" "~1.2.0"]]}
   "c" {"1.1.0" [] "1.2.5" [] "1.3.0" []}})

(dr/resolve-deps registry [["a" "*"] ["b" "*"]])
;; => {"a" "1.0.0", "b" "1.0.0", "c" "1.2.5"}

(dr/resolve-deps registry [["zzz" "*"]])   ;; => nil (unsatisfiable)

(dr/resolve-text "a 1.0.0:\nroot: a *\n")  ;; => "a 1.0.0\n"
```

`resolve-deps` returns a sorted map of package name → version string, or `nil`
when unsatisfiable (an empty map means the root needs nothing).

### Modules

| namespace | responsibility |
|---|---|
| `depresolve.core` | public API: `resolve-deps`, `resolve-text`, `format-resolution` |
| `depresolve.parse` | text input → registry/root data |
| `depresolve.version` | versions packed into a `long` for numeric ordering |
| `depresolve.range` | ranges as half-open `[lo, hi)` intervals |
| `depresolve.index` | compiles a registry to arrays; requirement → candidate index range via binary search |
| `depresolve.search` | the iterative backtracking search |
| `depresolve.cli` | stdin/stdout entry point |

## Tests

```sh
clojure -M:test
```

Unit tests per module, the worked examples from the specification, a CLI test
in a subprocess, and a `test.check` property comparing the implementation with
a direct recursive transcription of the specified search on random registries.
