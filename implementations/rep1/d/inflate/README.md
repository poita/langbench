# inflate

A DEFLATE ([RFC 1951](https://www.rfc-editor.org/rfc/rfc1951)) decoder written
in D with no dependencies beyond Phobos, packaged as a reusable library plus a
small command-line tool. It is written from scratch (no zlib / `std.zlib`).

Design: the whole input is held in memory; bits are read LSB-first through a
64-bit buffer; canonical Huffman codes are decoded through two-level lookup
tables (10-bit root for literals/lengths, 8-bit for distances) that are reused
between blocks; the output is one contiguous buffer that doubles as the
back-reference window. Malformed streams are rejected strictly (over-subscribed
or incomplete codes, bad distances, truncation, trailing bytes after the final
block, ...), following zlib's rules.

## Layout

```
dub.sdl               package manifest (configurations: cli, library, unittest)
source/inflate/       the library
    package.d         public import of everything below
    decoder.d         decompress(), tryDecompress(), Inflater
    errors.d          InflateError, InflateException
    huffman.d         canonical Huffman table construction
    bitreader.d       LSB-first bit buffer
    tables.d          constant RFC 1951 tables
    hex.d             hexDecode() / hexEncode()
app/main.d            the command-line tool
tests/                unit tests (separate from the library sources)
build.sh, run.sh      build / run wrappers
```

## Building

Requires LDC and dub.

```sh
./build.sh          # = dub build -b release --compiler=ldc2; produces bin/inflate
dub test --compiler=ldc2
```

## Command-line use

`inflate` reads one line of lowercase hex (the raw DEFLATE stream, no zlib or
gzip wrapper) on stdin and writes one line to stdout: the decompressed bytes
as hex, or the word `error` if the stream is malformed. The exit status is 0 in
both cases (2 only if the input is not valid hex).

```sh
$ echo 4b4c4a862000 | ./run.sh
616263616263616263
$ echo 030200 | ./run.sh        # copy from before the start of the output
error
```

## Library use

Add the package as a dub dependency (`dependency "inflate" path="../inflate"`,
configuration `library`) and:

```d
import std.stdio;
import inflate;

void main()
{
    ubyte[] compressed = hexDecode("4b4c4a862000");

    // Throwing API:
    try
        writeln(cast(string) decompress(compressed));      // abcabcabc
    catch (InflateException e)
        writeln("bad stream: ", e.msg, " (", e.error, ")");

    // Non-throwing API:
    ubyte[] output;
    InflateError err;
    if (!tryDecompress(compressed, output, err))
        writeln("malformed: ", describe(err));

    // Reuse table storage across many streams:
    auto inflater = Inflater(0);
    auto a = inflater.run(compressed);
}
```

`InflateError` enumerates every way a stream can be malformed; the decoder
stops at the first one. A valid stream must end exactly at its final block (the
unused bits of the last byte are ignored, but any further whole byte is an
error).
