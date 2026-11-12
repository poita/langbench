# bigint

Signed arbitrary-precision integer arithmetic in pure Rust (standard library
only), with a small line-oriented command-line calculator on top.

Numbers are a sign plus a magnitude stored as little-endian base 10⁹ limbs, so
decimal parsing and printing are linear. Algorithms:

| operation       | algorithm                                        |
|-----------------|--------------------------------------------------|
| `+`, `-`, cmp   | linear limb-wise passes                          |
| `*`             | schoolbook long multiplication, O(n·m)           |
| `/`, `%`        | Knuth's Algorithm D, O((n − m + 1)·m), truncating|
| `^`             | binary exponentiation                            |

Division and remainder follow C semantics (quotient truncated toward zero,
remainder has the sign of the dividend). Zero is always printed as `0`.

## Build

```sh
./build.sh            # or: cargo build --release
cargo test            # unit, property and CLI tests
```

## CLI

`bigint` reads queries from standard input, one per line, and prints one
result per line:

```
<a> <op> <b>        op ∈ + - * / % ^ cmp
```

Operands match `-?[0-9]+` (leading zeros and `-0` are accepted). `cmp` prints
`-1`, `0` or `1`. Division or remainder by zero, and a negative exponent, print
`error`. `0 ^ 0` is `1`.

```sh
$ printf '12 + 30\n-7 / 2\n-7 %% 2\n2 ^ 100\n1 / 0\n' | ./run.sh
42
-3
-1
1267650600228229401496703205376
error
```

## Library

```rust
use bigint::BigInt;

let a: BigInt = "-123456789012345678901234567890".parse().unwrap();
let b: BigInt = "987654321098765432109876543210".parse().unwrap();

println!("{}", &a * &b);          // -121932631137021795226185032733622923332237463801111263526900
let (q, r) = a.div_rem(&b).unwrap(); // truncating division
assert_eq!(&(&q * &b) + &r, a);
println!("{}", BigInt::from(2).pow(100));
```

Modules: `natural` (unsigned magnitudes), `int` (signed `BigInt` with operator
impls), `query` (the CLI's query language), `error`.
