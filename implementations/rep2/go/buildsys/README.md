# buildsys — Kiln, an incremental build system

Kiln reads a *workspace* (build files written in the **Kiln Build Language**,
KBL, plus ordinary source files), evaluates the build files into a graph of
build steps, and executes the out-of-date steps on a simulated pool of parallel
workers against a virtual file system. Nothing is ever run by a real shell: the
sixteen built-in commands are implemented by the engine, and every command has
an integer *cost* that drives a fully deterministic scheduling simulation.

Change detection is purely content based (FNV-1a 64-bit hashes recorded in a
`.kiln-state` file), so touching a file never causes a rebuild, and a step
whose upstream re-ran but produced identical bytes is still a cache hit (early
cutoff).

This repository contains a reusable Go library and a thin command-line tool
that runs a scripted *session* — a sequence of builds and workspace edits — and
writes a log plus the final workspace. The full behaviour is specified in
`problems/buildsys/SPEC.md`; the design follows `problems/buildsys/APPROACH.md`.

Only the Go standard library is used (Go 1.27.1).

## Building

```sh
./build.sh          # go build -o bin/kiln ./cmd/kiln
go test ./...       # unit and integration tests
```

`build.sh` and `run.sh` work from any directory.

## Command-line use

```
kiln <input directory> <output directory>
./run.sh <input directory> <output directory>
```

The input directory contains `session.txt` (the script), `main.kiln` (the root
build file) and the initial workspace files. The tool writes

```
<output>/log.txt             the session log
<output>/workspace/<path>    every file of the final workspace
```

and exits 0 even when builds fail (a build error is ordinary log output).
`session.txt` has one step per line:

```
build [TARGET ...] [-j N]    run a build (targets are paths or @phony names)
create PATH                  followed by content lines and a closing "---" line
edit PATH                    same as create, for an existing file
delete PATH
touch PATH                   updates the modification stamp only
clean                        removes out/... and .kiln-state
```

Lines that are blank or start with `#` are skipped. A small example:

`main.kiln`

```
let names = ["alpha", "beta"]
each i, n in names {
    step {
        out "out/{n}.txt"
        cmd write("{i}:{n}\n")
    }
}
step {
    out "out/all.txt"
    in map(names, "out/%.txt")
    cmd concat()
}
default "out/all.txt"
```

`session.txt`

```
build -j 2
build -j 2
```

`log.txt`

```
step 1: build (default) -j 2
  run 0 1 w0 out/alpha.txt write("0:alpha\n")
  run 0 1 w1 out/beta.txt write("1:beta\n")
  run 1 3 w0 out/all.txt concat()
  ok ran=3 hit=0 time=3
step 2: build (default) -j 2
  hit 0 out/alpha.txt
  hit 0 out/beta.txt
  hit 0 out/all.txt
  ok ran=0 hit=3 time=0
```

## Library layout

The module is named `buildsys`. Each package has one responsibility:

| Package | Responsibility |
|---------|----------------|
| `buildsys` | The engine entry point: `Build` runs the build phases against a `vfs.FS`. |
| `buildsys/vfs` | Virtual file system, FNV-1a hashing (cached per content), workspace path validation, sorted glob index, loading from / exporting to a real directory. |
| `buildsys/kerr` | The `Error` type (kind + detail) shared by all layers, with a constant per error kind. |
| `buildsys/glob` | Glob pattern compiler and matcher (`*`, `?`, classes, `**`). |
| `buildsys/kbl` | The Kiln Build Language: lexer, parser, tree-walking evaluator over a chain of scopes, values and the 39 built-in functions. |
| `buildsys/cmds` | The sixteen commands: static specs, canonical rendering, execution (including `preprocess` and depfiles). |
| `buildsys/graph` | Steps, phony targets, graph construction and validation, the deterministic cycle-detecting DFS, reachability. |
| `buildsys/state` | `.kiln-state` reader/writer and the freshness decision. |
| `buildsys/sched` | The event-driven scheduler simulation (priority queues, workers, failure and cancellation). |
| `buildsys/session` | Session script parsing, running and log formatting. |
| `buildsys/cmd/kiln` | The command-line tool. |

## Library example

```go
package main

import (
	"fmt"

	"buildsys"
	"buildsys/session"
	"buildsys/vfs"
)

func main() {
	fs := vfs.New()
	fs.Write("main.kiln", `
step {
    out "out/a.txt"
    cmd write("A\n")
    cost 3
}
step {
    out "out/b.txt"
    in "out/a.txt"
    cmd upper()
}
default "out/b.txt"
`)

	// Run builds directly...
	res := buildsys.Build(fs, buildsys.Options{Workers: 2})
	fmt.Println(res.Ran, res.Hits, res.Time, res.Err) // 2 0 5 <nil>

	// ...or drive a whole scripted session and get its log.
	log, _ := session.RunScript(fs, "build\nclean\nbuild -j 4\n")
	fmt.Print(log)
}
```

`buildsys.Build` returns a `*buildsys.Result` with the scheduler events (hits,
runs, failures, cancellations), the counts, the simulated completion time and
the build's single `*kerr.Error`, if any. Configuration errors (parse errors,
unknown variables, cycles, ...) leave the workspace untouched; execution errors
(such as a `preprocess` `@need` failure) still write `.kiln-state`.

## Design notes

* Every distinct file content is hashed once (`vfs.File` caches its hash), and
  `File` snapshots are immutable, so freshness checks, `hash()` and the state
  file reuse hashes across builds.
* `glob` binary-searches a sorted index of eligible paths by the pattern's
  wildcard-free prefix instead of scanning the workspace.
* Strings and lists are immutable, so copying one is O(1); `++` allocates.
* The scheduler keeps undecided and stale-ready steps in binary heaps keyed by
  serial number, so each ready-set operation is O(log R).
* Every build evaluates afresh; only the file system carries over.
