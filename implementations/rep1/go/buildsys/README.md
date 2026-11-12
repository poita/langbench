# buildsys — Kiln, an incremental build system

Kiln reads a *workspace* of build files written in the **Kiln Build Language**
(KBL), evaluates them into a graph of build steps, and runs the steps that are
out of date on a simulated pool of parallel workers against a virtual file
system. Nothing is executed by a real shell: Kiln's sixteen built-in commands
are implemented in-process, and every command has an integer *cost* that drives
a fully deterministic scheduling simulation. Change detection is content based
(64-bit FNV-1a hashes recorded in `.kiln-state`), so touching a file never
causes a rebuild and an unchanged intermediate output cuts the rebuild off early.

A *session* (`session.txt`) scripts a sequence of builds and workspace edits;
the tool writes a log of everything that happened plus the final workspace.

Only the Go standard library is used.

## Building

Requires Go 1.27.1.

```sh
./build.sh          # builds bin/kiln with `go build`
go test ./...       # runs the unit and end-to-end tests
```

## Command-line usage

```sh
./run.sh <input directory> <output directory>
# or: bin/kiln <input directory> <output directory>
```

The input directory contains `session.txt`, usually `main.kiln` (the root
build file), and the initial workspace files. The output directory receives:

```
log.txt            the session log
workspace/<path>   every file of the final workspace
```

Build errors are part of the normal output (an `error` line in the log); the
exit status is 0 unless the input or output directory cannot be read or written.

Example session:

```
build @all -j 4        # build with four workers
touch src/a.txt        # no effect on freshness
edit src/a.txt         # replace a file's content (block ends at "---")
line one
---
build @all -j 2
clean                  # delete out/ and .kiln-state
```

And a build file:

```
rule bundle(name, parts, weight = 2) {
    step {
        out "out/{name}.txt"
        in parts
        cmd concat()
        cost weight
    }
}
let srcs = glob("src/**/*.txt")
use bundle("all", srcs)
default "out/all.txt"
```

## Layout

| Package | Responsibility |
|---------|----------------|
| `kerr` | The thirty error kinds and their rendering (`E_TYPE …`). |
| `vfs` | In-memory workspace, cached FNV-1a content hashes, a sorted glob index, loading from / writing to a directory. |
| `glob` | Glob pattern compiler and matcher (`*`, `?`, `[...]`, `**`). |
| `cmds` | The sixteen commands: signatures, shape rules, canonical rendering, execution, `preprocess`. |
| `plan` | The data model produced by evaluation: steps, phony targets, defaults. |
| `kbl` | KBL lexer, parser and tree-walking interpreter, with the 39 built-in functions. |
| `graph` | Dependency graph, reference validation, deterministic cycle detection, reachability. |
| `state` | `.kiln-state` reader/writer and the freshness decision. |
| `sched` | The event-driven worker simulation, hit settling, failure and cancellation. |
| `engine` | One complete build: evaluate → validate → schedule → persist state. |
| `session` | Session script parser, the session driver and the log writer. |
| `cmd/kiln` | The thin command-line tool. |

## Using the library

```go
package main

import (
	"fmt"

	"buildsys/session"
	"buildsys/vfs"
)

func main() {
	ws := vfs.New()
	ws.Write("main.kiln", `
step {
    out "out/hello.txt"
    cmd write("hello\n")
}
default "out/hello.txt"
`)

	// Run a scripted session and print the log.
	log, err := session.RunScript(ws, "build\nbuild\n")
	if err != nil {
		panic(err)
	}
	fmt.Print(log)
	// step 1: build (default) -j 1
	//   run 0 1 w0 out/hello.txt write("hello\n")
	//   ok ran=1 hit=0 time=1
	// step 2: build (default) -j 1
	//   hit 0 out/hello.txt
	//   ok ran=0 hit=1 time=0

	content, _ := ws.Read("out/hello.txt")
	fmt.Printf("%q\n", content) // "hello\n"
}
```

For a single build, call `engine.Build(ws, targets, workers)`, which returns the
events, the summary figures and the build's single error (if any). The lower
layers are usable on their own: `kbl.Evaluate` turns build files into a
`plan.Plan`, `graph.New` validates it, and `glob.Compile` is a standalone
matcher.

## Design notes

* Every build evaluates the build files afresh; only the workspace (and its
  cached hashes and glob index) persists between builds.
* Values are immutable, so copying a string or list is O(1); `glob` binary
  searches a sorted index for the pattern's literal prefix.
* The scheduler keeps ready steps in min-heaps keyed by serial number, so each
  ready-set operation is O(log R); ties are always broken by step serial and
  workers are allocated lowest-id first.
* Strings are byte strings throughout; no operation is Unicode-aware.
