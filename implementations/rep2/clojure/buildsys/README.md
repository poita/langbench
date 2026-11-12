# buildsys — Kiln, an incremental build system in Clojure

Kiln reads a *workspace* of build files written in the **Kiln Build Language**
(KBL) and ordinary source files, evaluates the build files into a graph of
build steps, and executes the out-of-date steps on a simulated pool of parallel
workers against a virtual file system.  Nothing is ever run by a real shell:
Kiln's sixteen built-in commands are implemented by the engine, and every
command has an integer cost that drives a fully deterministic scheduling
simulation.  A *session* — a scripted sequence of builds and workspace edits —
produces a log of everything that happened plus the final workspace.

The language, file formats, commands, state file and scheduler are specified in
`problems/buildsys/SPEC.md`; this project implements that specification.

* Clojure 1.12.6, Java 27, `deps.edn` project, no runtime dependencies besides
  Clojure itself.
* A reusable library (`buildsys.core` is the public API) and a thin CLI
  (`buildsys.main`).

## Building

```sh
./build.sh
```

`build.sh` resolves the classpath with the `clojure` CLI (`clojure -Spath`) and
AOT-compiles `buildsys.main` into `classes/`, so that `run.sh` can start the JVM
directly.  It works from any directory.

## Command-line use

```sh
./run.sh <input directory> <output directory>
```

The input directory holds `session.txt` (the session script), usually a
`main.kiln` build file, and the initial workspace.  The program writes

```
<output>/log.txt           the session log
<output>/workspace/<path>  every file of the final workspace
```

and exits 0 even when builds fail (a build error is normal output and appears
in the log).  A tiny example:

```
input/main.kiln
    step {
        out "out/hello.txt"
        cmd write("hello\n")
    }
    default "out/hello.txt"
input/session.txt
    build
    build
```

gives a `log.txt` of

```
step 1: build (default) -j 1
  run 0 1 w0 out/hello.txt write("hello\n")
  ok ran=1 hit=0 time=1
step 2: build (default) -j 1
  hit 0 out/hello.txt
  ok ran=0 hit=1 time=0
```

## Using the library

```clojure
(require '[buildsys.core :as kiln])

(def files
  {"main.kiln" "rule shout(name) {
                    step {
                        out \"out/{name}.txt\"
                        in \"src/{name}.txt\"
                        cmd upper()
                    }
                }
                use shout(\"a\")
                default \"out/a.txt\"\n"
   "src/a.txt" "hello\n"})

;; One build, on 2 simulated workers:
(def r (kiln/build files :jobs 2))
(:ok? r)                                  ;=> true
(select-keys r [:ran :hits :time])        ;=> {:ran 1, :hits 0, :time 2}
(kiln/file-text (:files r) "out/a.txt")   ;=> "HELLO\n"

;; A whole session (builds interleaved with edits), returning the log:
(def s (kiln/run-session files "build\nedit src/a.txt\nbye\n---\nbuild\n"))
(println (:log s))
```

A workspace is a map of workspace path to content (`String`, encoded as UTF-8,
or `byte[]`).  `kiln/build` returns `:ok?`, `:ran`, `:hits`, `:time` (or
`:error`), the `:events` of the build and the resulting `:files`;
`kiln/run-session` returns the `:log` and final `:files`; `kiln/run-directory`
implements the command-line contract.

## Layout

| Namespace | Responsibility |
|-----------|----------------|
| `buildsys.core`      | public API |
| `buildsys.main`      | command-line entry point |
| `buildsys.session`   | parse `session.txt`, run its steps, write the log |
| `buildsys.build`     | one build: evaluate → validate graph → schedule → persist state |
| `buildsys.lexer`     | comment stripping, logical lines, tokens, string literals |
| `buildsys.parser`    | block structure and the recursive-descent expression parser |
| `buildsys.eval`      | tree-walking evaluator, scopes, `include`, rules, `step` blocks |
| `buildsys.builtins`  | the 39 built-in functions |
| `buildsys.glob`      | glob pattern compiler and matcher |
| `buildsys.value`     | KBL values, the total order, type errors |
| `buildsys.commands`  | the sixteen commands, canonical command strings |
| `buildsys.graph`     | graph construction, validation, cycle detection, reachability |
| `buildsys.state`     | `.kiln-state` reader/writer and freshness decision |
| `buildsys.scheduler` | the event-driven worker simulation |
| `buildsys.vfs`       | persistent virtual file system, directory I/O |
| `buildsys.hash`      | FNV-1a 64 |
| `buildsys.errors`    | error plumbing |

Design notes:

* All KBL strings are *byte strings*: Java `String`s whose chars are the bytes
  0–255 (ISO-8859-1 view), so `len`, `substr`, comparison, hashing and glob
  matching are byte operations as the specification demands.
* The virtual file system is a persistent sorted map: snapshots are O(1) (each
  command reads the workspace as of its start time) and `glob` finds the paths
  sharing the pattern's wildcard-free prefix by binary search.  Each file's
  hash is a `delay`, so each distinct content is hashed once.
* Ready steps sit in sorted sets keyed by serial number, so every ready-set
  operation is O(log R).

## Tests

```sh
./run_tests.sh            # clojure -M:test (Cognitect test-runner, test.check)
```

The tests are `clojure.test` namespaces under `test/`: unit tests per module,
`test.check` properties (hashing, glob, state-file round trips, line
splitting), and end-to-end sessions reproducing the worked examples of the
specification.  The acceptance suite is run from the repository root with

```sh
buildsys/build.sh && python3 run_tests.py buildsys -- buildsys/run.sh
```
