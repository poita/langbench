# inflate

A from-scratch DEFLATE (RFC 1951) decoder in Clojure, with no dependencies
beyond Clojure itself. It is a small library plus a command-line tool that reads
a hex-encoded raw DEFLATE stream and prints the decompressed bytes as hex, or the
word `error` if the stream is malformed.

Decoding uses canonical Huffman codes with two-level lookup tables (a 10-bit
root for literal/length codes, 8 bits for distances, 7 for the code-length
code), so each symbol costs one or two table lookups and a block's tables are
built in O(symbols + 2^root). It enforces the strict validity rules zlib does:
complete code-length sets (with the single-code and empty-distance exceptions),
distance checks across blocks, truncation, and trailing bytes.

## Requirements

Java 27 and the Clojure CLI (`clojure`) with Clojure 1.12.6.

## Build

```sh
./build.sh      # AOT-compiles the CLI into classes/
```

## Command line

```sh
echo 4b4c4a862000 | ./run.sh
# 616263616263616263
echo 030200 | ./run.sh
# error
```

Input: one line of lowercase hex (two digits per byte; may be empty).
Output: one line of lowercase hex, or `error`. The exit status is 0 in both
cases. All of stdin is read before decoding.

## Library

```clojure
(require '[inflate.core :as inflate])

(inflate/inflate-hex "4b4c4a862000")      ;=> "616263616263616263"

;; bytes in, bytes out
(inflate/inflate (byte-array [0x01 0x01 0x00 0xfe 0xff 0x41]))   ;=> #bytes[41]

;; malformed streams throw ex-info with {:type :inflate/malformed}
(try (inflate/inflate-hex "030200")
     (catch clojure.lang.ExceptionInfo e
       (when (inflate/malformed? e) :bad-stream)))

;; guard against decompression bombs
(inflate/inflate data {:max-output (* 16 1024 1024)})
```

Public API (`inflate.core`): `inflate`, `inflate-hex`, `malformed?`. Input is a
raw DEFLATE stream - no zlib or gzip header - and bytes after the final block
are an error.

### Modules

| namespace          | responsibility                                          |
|--------------------|---------------------------------------------------------|
| `inflate.core`     | public API                                              |
| `inflate.decoder`  | block decoding (stored, fixed, dynamic), stream driver  |
| `inflate.huffman`  | canonical code validation, table building, symbol decode|
| `inflate.bits`     | LSB-first bit reader with peek/consume semantics        |
| `inflate.output`   | growable output buffer / LZ77 history                   |
| `inflate.tables`   | RFC 1951 constant tables                                |
| `inflate.hex`      | hex <-> bytes                                           |
| `inflate.error`    | the malformed-stream error                              |
| `inflate.main`     | command-line entry point                                |

## Tests

```sh
clojure -M:test        # clojure.test + test.check, via the Cognitect test-runner
```

The tests cover hand-assembled streams (stored, fixed, dynamic blocks and every
error class), the Huffman table builder, hex conversion, the CLI contract, and
property tests that round-trip data through `java.util.zip.Deflater` (used only
as a compressor to generate input).
