# inflate

A from-scratch decoder for raw DEFLATE streams ([RFC 1951](https://www.rfc-editor.org/rfc/rfc1951)),
written in D using only Phobos/druntime. It contains no zlib/gzip code and does not
call any decompressor from the standard library.

The package has two parts:

* **`inflate`** – a reusable library (`source/inflate/`).
* **`inflate:cli`** – a thin command-line tool (`cli/`) that reads a hex-encoded
  DEFLATE stream on stdin and prints the hex-encoded result.

## How it works

Decoding is a single pass with a table-driven Huffman decoder. Each code
(fixed, or rebuilt from the lengths in every dynamic block) becomes a two-level
lookup table: a 10-bit root for literal/lengths and 8 bits for distances
(9/5 for the fixed codes, 7 for the code-length code), with second-level tables for longer
codes. Every symbol costs one or two lookups; building a table costs
O(symbols + 2^root). Input comes through a 64-bit bit buffer refilled eight
bytes at a time. Validation follows zlib's rules (over-subscribed/incomplete codes,
missing end-of-block code, bad distances, trailing data, ...) as listed in the problem
specification.

| Module | Responsibility |
|---|---|
| `inflate.decoder` | `decompress`, `tryDecompress`: block parsing and the symbol loop |
| `inflate.huffman` | canonical code construction, `HuffmanTable.decode` |
| `inflate.bitreader` | LSB-first `BitReader` with end-of-stream checks |
| `inflate.constants` | RFC 1951 length/distance/code-length tables |
| `inflate.error` | `InflateException` and the `InflateError` reason enum |
| `inflate.hex` | `toHex` / `fromHex` |

## Build

Requires LDC 1.41 and dub 1.40.

```sh
./build.sh          # dub build -b release --compiler=ldc2 :cli  ->  bin/inflate-cli
dub test --compiler=ldc2   # library unit tests
tests/cli_test.sh          # end-to-end CLI checks (after ./build.sh)
```

## CLI

```sh
$ echo 4b4c4a862000 | ./run.sh
616263616263616263
```

Standard input is one line of lowercase hex (two digits per byte) holding the raw
stream (no zlib/gzip wrapper); it may be empty. Standard output is one line:
the decompressed bytes as lowercase hex, or the word `error` if the stream is
malformed (truncated, bad block, bad Huffman table, distance too far, trailing bytes, ...).
The exit status is 0 in both cases; it is 2 only for unusable input (not hex) or arguments.

## Library

Add the dependency to `dub.sdl` (`dependency "inflate" path="../inflate"`) and:

```d
import inflate;
import std.stdio;

void main()
{
    ubyte[] compressed = fromHex("4b4c4a862000");

    // Throws InflateException on malformed input; e.kind says why.
    try
        writeln(cast(string) decompress(compressed)); // abcabcabc
    catch (InflateException e)
        writeln("bad stream: ", e.kind, " (", e.msg, ")");

    // Non-throwing variant, with an optional output size cap:
    ubyte[] output;
    if (tryDecompress(compressed, output, 1 << 20))
        writeln(toHex(output));
}
```

## Layout

```
dub.sdl             library package "inflate" (sub-package :cli)
source/inflate/     library modules (with unittest blocks)
cli/                command-line tool
tests/cli_test.sh   end-to-end CLI tests
build.sh run.sh     build and run helpers
```
