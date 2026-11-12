# inflate

A from-scratch decoder for raw DEFLATE streams ([RFC 1951]) in Haskell. It uses
no zlib/gzip/DEFLATE library: only `base`, `array` and `bytestring`.

Huffman codes are decoded with **two-level lookup tables** (a 10-bit root for
literal/length codes, 8 bits for distance codes, plus second-level tables for
longer codes), so each symbol costs one or two array reads. Building the tables
for a block takes O(symbols + 2^root).

The decoder is strict, in the way zlib is: it rejects over-subscribed or
incomplete Huffman codes (except a single 1-bit code or an empty distance
code), back-references before the start of the output, truncated streams, and
any whole bytes after the final block.

## Layout

| Path | Purpose |
|------|---------|
| `src/Codec/Compression/Inflate.hs` | public API: `inflate`, `InflateError` |
| `src/Codec/Compression/Inflate/Hex.hs` | hex encoding/decoding helpers |
| `src/Codec/Compression/Inflate/Huffman.hs` | canonical code → two-level lookup table |
| `src/Codec/Compression/Inflate/Tables.hs` | RFC 1951 constant tables |
| `src/Codec/Compression/Inflate/Types.hs` | error type |
| `src/Codec/Compression/Inflate/Decoder.hs` | block decoder (internal) |
| `app/Main.hs` | command-line tool |
| `test/` | hspec + QuickCheck test suite |

## Build

Requires GHC 9.14 and cabal 3.18 (any GHC with `base >= 4.20` should work).

```sh
cabal build          # library and CLI
./build.sh           # same, quietly, from any directory
cabal test           # run the test suite
```

## Command-line use

`inflate` (or `./run.sh`) reads one line of lowercase hex on stdin — a raw
DEFLATE stream with no zlib/gzip wrapper — and prints one line: the
decompressed bytes as lowercase hex, or the word `error` if the stream is
malformed. The exit status is 0 in both cases.

```console
$ echo 4b4c4a862000 | ./run.sh
616263616263616263
$ echo 010100feff41 | ./run.sh
41
$ echo 030200 | ./run.sh      # distance reaches before the start of the output
error
```

## Library use

```haskell
import qualified Data.ByteString as B
import Codec.Compression.Inflate (inflate, InflateError (..), describeError)

main :: IO ()
main = do
  -- a fixed-Huffman block: "abc" followed by a copy of length 6 at distance 3
  let stream = B.pack [0x4b, 0x4c, 0x4a, 0x86, 0x20, 0x00]
  case inflate stream of
    Right bytes -> print bytes                 -- "abcabcabc"
    Left err    -> putStrLn (describeError err)
```

`inflate :: ByteString -> Either InflateError ByteString` takes a complete raw
DEFLATE stream and returns either the decompressed data or the first error
found. `Codec.Compression.Inflate.Hex` provides `encodeHex`/`decodeHex`.

[RFC 1951]: https://www.rfc-editor.org/rfc/rfc1951
