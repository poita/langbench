# Kiln

Kiln is a deterministic, incremental build system **simulator**. It reads a
*workspace* containing build files written in the **Kiln Build Language**
(KBL) and ordinary source files, evaluates the build files into a graph of
build steps, and executes the steps that are out of date on a simulated set of
parallel workers against a virtual file system.

Nothing is ever run by a real shell. Kiln's sixteen built-in commands
(`write`, `copy`, `concat`, `upper`, `lower`, `grep`, `replace`, `sort_lines`,
`reverse_lines`, `dedup`, `number`, `indent`, `wrap`, `count_lines`, `hash`,
`preprocess`) are implemented by the engine, and every command has an integer
*cost* that drives a fully deterministic scheduling simulation. Change
detection is content based (64-bit FNV-1a), recorded in a `.kiln-state` file
inside the workspace, and supports early cutoff and depfile-discovered
dependencies.

A *session* is a scripted sequence of builds and workspace mutations; Kiln
runs it and writes a log of everything that happened plus the final state of
the workspace.

The project is the Rust standard library only (no dependencies). It is a
library (`kiln`) with a thin command-line tool on top.

## Building

```sh
cargo build --release      # or: ./build.sh
cargo test                 # unit, integration and doc tests
```

`build.sh` and `run.sh` work from any directory; `run.sh` runs the release
binary at `target/release/kiln`.

## Command line

```
kiln <input directory> <output directory>
./run.sh <input directory> <output directory>
```

The input directory holds:

```
session.txt     the session script (required; not part of the workspace)
main.kiln       the root build file
<anything else> the initial workspace (sources, further build files, ...)
```

The tool writes into the (existing) output directory:

```
log.txt             the session log
workspace/<path>    every file of the final workspace
```

Standard input is not read; the exit status is 0 even when builds fail (a
build error is reported in the log, not as a program failure). A nonzero
status means a usage or I/O problem, or a malformed `session.txt`.

### session.txt

```
# comments and blank lines are skipped
build [TARGET ...] [-j N]   # run a build; no targets = the `default` targets
create PATH                 # followed by content lines and a line `---`
edit PATH                   # same as create, for an existing path
delete PATH
touch PATH                  # updates a stamp; never causes a rebuild
clean                       # removes out/** and .kiln-state
```

### A small example

`main.kiln`:

```
let names = ["alpha", "beta"]
each i, n in names {
    step {
        out "out/{n}.txt"
        cmd write("{i}:{n}\n")
    }
}
step {
    out "out/index.txt"
    in map(names, "out/%.txt")
    cmd concat()
}
default "out/index.txt"
```

`session.txt`:

```
build -j 2
build -j 2
```

`log.txt`:

```
step 1: build (default) -j 2
  run 0 1 w0 out/alpha.txt write("0:alpha\n")
  run 0 1 w1 out/beta.txt write("1:beta\n")
  run 1 3 w0 out/index.txt concat()
  ok ran=3 hit=0 time=3
step 2: build (default) -j 2
  hit 0 out/alpha.txt
  hit 0 out/beta.txt
  hit 0 out/index.txt
  ok ran=0 hit=3 time=0
```

Log lines are `run <start> <end> w<worker> <target> <command>` for executed
steps, `hit <time> <target>` for cache hits, `fail` / `cancel` for execution
errors, and a final `ok ...` or `error <KIND> <detail>` line per session step.

## Library

The public API is organised by responsibility:

| Module | Responsibility |
|--------|----------------|
| `workspace` | the virtual file system with cached content hashes and a sorted path index |
| `parser`, `ast` | KBL text to syntax trees |
| `value`, `glob` | KBL values (with their total order) and the glob matcher |
| `step`, `command` | steps, phony targets, validation, the sixteen commands |
| `state` | the `.kiln-state` reader/writer and the freshness decision |
| `engine` | one complete build (`kiln::build`) |
| `session` | session scripts and the log |
| `error` | the thirty error kinds |

Run a whole session:

```rust
use kiln::{Session, Workspace};

let mut ws = Workspace::new();
ws.write(
    "main.kiln",
    b"step {\n    out \"out/hello.txt\"\n    cmd write(\"hello\\n\")\n}\ndefault \"out/hello.txt\"\n".to_vec(),
);

let session = Session::parse(b"build\nbuild\n").unwrap();
let log = String::from_utf8(session.run(&mut ws)).unwrap();
assert!(log.contains("run 0 1 w0 out/hello.txt write(\"hello\\n\")"));
assert!(log.contains("hit 0 out/hello.txt"));
assert_eq!(ws.read("out/hello.txt"), Some(&b"hello\n"[..]));
```

Or drive a single build and inspect the structured report:

```rust
use kiln::{build, EventKind, Workspace};

let mut ws = Workspace::new();
ws.write("src/a.txt", b"abc\n".to_vec());
ws.write(
    "main.kiln",
    b"step {\n    out \"out/a.txt\"\n    in \"src/a.txt\"\n    cmd upper()\n}\ndefault \"out/a.txt\"\n".to_vec(),
);

let report = build(&mut ws, &[], 4);
let summary = report.outcome.unwrap();
assert_eq!((summary.ran, summary.hits, summary.time), (1, 0, 2));
assert_eq!(report.events[0].kind, EventKind::Run);
assert_eq!(ws.read("out/a.txt"), Some(&b"ABC\n"[..]));

// A second build finds everything fresh.
let again = build(&mut ws, &[], 4).outcome.unwrap();
assert_eq!((again.ran, again.hits), (0, 1));
```

Build errors are values: `report.outcome` is `Err(kiln::Error)`, whose
`kind()` is an `ErrorKind` and whose `to_string()` is the text that appears
after `error ` in the log (for example `E_UNKNOWN_VAR greeting`).

## Design notes

* **Hashing.** Each file caches its FNV-1a hash, computed lazily and at most
  once per distinct content; freshness checks and state lines reuse it.
* **Evaluation.** Every build lexes, parses and interprets the build files
  afresh with a tree-walking interpreter over a chain of reference-counted
  scopes. Strings and lists are reference counted, so copying a value is O(1).
* **Glob.** The workspace keeps its paths in a sorted map; `glob` binary
  searches to the pattern's literal prefix and tests only paths sharing it.
* **Scheduling.** An event-driven simulation: ready steps come out of binary
  heaps keyed by serial number (O(log R)), workers are handed out
  lowest-id-first and the clock jumps to the next completion. Commands read
  their inputs when dispatched and write their outputs at their end time.
* **State.** `.kiln-state` is parsed strictly (any deviation means "empty")
  and written canonically, sorted by primary output.
