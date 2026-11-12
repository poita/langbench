# depresolve

A deterministic package dependency resolver for semver-style registries.
Given every version of every package (each with its requirements) and a root
manifest, it picks one version per needed package by running a fully
specified search: depth-first, requirements in listed order, newest candidate
first, chronological backtracking. The answer is the first solution that
search finds, so every run (and every implementation of the spec) agrees.

The search runs over an explicit stack of choice points, with requirements
precompiled to index ranges over each package's newest-first version list,
pending requirements shared as an immutable list, and chosen versions undone
through a mutable array. A search step is O(1) plus the requirements it adds,
and deep (10,000+ pending requirements) inputs need no call stack.

## Build

Requires GHC 9.14 and cabal 3.18. Only GHC's bundled packages are used
(`hspec` and `QuickCheck` for the tests).

```
./build.sh           # or: cabal build exe:depresolve
cabal test           # unit and property tests
```

## Command line

`run.sh` (or the `depresolve` executable) reads the registry and root manifest on
standard input and writes the resolution to standard output:

```
$ printf 'a 1.0.0: c ^1.0.0\nb 1.0.0: c ~1.2.0\nc 1.1.0:\nc 1.2.5:\nc 1.3.0:\nroot: a *, b *\n' | ./run.sh
a 1.0.0
b 1.0.0
c 1.2.5
```

Input is `name version: req, req, ...` lines followed by one `root: ...` line;
ranges are `*`, `X.Y.Z`, `^X.Y.Z`, `~X.Y.Z` or space-separated comparators
(`>=1.0.0 <2.0.0`). Output is one `name version` line per chosen package in
byte order of name, or the single line `unsatisfiable`. Both exit with
status 0. Malformed input exits 1 with a message on stderr.

## Library

| module | responsibility |
|---|---|
| `Depresolve` | convenient re-exports and `resolveInput` |
| `Depresolve.Version` | `Version`, order-preserving integer keys |
| `Depresolve.Range` | `Range`, `satisfies`, interval form of a range |
| `Depresolve.Registry` | `Registry`, `Requirement` |
| `Depresolve.Parse` | parser for the text format |
| `Depresolve.Resolve` | the search (`resolve`) |

```haskell
import Depresolve

main :: IO ()
main = do
  let reg = fromEntries
        [ ("a", mkVersion 1 0 0, [Requirement "b" (Caret (mkVersion 1 0 0))])
        , ("b", mkVersion 1 2 0, [])
        , ("b", mkVersion 2 0 0, [])
        ]
  print (resolve reg [Requirement "a" Any])
  -- Just [("a",Version {..1.0.0}),("b",Version {..1.2.0})]
```

`parseProblem :: ByteString -> Either String (Registry, [Requirement])` reads
the text format, and `resolve :: Registry -> [Requirement] -> Maybe Resolution`
returns `Nothing` when no resolution exists.
