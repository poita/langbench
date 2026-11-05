# buildsys — Kiln, an incremental build system in Go

Kiln reads a *workspace* — build files written in the **Kiln Build Language**
(KBL) plus ordinary source files — evaluates the build files into a graph of
build steps, and runs the steps that are out of date on a simulated pool of
parallel workers against an in-memory file system. Nothing is ever executed by
a real shell: Kiln's sixteen built-in commands run in-process, each with an
integer *cost* that drives a fully deterministic scheduling simulation. Change
detection is content based (64-bit FNV-1a hashes recorded in `.kiln-state`),
so `touch` never causes a rebuild and byte-identical rebuilt outputs cut the
chain off early.

A *session* is a scripted sequence of builds and workspace mutations
(`build`, `create`, `edit`, `delete`, `touch`, `clean`). The tool writes a log
of everything that happened and the final state of the workspace.

The full language and behaviour are specified in `problems/buildsys/SPEC.md`;
the project uses only the Go standard library.

## Building

Requires Go 1.27.1 or newer.

```sh
./build.sh          # builds bin/kiln (works from any directory)
go build ./...      # or build everything with the standard tool
go test ./...       # run the unit tests
```

## Command-line usage

```sh
./run.sh <input directory> <output directory>
# or: bin/kiln <input directory> <output directory>
```

The input directory holds `session.txt` (the script), usually `main.kiln` (the
root build file), and the initial workspace files. The tool writes

```
<output>/log.txt          the session log
<output>/workspace/<path> every file of the final workspace
```

and exits 0 even when a build in the session fails (a build error is normal
output, logged as `  error E_...`). It exits non-zero only for usage or I/O
problems. Nothing is read from stdin.

A tiny example. `main.kiln`:

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

produces this `log.txt` — the second and third builds are cache hits:

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

## Library layout

Each package has one responsibility and a documented public API
(`go doc buildsys/<package>`):

| Package | Responsibility |
|---------|----------------|
| `buildsys/kilnerr` | The single error type (`Kind`, `Detail`) shared by all stages |
| `buildsys/vfs` | In-memory file system, cached FNV-1a hashes, sorted glob index, workspace path rules, loading/writing real directories |
| `buildsys/glob` | Glob pattern compiler and allocation-free matcher (`*`, `?`, `[...]`, `**`) |
| `buildsys/command` | The 16 built-in commands: specs, canonical rendering, in-process execution (including `preprocess`) |
| `buildsys/plan` | The data model produced by evaluation: steps, phony targets, defaults |
| `buildsys/kbl` | KBL lexer, parser, evaluator and the 39 built-in functions |
| `buildsys/state` | Strict `.kiln-state` reader and canonical writer |
| `buildsys/build` | One build: graph construction and validation, cycle detection, freshness, event-driven scheduler |
| `buildsys/session` | `session.txt` parser and session driver producing the log |
| `cmd/kiln` | The thin command-line wrapper |

## Library example

Running a whole session in memory:

```go
package main

import (
	"fmt"

	"buildsys/session"
	"buildsys/vfs"
)

func main() {
	fs := vfs.New()
	fs.Write("src/a.txt", []byte("abc\n"))
	fs.Write("main.kiln", []byte(`
step {
    out "out/mid.txt"
    in "src/a.txt"
    cmd upper()
}
step {
    out "out/final.txt"
    in "out/mid.txt"
    cmd number()
}
default "out/final.txt"
`))

	steps, err := session.Parse([]byte("build\nedit src/a.txt\nABC\n---\nbuild\n"))
	if err != nil {
		panic(err)
	}
	fmt.Print(string(session.Run(fs, steps)))

	out, _ := fs.Read("out/final.txt")
	fmt.Printf("%s", out) // 1: ABC
}
```

Individual builds are available through `build.Run(fs, targets, workers)`,
which returns the scheduling events, counts and error without any log
formatting; `kbl.Evaluate(fs)` evaluates `main.kiln` into a `plan.Plan`
without running anything.

## Design notes

* Every file in the VFS holds an immutable byte slice and a cached hash, so a
  content is hashed at most once; command outputs are hashed when produced.
* `glob` narrows a sorted path index by the pattern's literal prefix before
  running the matcher, and the matcher walks components by offset without
  per-candidate allocation.
* Values copy in O(1) (strings and lists are shared handles); each build
  lexes and parses every build file once, then walks the AST.
* The scheduler keeps two min-heaps keyed by step serial (undecided and
  decided-stale), so each step is pushed and popped O(1) times per build.
  Commands read their inputs when dispatched and write their outputs at their
  end time.
* The cycle search and reachability use an explicit stack (no recursion).
