# inflate

A pure-Python decoder for raw DEFLATE streams ([RFC 1951]), using only the
standard library. It decodes with table-driven Huffman lookups (a 10-bit root
table for literal/length codes, 8-bit for distances, second-level tables for
longer codes), so each symbol costs one or two list lookups. It is strict:
malformed, truncated, or trailing-garbage streams are rejected, following
zlib's rules for code validity.

It contains no use of `zlib`, `gzip` or any other decompressor.

## Layout

```
src/inflate/
    __init__.py    public API: inflate(), InflateError and subclasses
    decoder.py     block parsing, dynamic headers, the symbol decode loop
    huffman.py     canonical-code table construction
    bitreader.py   LSB-first bit reader
    tables.py      RFC 1951 constants
    errors.py      exception types
    cli.py         hex-in / hex-out command line tool
tests/             pytest suite
build.sh, run.sh   build / run scripts
```

## Build

Nothing needs compiling; `./build.sh` byte-compiles the package and checks
that it is syntactically valid. Requires Python 3.14. Run the tests with
`python3 -m pytest` (pytest is the only non-standard dependency, and only for
tests; `pyproject.toml` puts `src/` on the path).

## Command line

`run.sh` reads one line of lowercase hex (a raw DEFLATE stream, no zlib or
gzip wrapper) on stdin and prints one line: the decompressed bytes as hex, or
`error` if the stream is malformed. The exit status is 0 in both cases.

```
$ echo 4b4c4a862000 | ./run.sh
616263616263616263
$ echo 030200 | ./run.sh
error
```

It can also be run directly as `PYTHONPATH=src python3 -m inflate`.

## Library

```python
from inflate import inflate, InflateError

data = inflate(bytes.fromhex("4b4c4a862000"))
assert data == b"abcabcabc"

try:
    inflate(b"\x07")          # reserved block type 3
except InflateError as exc:
    print("malformed:", exc)
```

`inflate(data)` accepts `bytes`, `bytearray` or `memoryview` and returns
`bytes`. It raises `InflateError` for any malformation;
`TruncatedStreamError` (stream ends early) and `TrailingDataError` (whole
bytes after the final block) are subclasses.

[RFC 1951]: https://www.rfc-editor.org/rfc/rfc1951
