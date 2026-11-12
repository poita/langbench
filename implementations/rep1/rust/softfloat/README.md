# softfloat

IEEE-754 binary32 (single-precision) **add, subtract, multiply, divide and
square root** in pure integer arithmetic. Operands and results are raw 32-bit
patterns; rounding is round-to-nearest-even with full gradual underflow
(denormals). NaN results are always the canonical quiet NaN `7fc00000`;
exception flags are not modelled.

The library uses only the Rust standard library and never touches host
floating point; every intermediate fits in a `u64`.

## How it works

Each operation classifies its operands from the bit fields (NaN, infinity, zero
are resolved directly), unpacks finite values into a normalised 24-bit
significand and exponent, and computes a truncated integer result plus a
sticky bit. A single shared step, `round::round_pack`, rounds once onto the
binary32 grid (normal or denormal) and packs the result.

* **add/sub** – align the smaller operand with 29 guard bits, folding shifted-out
  bits into a sticky bit, then add or subtract. `sub a b` is `add a (-b)`.
* **mul** – the exact 48-bit product of the two significands.
* **div** – one integer division of the shifted dividend; the sticky bit is a
  nonzero remainder.
* **sqrt** – restoring digit-by-digit integer square root (about 32 steps).

## Build

```sh
cargo build --release     # or ./build.sh
```

## Command-line use

The tool reads one operation per line on stdin and prints one 8-hex-digit
result per line on stdout (`./run.sh` runs the release binary):

```sh
$ printf 'add 3f800000 3f800000\ndiv 3f800000 40400000\nsqrt 40000000\n' | ./run.sh
40000000
3eaaaaab
3fb504f3
```

Lines are `<op> <a> <b>` for `add sub mul div`, or `sqrt <a>`, with operands as
exactly 8 lowercase hex digits. Malformed input prints a diagnostic on stderr
and exits nonzero.

## Library use

```rust
use softfloat::{add, div, mul, sqrt, sub, QNAN};

assert_eq!(add(0x3f80_0000, 0x3f80_0000), 0x4000_0000); // 1 + 1 = 2
assert_eq!(div(0x3f80_0000, 0x4040_0000), 0x3eaa_aaab); // 1 / 3
assert_eq!(sqrt(0x4000_0000), 0x3fb5_04f3);             // sqrt(2)
assert_eq!(mul(0x7f80_0000, 0), QNAN);                  // inf * 0 is invalid
assert_eq!(sub(0x8000_0000, 0), 0x8000_0000);           // -0 - +0 = -0
```

Modules: `format` (field layout, classification, unpacking), `round` (shared
round-and-pack), `addsub`, `mul`, `div`, `sqrt`, and `line` (the text protocol
used by the CLI).

## Tests

```sh
cargo test --release
```

Unit tests live next to each module. `tests/against_hardware.rs` compares
millions of random and edge-biased inputs with the host's `f32` arithmetic
(used only as a test oracle), `tests/cli.rs` exercises the binary end to end.
