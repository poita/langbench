# inflate

A small, strict DEFLATE (RFC 1951) decoder in Go, written from scratch using
only the standard library (no `compress/flate`, `compress/zlib`, ...), plus a
command-line tool that decodes hex-encoded streams.

* Table-driven: canonical Huffman codes become two-level lookup tables
  (10-bit root for literal/length codes, 8-bit for distances), bits come from
  a 64-bit LSB-first buffer, and the output buffer doubles as the
  back-reference window.
* Strict: rejects everything zlib rejects (bad block types, stored-length
  mismatches, over-subscribed or incomplete codes, missing end-of-block code,
  bad code-length repeats, reserved symbols, distances before the start of the
  output, truncation) and also whole bytes left over after the final block.

## Layout

| File                     | Responsibility                                        |
|--------------------------|-------------------------------------------------------|
| `doc.go`, `decoder.go`   | public API (`Decode`, `Decoder`), block decoding loop |
| `bitreader.go`           | 64-bit bit buffer, end-of-data tracking               |
| `huffman.go`             | code validation and two-level table construction      |
| `tables.go`              | RFC 1951 constant tables                              |
| `errors.go`              | exported error values                                 |
| `cmd/inflate/`           | the command-line tool                                 |

## Build

Requires Go 1.27 or newer.

```sh
./build.sh          # builds bin/inflate (same as: go build -o bin/inflate ./cmd/inflate)
go test ./...       # unit tests
```

## Command-line use

`inflate` reads one line of lowercase hex (the raw DEFLATE stream, no zlib or
gzip wrapper) on stdin and prints one line on stdout: the decompressed bytes
as hex, or the word `error` if the stream is malformed. The exit status is 0
in both cases.

```console
$ echo 4b4c4a862000 | ./run.sh
616263616263616263
$ echo 030200 | ./run.sh       # copy from before the start of the output
error
```

`run.sh` simply runs `bin/inflate`; both scripts work from any directory.

## Library use

```go
package main

import (
	"errors"
	"fmt"

	"example.com/inflate"
)

func main() {
	// Fixed-Huffman block: "abc" followed by a copy of 6 bytes at distance 3.
	stream := []byte{0x4b, 0x4c, 0x4a, 0x86, 0x20, 0x00}

	out, err := inflate.Decode(stream)
	if err != nil {
		if errors.Is(err, inflate.ErrTruncated) {
			fmt.Println("stream is incomplete")
		}
		return
	}
	fmt.Printf("%s\n", out) // abcabcabc
}
```

To decode many streams, keep a `*inflate.Decoder` (`inflate.NewDecoder()`) and
call its `Decode` method: it reuses its Huffman table buffers. A `Decoder` is
not safe for concurrent use; the package-level `Decode` is.

Errors are sentinel values (`ErrTruncated`, `ErrBlockType`, `ErrStoredLength`,
`ErrTooManyCodes`, `ErrOverSubscribed`, `ErrIncompleteCode`,
`ErrMissingEndOfBlock`, `ErrBadRepeat`, `ErrInvalidCode`, `ErrInvalidSymbol`,
`ErrDistance`, `ErrTrailingData`); match them with `errors.Is`.
