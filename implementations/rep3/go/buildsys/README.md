# buildsys — Kiln, an incremental build system

Kiln reads a *workspace* — build files written in the **Kiln Build Language**
(KBL) plus ordinary source files — evaluates the build files into a graph of
steps, and executes the steps that are out of date on a simulated set of
parallel workers against an in-memory file system. Nothing is ever run by a
real shell: Kiln's sixteen built-in commands (`write`, `copy`, `concat`,
`upper`, `grep`, `sort_lines`, `preprocess`, …) are implemented in-process, and
each has an integer cost that drives a fully deterministic scheduling
simulation. Change detection is content based (FNV-1a hashes recorded in a
`.kiln-state` file), so only the steps whose inputs, command line or outputs
changed are re-run, with early cutoff when a rebuilt step produces identical
bytes.

The program drives a whole *session*: a scripted sequence of builds and
workspace mutations (`build`, `create`, `edit`, `delete`, `touch`, `clean`).
It writes a log of everything that happened and the final state of the
workspace. The complete language and file-format definitions are in
`problems/buildsys/SPEC.md`; the design notes are in `APPROACH.md`.

Only the Go standard library is used (Go 1.27).

## Building

```sh
./build.sh          # go build -o bin/kiln ./cmd/kiln
go test ./...       # unit tests
```

`build.sh` and `run.sh` work from any current directory.

## Command line

```sh
./run.sh <input directory> <output directory>
```

The input directory contains `session.txt`, the optional root build file
`main.kiln`, and any other files, which form the initial workspace. The tool
writes

```
<output>/log.txt              the session log
<output>/workspace/<path>     every file of the final workspace
```

The exit status is 0 even if builds in the session fail: a build error is
reported as an `error` line in the log. Example:

```
$ cat in/main.kiln
step {
    out "out/hello.txt"
    cmd write("hello\n")
}
default "out/hello.txt"
$ printf 'build\nbuild\n' > in/session.txt
$ ./run.sh in out && cat out/log.txt
step 1: build (default) -j 1
  run 0 1 w0 out/hello.txt write("hello\n")
  ok ran=1 hit=0 time=1
step 2: build (default) -j 1
  hit 0 out/hello.txt
  ok ran=0 hit=1 time=0
```

## Library

Each package has one responsibility and a documented API:

| Package    | Responsibility |
|------------|----------------|
| `diag`     | The `Error` type (kind + detail) shared by every layer. |
| `vfs`      | In-memory file system with cached FNV-1a hashes, workspace-path validation, a sorted glob index, and loading/writing real directories. |
| `glob`     | Compiled glob patterns (`*`, `?`, `[..]`, `**`) with an allocation-free matcher. |
| `cmds`     | The sixteen commands: signatures, shape checks, canonical rendering, execution (including `preprocess`). |
| `plan`     | The evaluated build description: steps, phony targets, defaults; step validation. |
| `kbl`      | KBL lexer, parser and evaluator, including the 39 built-in functions. |
| `graph`    | Reference resolution, whole-graph validation, requested targets, cycle detection and reachability. |
| `state`    | Strict `.kiln-state` reader, canonical writer and the freshness test. |
| `sched`    | The deterministic worker simulation: cache-hit settling, dispatch, clock, failure and cancellation. |
| `engine`   | One complete build: the eight phases of the specification. |
| `session`  | `session.txt` parsing, session execution and log formatting. |

### Example

```go
package main

import (
	"fmt"

	"buildsys/engine"
	"buildsys/session"
	"buildsys/vfs"
)

func main() {
	fs := vfs.New()
	fs.Write("main.kiln", []byte(`
let names = ["a", "b"]
each n in names {
    step {
        out "out/{n}.txt"
        cmd write("{n}\n")
    }
}
step {
    out "out/all.txt"
    in map(names, "out/%.txt")
    cmd concat()
}
default "out/all.txt"
`))

	// Run a single build directly...
	rep := engine.Build(fs, nil, 2)
	fmt.Println(rep.Err, rep.Ran, rep.Hits, rep.Time) // <nil> 3 0 3

	// ...or drive a whole session and get the log text.
	log, _ := session.RunScript(fs, []byte("touch main.kiln\nbuild\n"))
	fmt.Print(string(log))

	out, _ := fs.Read("out/all.txt")
	fmt.Printf("%q\n", out)
}
```

Lower-level pieces can be used on their own, for instance
`kbl.Evaluate(fs, "main.kiln")` to get a `*plan.Build`, `glob.Compile` to match
paths, or `state.Parse` / `State.Encode` to inspect `.kiln-state`.

## Layout

```
cmd/kiln/    command-line tool (thin wrapper over session + vfs)
diag/ vfs/ glob/ cmds/ plan/ kbl/ graph/ state/ sched/ engine/ session/
build.sh     builds bin/kiln
run.sh       runs bin/kiln
```

Unit tests live next to each package in `*_test.go` files.
