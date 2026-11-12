# buildsys — Kiln, an incremental build system

Kiln reads a *workspace* — build files written in the **Kiln Build Language**
(KBL) plus ordinary source files — evaluates the build files into a graph of
build steps, and executes the out-of-date steps on a **simulated** pool of
parallel workers against a **virtual** file system. No real shell is ever
run: Kiln's sixteen built-in commands (`write`, `copy`, `concat`, `upper`,
`grep`, `preprocess`, …) are implemented by the engine, and every command has
an integer *cost* that drives a fully deterministic scheduling simulation.

A *session* is a scripted sequence of builds and workspace edits. Kiln runs the
whole session and writes a log of everything that happened, plus the final
state of the workspace.

Highlights:

- content-based change detection (64-bit FNV-1a), a `.kiln-state` file, early
  cutoff, and discovered dependencies through depfiles (`preprocess` / `@need`);
- a small language with variables, scopes, `when`/`each`, rule templates,
  `include`, 39 built-in functions and glob patterns;
- deterministic scheduling: ready steps by creation order, lowest free worker
  first, cache hits settled before dispatch;
- one error per failed build, with a precise, stable message.

The standard library is the only dependency.

## Building

Requires Rust 1.96 or later.

```sh
cargo build --release      # or ./build.sh
cargo test                 # unit, integration and doc tests
```

The binary is `target/release/buildsys`; `./run.sh` runs it from any directory.

## Command line

```
buildsys <input directory> <output directory>
```

The input directory contains:

```
session.txt    the session script (required)
main.kiln      the root build file
...            the initial workspace (sources, other build files, .kiln-state)
```

`session.txt` holds one step per line (`#` comments and blank lines are
skipped):

| Step | Meaning |
|------|---------|
| `build [TARGET ...] [-j N]` | run a build (`@phony` or path targets; default targets if none) on `N` workers |
| `create PATH` / `edit PATH` | followed by content lines and a closing `---` line |
| `delete PATH`, `touch PATH` | delete a file; update its stamp (never causes a rebuild) |
| `clean` | remove `out/…` and `.kiln-state` |

The output directory receives:

```
log.txt          the session log
workspace/...    every file of the final workspace
```

A build error is normal output (a `  error E_... ` line in the log); the exit
status is 0 whenever the session ran. Example:

```
$ cat in/main.kiln
step {
    out "out/hello.txt"
    cmd write("hello\n")
}
default "out/hello.txt"
$ printf 'build\nbuild\n' > in/session.txt
$ buildsys in out && cat out/log.txt
step 1: build (default) -j 1
  run 0 1 w0 out/hello.txt write("hello\n")
  ok ran=1 hit=0 time=1
step 2: build (default) -j 1
  hit 0 out/hello.txt
  ok ran=0 hit=1 time=0
```

## Library

The crate `buildsys` exposes each stage as a module (see the crate docs):
`workspace` (virtual file system), `lexer`/`parser`/`ast`, `value`/`builtins`/`eval`
(the interpreter), `step`/`command`, `graph`, `state`, `build` (one build with the
scheduler) and `session`.

```rust
use buildsys::{build, parse_session, run_session, Workspace};

let mut ws = Workspace::new();
ws.write(
    b"main.kiln",
    b"step {\n    out \"out/hello.txt\"\n    cmd write(\"hello\\n\")\n}\ndefault \"out/hello.txt\"\n".to_vec(),
);

// Drive a whole session and get the log text ...
let log = run_session(&mut ws, &parse_session(b"build\nbuild\n"));
assert!(String::from_utf8(log).unwrap().contains("hit 0 out/hello.txt"));

// ... or run a single build and inspect the structured report.
let report = build(&mut ws, &[b"out/hello.txt".to_vec()], 4);
let summary = report.result.unwrap();
assert_eq!((summary.ran, summary.hits), (0, 1));
```

`buildsys::run_directory(input, output)` is the whole CLI as a function.

## Layout

```
src/
  lib.rs        crate docs, re-exports, run_directory
  main.rs       the command-line tool
  workspace.rs  virtual file system, path rules, glob index
  hash.rs       FNV-1a
  glob.rs       glob patterns
  lexer.rs      comments, logical lines, tokens
  parser.rs     statements, blocks, expressions, string literals
  ast.rs        syntax trees
  value.rs      values, total order
  builtins.rs   the 39 functions
  eval.rs       interpreter: scopes, rules, include, steps
  step.rs       step validation
  command.rs    the 16 commands, canonical command strings
  graph.rs      resolution, validation, cycles, reachability
  state.rs      .kiln-state and freshness
  build.rs      one build: scheduler and state update
  session.rs    session scripts and log
  error.rs      the 30 error kinds
tests/
  examples.rs   the specification's worked examples
```

## Design notes

- Strings and lists are reference counted, so copying is O(1); `a ++ b` is
  O(|a| + |b|).
- Every file's hash is computed once, when its content is stored, and reused by
  `hash()` inputs, freshness checks and state lines.
- `glob` binary-searches a sorted path index by the pattern's wildcard-free
  prefix instead of scanning every file.
- The scheduler takes ready steps from binary heaps keyed by serial number, so a
  ready-set operation is O(log R).
