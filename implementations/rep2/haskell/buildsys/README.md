# buildsys — Kiln, an incremental build system simulator

Kiln reads a *workspace* — build files written in the **Kiln Build Language**
(KBL) plus ordinary source files — evaluates the build files into a graph of
build steps, and runs the steps that are out of date on a simulated pool of
parallel workers against a virtual file system. Nothing is ever executed by a
real shell: Kiln's sixteen built-in commands are implemented in Haskell and each
has an integer cost that drives a fully deterministic scheduling simulation.
Change detection is content based (64-bit FNV-1a hashes persisted in a
`.kiln-state` file), so touching a file never causes a rebuild and an unchanged
intermediate output cuts the rebuild off early.

The behaviour is defined by `problems/buildsys/SPEC.md`; this project is a
library plus a thin command-line tool on top of it.

## Layout

| Module | Responsibility |
|--------|----------------|
| `Kiln` | convenient re-exports of the high-level API |
| `Kiln.Workspace`, `Kiln.Workspace.IO` | the virtual file system (hashes computed lazily, once per content); loading/writing a real directory |
| `Kiln.Hash` | FNV-1a hashing and its 16-hex-digit rendering |
| `Kiln.Lexer`, `Kiln.Parser`, `Kiln.Syntax` | comment stripping, logical lines, tokens, string literals; parser and AST |
| `Kiln.Value`, `Kiln.Glob`, `Kiln.Builtins` | values and their total order, glob matching, the 39 built-in functions |
| `Kiln.Eval`, `Kiln.Step` | the interpreter (scopes, rules, `include`, `step` blocks) producing a `Program` of steps |
| `Kiln.Command` | the 16 commands, canonical rendering, `preprocess` with depfiles |
| `Kiln.Graph` | whole-graph validation, target resolution, deterministic cycle detection, reachability |
| `Kiln.State` | strict `.kiln-state` reader, canonical writer, freshness decision |
| `Kiln.Scheduler` | the event-driven worker simulation (hits, dispatch, failure and cancellation) |
| `Kiln.Build` | one whole build: configure, schedule, persist state |
| `Kiln.Session` | `session.txt` parsing, running a session, the log format |
| `Kiln.Error` | the thirty error kinds and their log rendering |

## Building

Requires GHC 9.14.1 and cabal 3.18.2.0 (only GHC's bundled packages are used;
the tests additionally use `hspec` and `QuickCheck`).

```
cabal build            # library + executable
cabal test             # unit and property tests
./build.sh             # cabal build, then copy the executable to bin/buildsys
```

## Command line

```
buildsys <input directory> <output directory>
# or, after ./build.sh:
./run.sh <input directory> <output directory>
```

The input directory holds `session.txt` (the session script), usually a
`main.kiln`, and the initial workspace files. The tool writes

* `<output>/log.txt` — one block per session step (`build`, `create`, `edit`,
  `delete`, `touch`, `clean`) with `run` / `hit` / `fail` / `cancel` events
  and a result line, and
* `<output>/workspace/…` — the final virtual workspace, including
  `.kiln-state` and generated files.

A build error is normal output (an `error E_…` line in the log); the exit
status is `0` unless the arguments are wrong or the files cannot be read or
written.

Example `session.txt`:

```
build @all -j 4
touch src/a.txt
edit src/a.txt
new contents
---
build @all -j 4
clean
```

and a `main.kiln`:

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
phony all = ["out/index.txt"]
default "@all"
```

## Library example

```haskell
{-# LANGUAGE OverloadedStrings #-}
import Kiln

main :: IO ()
main = do
  let ws0 = fromFiles
        [ ("main.kiln", "step {\n  out \"out/hello.txt\"\n  cmd write(\"hello\\n\")\n}\ndefault \"out/hello.txt\"\n") ]

      -- A single build on two simulated workers.
      first = build ws0 (BuildRequest { brTargets = [], brWorkers = 2 })

  mapM_ print (boEvents first)                 -- the run/hit events
  print (either renderError (const "ok") (boResult first))

  -- Builds are pure: thread the resulting workspace into the next build to
  -- see incremental behaviour (this one is a cache hit).
  let second = build (boWorkspace first) (BuildRequest [] 2)
  print (map evKind (boEvents second))         -- [Hit]

  -- Or drive a whole scripted session and get the log text.
  let (logText, _final) = runSession ws0 (parseSession "build\nbuild\nclean\n")
  putStr (show logText)
```

Every pipeline stage is also exposed on its own — for instance
`Kiln.Parser.parseSource`, `Kiln.Eval.evalProgram`, `Kiln.Glob.compilePattern`
and `Kiln.State.parseState` — which is how the test suite exercises them.

## Design notes

* A file's hash is a lazy field of the stored file, so each distinct content is
  hashed at most once and shared by freshness checks, `hash()` and the state
  file.
* `glob` uses the sorted workspace map as its index: a binary-search split on
  the pattern's wildcard-free prefix, then matching only those paths. Pattern
  matching is an NFA simulation (O(pattern × path), no backtracking).
* KBL lists are `Data.Sequence`s and strings are `ByteString`s, so copying is
  O(1), indexing is O(log n), and `a ++ b` is no worse than linear.
* Scopes live in an `IntMap` indexed by scope id, so rules can capture their
  defining scope *by reference*, as the specification requires.
* The scheduler keeps undecided and stale steps in ordered sets, so taking the
  lowest-serial ready step is O(log R). A command's inputs are captured as a
  persistent snapshot when it is dispatched, and its result is computed lazily
  at its end time.
* `touch` has no observable effect (modification stamps are never recorded or
  compared), so the session driver implements it as a no-op.
