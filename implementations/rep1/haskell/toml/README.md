# toml-tagged

A TOML 1.0.0 parser and canonical serializer in Haskell, written from scratch
(no TOML library) on top of `base`, `bytestring`, `containers` and `text`.

* **Decoder** – a single-pass recursive-descent parser that is linear in the
  input and rejects everything TOML 1.0.0 forbids (bad UTF-8, lone CRs, control
  characters, redefined tables, out-of-range integers, impossible dates, …).
* **Encoder** – writes a *canonical* TOML document: a given tree always produces
  the same bytes, and `decode . encode` is the identity.
* **Tagged JSON** – the interchange format of the
  [toml-test](https://github.com/toml-lang/toml-test) suite, used by the
  command-line tool.

Scalars are kept as **canonical text** and are never turned into numbers or
dates and back: integers are decimal, floats are `printf("%.16e")`-style
17-significant-digit text (`inf`, `-inf`, `nan` for the specials), date-times
use a `T` separator, drop trailing fractional zeros and write a zero offset as
`Z`.  Float conversion is exact (`Rational` arithmetic, round-half-even).

## Layout

| Module | Responsibility |
| --- | --- |
| `Toml` | convenience re-export of the public API |
| `Toml.Value` | the document model (`Value`, `Table`, `ScalarType`) |
| `Toml.Decode` | TOML text → `Table` |
| `Toml.Encode` | `Table` → canonical TOML |
| `Toml.Json` | `Table` ⇄ tagged JSON |
| `Toml.Internal.*` | parser monad, table-resolution rules, numbers, floats, date-times (not a stable API) |
| `app/Main.hs` | the `toml` command-line tool |
| `test/` | hspec + QuickCheck test suite |

## Building

Requires GHC 9.14 and cabal 3.18.

```sh
./build.sh          # cabal build, then copies the executable to bin/toml
cabal test          # run the test suite
```

## Command-line use

`toml` reads standard input: a first line that is the mode, then the document.

```sh
printf 'decode\nname = "Tom"\n[db]\nports = [8001, 8002]\n' | ./run.sh
# {"db":{"ports":[{"type":"integer","value":"8001"},{"type":"integer","value":"8002"}]},"name":{"type":"string","value":"Tom"}}

printf 'decode\nname = ' | ./run.sh
# error

printf 'encode\n{"a":{"type":"integer","value":"1"}}' | ./run.sh
# a = 1
```

* `decode` prints compact, key-sorted tagged JSON, or `error` if the document
  is not valid TOML (the reason goes to stderr). Exit code 0.
* `encode` reads tagged JSON (any whitespace, any member order) and prints the
  canonical TOML.

## Library example

```haskell
{-# LANGUAGE OverloadedStrings #-}
import qualified Data.ByteString.Builder as B
import qualified Data.Map.Strict as Map
import System.IO (stdout)
import qualified Toml

main :: IO ()
main = do
  case Toml.decodeText "answer = 42\n[owner]\nname = \"Tom\"\n" of
    Left err  -> putStrLn (Toml.renderDecodeError err)
    Right doc -> do
      B.hPutBuilder stdout (Toml.renderTaggedJson doc <> B.char7 '\n')
      putStr (show (Map.lookup "answer" doc))   -- Just (VScalar TInteger "42")

  -- Build a document and serialise it.
  let doc = Map.fromList
        [ ("title", Toml.vString "example")
        , ("ports", Toml.VArray [Toml.vInteger 80, Toml.vInteger 443])
        ]
  putStr (show (Toml.encodeText doc))
  -- "ports = [80, 443]\ntitle = \"example\"\n"
```

## Notes on the format

Where TOML 1.0.0 leaves a choice the decoder follows the toml-test reference
behaviour: seconds are `00`–`59`, a leading BOM is an error, integers must fit
in 64 bits in every base, float overflow/underflow silently gives ±inf / ±0.0,
`-00:00` is `Z`, and NaN loses its sign.

## License

MIT
