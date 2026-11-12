# hjq

`hjq` is a small implementation of a subset of the [jq](https://jqlang.github.io/jq/)
filter language (semantics of jq 1.7, `jq -c`), written in Haskell using only
GHC's bundled libraries (`base`, `bytestring`, `containers`, `text`). It
contains its own JSON parser, JSON serialiser, filter parser and evaluator.

The package provides a library (`hjq`) and a command-line tool (`hjq`).

## Building

Requires GHC 9.14 and cabal 3.18.

```sh
./build.sh          # cabal build, then copies the binary to bin/hjq
cabal test          # unit tests (hspec) and properties (QuickCheck)
```

## Command-line usage

`hjq` reads all of stdin. The **first line** is the filter; the rest is one
JSON document. Every result is printed as compact JSON on its own line. If
evaluation raises an uncaught error, the results produced so far are printed,
followed by a line `error`, and evaluation stops. The exit status is 0.

```sh
$ printf '%s\n%s\n' '.users | map(select(.age >= 30)) | sort_by(.age) | map(.name)' \
    '{"users":[{"name":"ann","age":31},{"name":"bo","age":20},{"name":"cy","age":30}]}' | ./run.sh
["cy","ann"]
```

`run.sh` runs the binary built by `build.sh` from any directory.

### Supported language

* Paths: `.`, `.foo`, `."foo"`, `.[e]`, `.[]`, `.[a:b]`, with `?`
* Operators: `|`, `,`, `+ - * / %`, `== != < <= > >=`, `and`, `or`, unary `-`
* Constructors: `[...]`, `{a: 1, "b": 2, (expr): 3, c, $x}`
* Control: `if/elif/else/end`, `E as $x | body`, `reduce E as $x (init; update)`
* Builtins: `empty error error(f) not length keys has(k) type add select(f)
  map(f) sort sort_by(f) group_by(f) unique reverse min max tostring tonumber`

Generators follow jq's evaluation order (for binary operators the right
operand is the outer loop). Objects keep insertion order; `keys` sorts.

## Library usage

```haskell
import qualified Data.Text as T
import Jq

main :: IO ()
main =
  case query (T.pack ".a | map(. * 2)") (T.pack "{\"a\":[1,2,3]}") of
    Left err   -> putStrLn ("syntax error: " ++ err)
    Right outs -> mapM_ (putStrLn . either (const "error") (T.unpack . renderText)) outs
-- prints: [2,4,6]
```

`query` parses the filter and document; `runFilter` runs an already parsed
filter (`parseFilter`) on a `Value` (`parseJson`). The result list is lazy: a
runtime error appears as one trailing `Left`.

### Modules

| Module | Responsibility |
|---|---|
| `Jq` | Facade: `query`, `runFilter`, re-exports |
| `Jq.Value` | `Value`, insertion-ordered `Object`, jq's total ordering |
| `Jq.Number` | Exact decimal→double conversion, shortest number rendering |
| `Jq.Json.Parse` / `Jq.Json.Render` | JSON parser and compact serialiser |
| `Jq.Syntax`, `Jq.Lexer`, `Jq.Parser` | Filter AST, tokeniser, recursive-descent parser |
| `Jq.Stream` | Lazy result stream with error termination |
| `Jq.Ops` | Pure operators and builtins on values |
| `Jq.Eval` | Lazy tree-walking evaluator |

## Design notes

Values are immutable and shared (never deep-copied). Arrays are
`Data.Sequence`s, objects pair a `Map` (key lookup, sorted keys for free) with
an `IntMap` recording insertion order. Sorting uses a stable merge sort with
one key evaluation per element; `add` concatenates in a single pass.
