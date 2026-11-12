# bigint

Signed arbitrary-precision integer arithmetic in Rust, written from scratch
with only the standard library. It evaluates `+ - * / % ^` and three-way
comparison on decimal integers with tens of thousands of digits.

* Numbers are a sign plus a magnitude in base 10⁹ (so decimal parsing and
  printing are linear).
* Addition, subtraction, comparison: O(n + m).
* Multiplication: schoolbook, O(n·m).
* Division/remainder: Knuth's Algorithm D, quotient and remainder together,
  O((n − m + 1)·m); truncating toward zero, remainder takes the sign of the
  dividend (C semantics).
* Exponentiation: binary exponentiation.

## Layout

| Path            | Contents                                                  |
|-----------------|-----------------------------------------------------------|
| `src/natural.rs`| `Natural`: unsigned magnitude arithmetic                  |
| `src/int.rs`    | `BigInt`: signed integer, `div_rem`, `pow`, operators     |
| `src/query.rs`  | Parsing/evaluation of the `<a> <op> <b>` line format      |
| `src/error.rs`  | `ParseError`, `ArithmeticError`                           |
| `src/main.rs`   | Thin CLI over `query::run`                                |
| `tests/`        | Integration tests (CLI and property-style library tests)  |

## Build

```sh
./build.sh            # or: cargo build --release
cargo test            # unit, integration and doc tests
```

## CLI

`bigint` reads queries from standard input, one per line, and prints one result
line per query.

```
<a> <op> <b>        op is one of  +  -  *  /  %  ^  cmp
```

Operands match `-?[0-9]+` (leading zeros and `-0` allowed). Results are in
canonical decimal form (never `-0`). `cmp` prints `-1`, `0` or `1`. Division
or remainder by zero and a negative exponent print `error`.

```sh
$ printf '12 + 30\n-7 / 2\n-7 %% 2\n2 ^ 10\n1 / 0\n007 cmp 7\n' | ./run.sh
42
-3
-1
1024
error
0
```

## Library

```rust
use bigint::BigInt;

let a: BigInt = "-123456789012345678901234567890".parse().unwrap();
let b: BigInt = "987654321098765432109876543210".parse().unwrap();
assert_eq!(
    (&a * &b).to_string(),
    "-121932631137021795226185032733622923332237463801111263526900"
);

let (q, r) = BigInt::from(-7).div_rem(&BigInt::from(2)).unwrap();
assert_eq!((q.to_string(), r.to_string()), ("-3".to_string(), "-1".to_string()));

let p = BigInt::from(2).pow(&BigInt::from(100)).unwrap();
assert_eq!(p.to_string(), "1267650600228229401496703205376");
```
