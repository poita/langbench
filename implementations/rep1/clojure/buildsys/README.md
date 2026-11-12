# buildsys — Kiln, an incremental build system

Kiln reads a *workspace* — build files written in the **Kiln Build Language**
(KBL) plus ordinary source files — evaluates them into a graph of build steps,
and executes the out-of-date steps on a simulated set of parallel workers
against a virtual file system. Nothing is run by a real shell: Kiln's sixteen
built-in commands are implemented by the engine, and every command has an
integer cost that drives a fully deterministic scheduling simulation. Change
detection is content based (64-bit FNV-1a hashes recorded in `.kiln-state`), so
touching a file never causes a rebuild and an upstream step that reproduces
identical bytes stops the rebuild chain (early cutoff).

The project is a reusable Clojure library (`buildsys.core`) with a thin
command-line tool on top (`buildsys.main`). The language and file formats are
defined in `problems/buildsys/SPEC.md` of the parent repository; this README
only covers using the code.

Requires Clojure 1.12 on a recent JDK (developed on Java 27) and the `clojure`
CLI. There are no runtime dependencies besides Clojure itself.

## Build

```sh
./build.sh
```

`build.sh` (runnable from any directory) AOT-compiles the CLI into
`target/classes` and records the runtime classpath in `target/classpath`.

## Command-line use

```sh
./run.sh <input directory> <output directory>
```

The input directory holds `session.txt` (a script of builds and workspace
edits) plus the initial workspace (`main.kiln`, sources, …). The tool runs the
session and writes into the output directory:

- `log.txt` — one block per session step: a header, `hit` / `run` / `fail` /
  `cancel` events with simulated start and end times and worker ids, and a
  result line (`ok ran=… hit=… time=…`, `error E_…`, …);
- `workspace/` — every file of the final workspace, including the generated
  `out/…` tree and `.kiln-state`.

The exit status is 0 whenever the session ran, including sessions whose builds
fail: a build error is normal output and appears in `log.txt`.

A minimal session — `main.kiln`:

```
step {
    out "out/hello.txt"
    cmd write("hello\n")
}
default "out/hello.txt"
```

`session.txt`:

```
build
build
touch main.kiln
build
```

produces a `log.txt` showing one `run` followed by two cache hits:

```
step 1: build (default) -j 1
  run 0 1 w0 out/hello.txt write("hello\n")
  ok ran=1 hit=0 time=1
step 2: build (default) -j 1
  hit 0 out/hello.txt
  ok ran=0 hit=1 time=0
step 3: touch main.kiln
  ok
step 4: build (default) -j 1
  hit 0 out/hello.txt
  ok ran=0 hit=1 time=0
```

The session script supports `build [TARGET …] [-j N]`, `create PATH` /
`edit PATH` (with a content block ended by a `---` line), `delete PATH`,
`touch PATH` and `clean`.

## Library use

All file contents are *byte strings*: Java strings holding one char (0–255)
per byte. `kiln/utf8` converts an ordinary string to its UTF-8 byte string, and
`kiln/bytes->str` / `kiln/str->bytes` convert from and to byte arrays.

```clojure
(require '[buildsys.core :as kiln])

(def ws
  (kiln/workspace
   {"main.kiln" (str "let srcs = glob(\"src/*.txt\")\n"
                     "step {\n  out \"out/all.txt\"\n  in srcs\n  cmd concat()\n}\n"
                     "default \"out/all.txt\"\n")
    "src/a.txt" "alpha\n"
    "src/b.txt" "beta\n"}))

;; One build on two simulated workers; no targets means the default targets.
(def r1 (kiln/build ws [] 2))
(select-keys r1 [:ran :hits :time :error])  ;=> {:ran 1, :hits 0, :time 2, :error nil}
(:events r1)
;=> [{:kind :run, :serial 0, :start 0, :end 2, :worker 0,
;     :target "out/all.txt", :cmd "concat()"}]

;; The returned workspace includes outputs and `.kiln-state`, so a second build
;; is incremental.
(def r2 (kiln/build (:workspace r1) []))
(select-keys r2 [:ran :hits :time])          ;=> {:ran 0, :hits 1, :time 0}
(get (kiln/files (:workspace r2)) "out/all.txt")  ;=> "alpha\nbeta\n"

;; Build errors are values, not exceptions.
(:error (kiln/build (kiln/workspace {"main.kiln" "default \"nope\"\n"}) []))
;=> "E_UNKNOWN_TARGET nope"

;; A whole session script, as the CLI runs it:
(:log (kiln/run-session ws "build -j 2\ntouch src/a.txt\nbuild\n"))
```

Public functions of `buildsys.core`: `workspace`, `load-workspace`,
`write-workspace`, `files`, `build`, `parse-session`, `run-session`, `utf8`,
`bytes->str`, `str->bytes`.

## Layout

| Namespace | Responsibility |
|-----------|----------------|
| `buildsys.core` | public API (this is the one to depend on) |
| `buildsys.main` | the command-line tool |
| `buildsys.session` | parsing `session.txt`; running a session; log format |
| `buildsys.build` | one build: configuration phases, scheduling, state write |
| `buildsys.lexer`, `buildsys.parser` | KBL lexing (comments, logical lines, tokens, literal scanner) and parsing to an AST |
| `buildsys.eval`, `buildsys.value`, `buildsys.builtins` | the tree-walking evaluator over scopes, the value model and total order, the 39 built-in functions |
| `buildsys.glob` | glob pattern compilation and matching |
| `buildsys.graph` | reference resolution, validation, the deterministic cycle search, reachability |
| `buildsys.commands` | the sixteen commands, including `preprocess` with depfiles |
| `buildsys.state` | `.kiln-state` reader/writer, canonical command strings, change detection |
| `buildsys.scheduler` | the deterministic worker simulation |
| `buildsys.vfs`, `buildsys.hash`, `buildsys.path` | virtual file system, FNV-1a, workspace paths |
| `buildsys.error` | Kiln error values |

## Tests

```sh
clojure -M:test
```

runs the unit, property (`test.check`) and end-to-end tests with the Cognitect
test runner. The end-to-end tests include the worked examples of the
specification.
