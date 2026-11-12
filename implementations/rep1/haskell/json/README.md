# json-canon

A strict JSON parser and canonical serializer in Haskell, written from scratch
(no JSON library; only `base`, `bytestring` and `text`).

It reads one JSON document (RFC 8259, plus strict UTF-8 validation and a
nesting limit of 512) and prints its canonical form:

- no whitespace outside strings;
- object keys sorted by **UTF-16 code unit** order; for duplicate keys the
  last occurrence wins (every byte of the input is still validated);
- strings escape only `"`, `\`, and U+0000–U+001F (`\b \f \n \r \t`, else
  lowercase `\u00xx`); everything else, including `/`, DEL and U+2028, is raw
  UTF-8;
- numbers are echoed textually (never converted to floating point), with the
  exponent normalised (`1E+05` → `1e5`, `1e-0` → `1e0`).

Invalid input yields the single line `invalid` (exit code 0).

## Build

Requires GHC 9.14 and cabal 3.18.

```sh
./build.sh          # cabal build, then copies the binary to bin/json-canon
```

Run the test suite (hspec + QuickCheck):

```sh
cabal test --enable-tests
```

## CLI

```sh
$ echo '{ "b": [1, 2.50, 1E+3], "a": "héllo\/", "b": null }' | ./run.sh
{"a":"héllo/","b":null}
$ echo '[1, 2, ]' | ./run.sh
invalid
```

The entire stdin is the document; the output is one line ending in `\n`.

## Library

```haskell
{-# LANGUAGE OverloadedStrings #-}
import qualified Data.ByteString.Lazy.Char8 as BL
import Json.Canon

main :: IO ()
main = do
  -- One shot: bytes in, canonical bytes out.
  print (canonicalize "{\"b\":1,\"a\":[true,1E+2]}")
  -- Right "{\"a\":[true,1e2],\"b\":1}"

  -- Or parse to a tree, inspect it, then render.
  case parse "{\"x\":[1,2],\"x\":null}" of
    Left err -> putStrLn ("invalid at byte " ++ show (errorOffset err))
    Right v  -> do
      print v                      -- Object [("x",Array [...]),("x",Null)]
      BL.putStrLn (renderLazy v)   -- {"x":null}
```

### Modules

| Module | Responsibility |
| --- | --- |
| `Json.Canon` | Public facade: `parse`, `render`, `renderLazy`, `canonicalize`, `Value`, `ParseError` |
| `Json.Canon.Types` | `Value` tree and `ParseError` |
| `Json.Canon.Utf8` | Strict UTF-8 validation (`validateUtf8`) |
| `Json.Canon.Parser` | Single-pass recursive-descent parser |
| `Json.Canon.Key` | `compareKeys`: UTF-16 code unit ordering over UTF-8 text |
| `Json.Canon.Render` | Canonical serialisation into one `Builder` |

### Design

Validation, parsing and rendering are each a single forward pass. `parse`
keeps duplicates and input order in the tree; `render` stably sorts each
object's members and drops all but the last of each equal-key run, writing to
a single `Builder` so there is no per-subtree copying. Rendering is O(n) plus
O(m log m) key comparisons per object. Arrays and objects nested more than
512 deep are rejected.
