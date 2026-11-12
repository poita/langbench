# buildsys — Kiln, an incremental build-system simulator

Kiln reads a *workspace* — build files written in the **Kiln Build Language**
(KBL) plus ordinary source files — evaluates the build files into a graph of
steps, and executes the out-of-date steps on a simulated set of parallel
workers against a virtual file system. Nothing is ever run by a real shell: the
sixteen built-in commands are implemented by the engine, every command has an
integer cost, and the scheduling is fully deterministic.

A *session* (`session.txt`) scripts a sequence of builds and workspace
mutations (`create`, `edit`, `delete`, `touch`, `clean`). Kiln writes a log of
everything that happened and the final state of the workspace. The complete
language, file formats and scheduler are defined in `problems/buildsys/SPEC.md`
of the repository this project lives in.

The library has no dependencies beyond GHC's bundled packages (`base`,
`bytestring`, `containers`, `array`, `directory`, `filepath`).

## Building

Requires GHC 9.14 and cabal 3.18.

```sh
./build.sh          # cabal build, then stage the executable at bin/buildsys
cabal build         # or build directly
cabal test          # the project's own tests (hspec + QuickCheck)
```

## Command-line use

```sh
./run.sh INPUT_DIR OUTPUT_DIR
# or: buildsys INPUT_DIR OUTPUT_DIR
```

`INPUT_DIR` contains `session.txt`, usually `main.kiln`, and the rest of the
initial workspace. `OUTPUT_DIR` receives

```
log.txt              the session log
workspace/<path>     every file of the final workspace (including .kiln-state)
```

Build errors are normal output (an `  error E_…` line in the log); the exit code
is `0` unless the program is invoked incorrectly.

Example:

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

The public API is documented with Haddock (`cabal haddock`). Modules, by
responsibility:

| Module | Responsibility |
|--------|----------------|
| `Kiln` | Top-level entry points (`runDirectory`, `runSession`, …) |
| `Kiln.Session` | Parsing session scripts, running steps, rendering `log.txt` |
| `Kiln.Build` | One build: configuration phases, scheduling, state update |
| `Kiln.Lexer`, `Kiln.Parser`, `Kiln.Syntax` | KBL lexing, parsing and AST |
| `Kiln.Eval`, `Kiln.Builtins`, `Kiln.Value` | Interpreter, the 39 built-in functions, value model |
| `Kiln.Glob` | Glob pattern compilation and matching |
| `Kiln.Step`, `Kiln.Command` | Step validation; the sixteen commands and their execution |
| `Kiln.Graph` | Reference resolution, duplicate detection, cycle search, reachability |
| `Kiln.State` | `.kiln-state` parsing/rendering and the freshness decision |
| `Kiln.Scheduler` | The deterministic worker simulation |
| `Kiln.Workspace`, `Kiln.Hash`, `Kiln.Path` | Virtual file system, FNV-1a hashing, path rules |
| `Kiln.Error` | The thirty error kinds and their rendering |

### Example

```haskell
{-# LANGUAGE OverloadedStrings #-}
import qualified Data.ByteString.Lazy.Char8 as BL
import qualified Kiln
import qualified Kiln.Workspace as W

main :: IO ()
main = do
  let ws = W.fromList
        [ ("main.kiln", "step {\n  out \"out/a.txt\"\n  cmd write(\"A\\n\")\n}\ndefault \"out/a.txt\"\n") ]
  (final, logText) <- Kiln.runSession ws (Kiln.parseSession "build\nbuild\n")
  BL.putStr logText                 -- the log: one run, then one cache hit
  print (map fst (W.toList final))  -- [".kiln-state","main.kiln","out/a.txt"]
```

Single builds are available through `Kiln.runBuild :: Workspace -> [ByteString] -> Int -> IO BuildResult`,
and individual KBL expressions can be evaluated with `Kiln.Eval.evalExprText`.

## Design notes

* Strings are byte strings throughout (`Data.ByteString`); nothing is decoded.
* Each file carries a lazily computed FNV-1a hash, so every distinct content is
  hashed at most once and the hash survives across builds.
* `glob` binary-searches the sorted path index by the pattern's wildcard-free
  prefix and matches only the candidates in that range.
* Lists are `Data.Sequence`s: copying is O(1), `a ++ b` is O(log min), indexing
  is O(log n).
* The scheduler keeps its ready sets in `IntSet`s ordered by step serial, so
  every ready-set operation is O(log R).
* Commands run against an immutable snapshot taken when they are dispatched and
  their outputs are applied at their end time, which is exactly the model the
  specification gives.

## Tests

`cabal test` runs hspec suites for the glob matcher (with a QuickCheck
comparison against a naive reference), the lexer/parser, the evaluator and
built-ins, the commands and hashing, the state file (including a round-trip
property) and whole sessions taken from the specification's worked examples.
