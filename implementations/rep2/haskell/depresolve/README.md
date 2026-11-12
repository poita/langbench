# depresolve

A deterministic package dependency resolver. Given a registry (every version
of every package with its requirements) and a root manifest, it picks one
version per needed package using a fully specified search: **depth-first,
newest version first, chronological backtracking**. The first solution that
search finds is the answer, so every run (and every correct implementation)
prints the same resolution. If there is none, it prints `unsatisfiable`.

The search runs on an explicit stack with an undo trail. Pending requirements
are a shared immutable list, chosen versions live in a mutable array, and each
requirement's range is turned into a block of candidate indices once, up front,
by binary search. A search step is O(1) plus the requirements it adds, and the
recursion depth (about 10,000 pending requirements on large inputs) is bounded
only by memory.

## Build

Requires GHC 9.14 and cabal 3.18.

```sh
./build.sh            # or: cabal build exe:depresolve
cabal test            # run the test suite (hspec + QuickCheck)
```

## Command line

`./run.sh` reads a problem on stdin and writes the resolution on stdout. It
takes no arguments and always exits 0 for well-formed input (malformed input
prints a message on stderr and exits 1).

```
$ printf 'a 1.0.0: c ^1.0.0\nb 1.0.0: c ~1.2.0\nc 1.1.0:\nc 1.2.5:\nc 1.3.0:\nroot: a *, b *\n' | ./run.sh
a 1.0.0
b 1.0.0
c 1.2.5
```

### Input format

```
input         = { registry_line } root_line
registry_line = name " " version ":" requirements "\n"
root_line     = "root:" requirements "\n"
requirements  = ""  |  " " requirement { ", " requirement }
requirement   = name " " range
range         = "*" | version | "^" version | "~" version
              | comparator { " " comparator }
comparator    = ( "<" | "<=" | ">" | ">=" ) version
```

Versions are `MAJOR.MINOR.PATCH` and compared numerically. Caret and tilde
follow npm semantics (`^0.2.3` is `>=0.2.3 <0.3.0`, `^0.0.3` accepts only
`0.0.3`, `~X.Y.Z` is `>=X.Y.Z <X.(Y+1).0`).

### Output

One `name version` line per chosen package, sorted by name in ascending byte
order, or the single line `unsatisfiable`. An empty root yields empty output.

## Library

Modules, by responsibility:

| module | role |
|---|---|
| `Depresolve` | public facade: `resolve`, `resolveText`, re-exports |
| `Depresolve.Version` | `Version` and its numeric ordering |
| `Depresolve.Range` | `Range`, `satisfies`, interval form of a range |
| `Depresolve.Types` | `Problem`, `PackageVersion`, `Requirement` |
| `Depresolve.Parse` | parser for the text format |
| `Depresolve.Index` | interning, sorting, candidate-index blocks |
| `Depresolve.Resolve` | the iterative backtracking search |
| `Depresolve.Render` | output formatting |

Example:

```haskell
{-# LANGUAGE OverloadedStrings #-}
import qualified Data.ByteString.Char8 as B
import Depresolve

main :: IO ()
main = do
  -- Build a problem programmatically ...
  let problem = Problem
        { problemRegistry =
            [ PackageVersion "app-lib" (Version 2 0 0) [Requirement "util" (Tilde (Version 1 0 0))]
            , PackageVersion "util" (Version 1 0 5) []
            , PackageVersion "util" (Version 1 5 0) []
            ]
        , problemRoot = [Requirement "app-lib" Any, Requirement "util" Any]
        }
  case resolve problem of
    Nothing  -> putStrLn "unsatisfiable"
    Just sol -> mapM_ (\(n, v) -> putStrLn (B.unpack n ++ " " ++ renderVersion v)) sol
  -- ... or parse the text format.
  print (fmap resolve (parseProblem "a 1.0.0:\nroot: a ^1.0.0\n"))
```

## Tests

`cabal test` runs hspec specs for versions, ranges, the parser and the
resolver, including the worked examples from the specification, a 20,000-deep
chain (stack safety), and a QuickCheck property that compares the resolver with
a naive list-and-map transcription of the specified recursion on random small
registries (cycles, missing packages and empty ranges included).
