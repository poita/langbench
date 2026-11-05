# Kiln

Kiln is an incremental build system written in Go with no dependencies beyond
the standard library. It reads a *workspace* — build files written in the Kiln
Build Language (KBL) plus ordinary source files — evaluates them into a graph
of build steps, and runs the out-of-date steps on a simulated pool of parallel
workers against an in-memory virtual file system. Nothing ever invokes a real
shell: Kiln's sixteen built-in commands run inside the engine, and each has an
integer cost that drives a fully deterministic scheduling simulation. Freshness
is decided by content hashes (64-bit FNV-1a) recorded in a `.kiln-state` file,
so touching a file never causes a rebuild and an unchanged intermediate output
cuts the rebuild short ("early cutoff").

The language, file formats, error messages and scheduler are specified in
`problems/buildsys/SPEC.md`; the design notes are in `problems/buildsys/APPROACH.md`.

## Building

Requires Go 1.27 or newer.

```sh
./build.sh            # produces bin/kiln
go test ./...         # unit tests
```

`build.sh` is just `go build -o bin/kiln ./cmd/kiln` and works from any
directory.

## Command-line use

```sh
./run.sh <input directory> <output directory>      # or: bin/kiln <in> <out>
```

The input directory holds `session.txt`, a script of builds and workspace
mutations, and the initial workspace (`main.kiln`, sources, optionally
`.kiln-state` and `out/…`). The program writes into the output directory:

- `log.txt` — one block per session step: a header, event lines (`run`,
  `hit`, `fail`, `cancel`, `remove`) and a result line;
- `workspace/…` — every file of the final workspace.

Build errors (a cycle, a type error, a failing command) are normal log output;
the exit status is 0 unless the input could not be read or the output could not
be written. A session looks like this:

```
build @all -j 4        # build with 4 workers
touch src/a.txt        # never causes a rebuild
edit src/a.txt         # followed by content lines and a closing '---'
new text
---
delete src/b.txt
clean                  # removes out/… and .kiln-state
```

A minimal workspace:

```
main.kiln:
    step {
        out "out/hello.txt"
        cmd write("hello\n")
    }
    default "out/hello.txt"
session.txt:
    build
    build
```

gives

```
step 1: build (default) -j 1
  run 0 1 w0 out/hello.txt write("hello\n")
  ok ran=1 hit=0 time=1
step 2: build (default) -j 1
  hit 0 out/hello.txt
  ok ran=0 hit=1 time=0
```

## Library

Everything the CLI does is available as a library (module name `kiln`). Each
package has one responsibility:

| Package | Responsibility |
|---------|----------------|
| `kiln/errs` | the `Error` type and the thirty error kinds |
| `kiln/vfs` | virtual file system, workspace-path rules, FNV-1a hashing, glob index, disk load/store |
| `kiln/glob` | glob pattern compiler and allocation-free matcher |
| `kiln/cmds` | the sixteen built-in commands, canonical command strings |
| `kiln/kbl` | KBL lexer, parser, values, 39 built-in functions, statement interpreter → `Program` of steps |
| `kiln/build` | graph validation, cycle detection, state file, freshness, the scheduler → `Result` |
| `kiln/session` | `session.txt` parser, session driver, log writer |

### Example

```go
package main

import (
	"fmt"

	"kiln/build"
	"kiln/session"
	"kiln/vfs"
)

func main() {
	fs := vfs.New()
	fs.Write("main.kiln", []byte(`
step {
    out "out/greeting.txt"
    cmd write("hello\n")
}
step {
    out "out/loud.txt"
    in "out/greeting.txt"
    cmd upper()
}
default "out/loud.txt"
`))

	// Drive a scripted session and get the log text...
	script, _ := session.Parse([]byte("build -j 2\nbuild\n"))
	fmt.Print(script.Run(fs))

	// ...or run a single build and inspect the structured result.
	res := build.Run(fs, build.Request{Targets: []string{"out/loud.txt"}, Workers: 4})
	fmt.Println(res.Ran, res.Hits, res.Time, res.Err)

	out, _ := fs.Read("out/loud.txt")
	fmt.Printf("%q\n", out)
}
```

The first part of this program is checked by `session/example_test.go`.

Notes on the API:

- `vfs.FS` is the workspace: `Write`, `Read`, `Delete`, `Touch`, `Paths`,
  plus `LoadDir` / `WriteDir` for real directories. Hashes are cached per file
  content and invalidated by writes.
- `kbl.Evaluate(fs)` runs `main.kiln` and returns a `*kbl.Program` (steps,
  phony targets, default targets) or an `*errs.Error`.
- `build.Run(fs, req)` performs a full build — evaluation, validation, state
  loading, scheduling, state writing — and returns events, counters and the
  single error, if any. Configuration errors leave the file system untouched.
- `glob.Compile(pattern)` returns a `*glob.Pattern` with `Match` and
  `LiteralPrefix`; a `Pattern` is not safe for concurrent use.

## Layout

```
cmd/kiln/    command-line tool (a thin wrapper over session.RunDir)
errs/ vfs/ glob/ cmds/ kbl/ build/ session/   library packages, each with *_test.go
build.sh run.sh                                 build and run scripts
```
