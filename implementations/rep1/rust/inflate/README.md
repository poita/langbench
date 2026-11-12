# inflate

A from-scratch DEFLATE ([RFC 1951](https://www.rfc-editor.org/rfc/rfc1951))
decoder in Rust, using only the standard library. It ships as a reusable
library plus a small command-line tool that reads a hex-encoded raw DEFLATE
stream and prints the decompressed bytes as hex.

Decoding is a single pass with a table-driven Huffman decoder: each canonical
code is compiled into a two-level lookup table (10-bit root for literal/length
codes, 8-bit for distances, 7-bit for the code-length code), so every symbol
costs one or two lookups. Per-block table construction is
O(symbols + 2^root bits). Malformed streams are rejected strictly, matching
zlib's validity rules (over-subscribed/incomplete codes, bad distances,
truncation, trailing bytes, …).

## Build

```sh
./build.sh            # or: cargo build --release
cargo test            # unit, integration, CLI and doc tests
```

Requires Rust 1.96 or newer. The binary is `target/release/inflate`.

## Command-line usage

Standard input is one line of lowercase hex (two digits per byte) holding a raw
DEFLATE stream — no zlib/gzip wrapper. The tool prints one line: the
decompressed bytes as hex, or the word `error` if the stream is malformed. The
exit status is 0 in both cases.

```console
$ echo 4b4c4a862000 | ./run.sh
616263616263616263
$ echo 030200 | ./run.sh
error
```

## Library usage

```rust
use inflate::{hex, inflate, Error};

fn main() {
    // Literals "abc", then a copy of 6 bytes at distance 3.
    let compressed = hex::decode(b"4b4c4a862000").unwrap();
    assert_eq!(inflate(&compressed).unwrap(), b"abcabcabc");

    // Errors are values.
    let bad = hex::decode(b"030200").unwrap();
    assert_eq!(inflate(&bad), Err(Error::DistanceTooFar));
}
```

## Layout

| Module | Responsibility |
|--------|----------------|
| `inflate::decoder` | Block parsing (stored, fixed, dynamic) and the `inflate` function |
| `inflate::huffman` | Canonical Huffman code construction and two-level table decoding |
| `inflate::bitreader` | LSB-first bit reader (peeking past the end is allowed, consuming is not) |
| `inflate::tables` | RFC 1951 constants (length/distance bases, extra bits, fixed code lengths) |
| `inflate::hex` | Hex encoding/decoding used by the CLI |
| `inflate::error` | The `Error` type |
| `src/main.rs` | The command-line tool |

## License

MIT
