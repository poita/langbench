# jq-hs

A small, from-scratch implementation of a subset of the [`jq`](https://jqlang.github.io/jq/)
filter language (semantics of jq 1.7, `jq -c`), written in Haskell using only
GHC's bundled libraries (`base`, `containers`, `bytestring`, `text`). It ships
as

* a **library** (`Jq` and friends): JSON parser and serializer, filter parser,
  and a lazy tree-walking interpreter with jq's generator semantics;
* a thin **command-line tool**, `jq-hs`, built on the library.

There is no JSON library or jq engine underneath: the JSON parser, the
serializer and the interpreter are all in this repository.

## Building

Requires GHC 9.14 and cabal 3.18.

```sh
./build.sh              # cabal build + copies the binary to bin/jq-hs
cabal test              # unit and property tests (hspec + QuickCheck)
```

## Command-line usage

The program takes no arguments. It reads **all of stdin**: the first line is
the filter, everything after the first newline is one JSON document. Every
result of the filter is printed as one line of compact JSON. If evaluation
raises an error that is not caught with `?`, the results produced before it are
printed, then a line `error`, and evaluation stops. The exit code is 0 on
success.

```sh
$ printf '%s\n%s\n' '.users | map(select(.age >= 30)) | sort_by(.age) | map(.name)' \
    '{"users":[{"name":"ann","age":31},{"name":"bob","age":25},{"name":"cy","age":30}]}' | ./run.sh
["cy","ann"]

$ printf '%s\n%s\n' '[(1,2) + (10,20)], {a:(1,2)}' 'null' | ./run.sh
[11,12,21,22]
{"a":1}
{"a":2}
```

### Supported language

* Paths: `.`, `.foo`, `."foo bar"`, `.[k]`, `.[]`, `.[a:b]`, with `?` (tolerant
  per-operation after a path suffix; `try` after any other term).
* Operators: `|`, `,`, `+ - * / %`, unary `-`, `== != < <= > >=`, `and`, `or`.
* Constructs: literals, `[ ... ]`, `{ ... }` (including `{a}`, `{$x}`,
  `{(expr): v}`), `if/elif/else/end`, `E as $x | body`, `reduce`.
* Builtins: `empty error error(f) not length keys has type add select map sort
  sort_by group_by unique reverse min max tostring tonumber`.

Evaluation is lazy and ordered exactly as in jq (for instance the right operand
of a binary operator is the outer loop). Objects preserve insertion order.
Numbers are IEEE-754 doubles.

## Library

| Module | Responsibility |
|---|---|
| `Jq` | Public facade: parse, evaluate, render, and the CLI contract (`processInput`) |
| `Jq.Value` | `Value`, insertion-ordered `Object`, the jq total ordering |
| `Jq.Number` | Correctly-rounded number reading, shortest round-trip printing |
| `Jq.Json.Parser` / `Jq.Json.Encoder` | JSON text to `Value` and back (compact) |
| `Jq.Syntax`, `Jq.Lexer`, `Jq.Parser` | Filter AST, tokeniser, recursive-descent parser |
| `Jq.Stream` | Lazy result streams that may end in an error |
| `Jq.Ops` | Arithmetic, comparison, indexing and slicing on values |
| `Jq.Builtins` | Builtin functions |
| `Jq.Eval` | The tree-walking evaluator |

Design notes: values are immutable and shared (never deep-copied); an object is
a `Map` from key to slot plus an `IntMap` of slots recording insertion order, so
keys are sorted structurally exactly once, lookup is logarithmic, and `+`/`*`
cost proportional to the right operand; arrays are `Data.Sequence`s, so `+` is
cheap and indexing logarithmic; sorting is a stable merge sort evaluating each
sort key once.

### Example

```haskell
import qualified Data.ByteString.Char8 as BC
import qualified Data.ByteString.Lazy.Char8 as BLC
import qualified Data.Text as T
import Jq

main :: IO ()
main = do
  let Right prog = parseFilter (T.pack ".users | map(.age) | add")
      Right doc  = parseJSON (BC.pack "{\"users\":[{\"age\":3},{\"age\":4}]}")
      (outputs, err) = results prog doc   -- all outputs, plus the error that ended evaluation (if any)
  mapM_ (BLC.putStrLn . renderValue) outputs   -- prints 7
  print err                                    -- Nothing
```

`evalTop prog doc` gives the lazy `Stream` (`Nil | Cons Value Stream | Err Text`)
if you want to consume results incrementally; `runFilter` is a one-shot
convenience that returns `Either String [Value]`.

## Layout

```
jq-hs.cabal   package manifest (library, executable, test-suite)
src/          library modules
app/Main.hs   the CLI
test/Spec.hs  hspec + QuickCheck tests
build.sh      builds and installs bin/jq-hs
run.sh        runs the CLI from any directory
```
