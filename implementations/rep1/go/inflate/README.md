# inflate

A from-scratch DEFLATE (RFC 1951) decoder in Go, with no dependencies beyond
the standard library: a reusable library plus a small command-line tool.

The decoder is strict (it matches zlib's validity rules for Huffman code
sets, rejects truncated input, bad distances and trailing bytes) and fast:
Huffman decoding is table driven, with a 10-bit root table for
literal/lengths, 8 bits for distances, and second-level tables for longer
codes. Table construction costs O(symbols + 2^root) per block.

## Layout

| Path                | Responsibility                                        |
|---------------------|-------------------------------------------------------|
| `bitreader.go`      | LSB-first bit reader (peeks past the end, never consumes missing bits) |
| `huffman.go`        | canonical code construction and two-level lookup tables |
| `tables.go`         | length/distance base and extra-bit constants           |
| `decoder.go`        | block parsing (stored, fixed, dynamic) and the decode loop |
| `errors.go`         | sentinel errors                                       |
| `cmd/inflate`       | the command-line tool                                 |

## Build

Requires Go 1.27.1 or later.

```sh
./build.sh          # produces bin/inflate
go test ./...       # unit, round-trip and conformance tests
```

## Command-line use

`inflate` reads one line of lowercase hex (a raw DEFLATE stream, no zlib or
gzip wrapper) on stdin and prints one line on stdout: the decompressed bytes as
hex, or `error` if the stream is malformed. The exit status is 0 in both cases.

```console
$ echo 4b4c4a862000 | ./run.sh
616263616263616263
$ echo 030200 | ./run.sh
error
```

## Library use

```go
package main

import (
	"fmt"
	"log"

	"example.com/inflate"
)

func main() {
	compressed := []byte{0x4b, 0x4c, 0x4a, 0x86, 0x20, 0x00}
	out, err := inflate.Decode(compressed)
	if err != nil {
		log.Fatal(err) // e.g. errors.Is(err, inflate.ErrDistance)
	}
	fmt.Printf("%s\n", out) // abcabcabc
}
```

Use a `inflate.Decoder` to reuse table buffers across many streams, and
`Decoder.Append` to append output to an existing slice.

## Tests

The tests use the standard `testing` package: unit tests for the bit reader
and Huffman tables, error-path tests, round trips against streams produced by
`compress/flate`'s *compressor* at every level, a truncation sweep, a fuzz
target (`go test -fuzz FuzzDecode .`), and — when the repository's
`problems/inflate/tests` directory is present — the shared conformance cases.
