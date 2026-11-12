# bigint

A small C++17 library for signed arbitrary-precision integer arithmetic, plus a
command-line tool that evaluates one-line arithmetic queries on decimal
integers with tens of thousands of digits.

Supported: `+ - * / % ^` and three-way comparison. Division truncates toward
zero and `%` takes the sign of the dividend (C semantics). Zero is never
negative.

## Design

Numbers are a sign plus a magnitude stored as little-endian `uint32_t` limbs in
base 10^9, so decimal parsing and printing are linear. Algorithms are the
classical ones: linear add/sub/compare, schoolbook multiplication, Knuth's
Algorithm D for division (quotient and remainder together), and binary
exponentiation. Only the C++ standard library is used.

| Module | Files | Responsibility |
| --- | --- | --- |
| magnitude | `include/bigint/magnitude.hpp`, `src/magnitude.cpp` | unsigned base-10^9 arithmetic |
| BigInt | `include/bigint/bigint.hpp`, `src/bigint.cpp` | signed value type, operators, parsing |
| query | `include/bigint/query.hpp`, `src/query.cpp` | evaluating `<a> <op> <b>` lines |
| CLI | `cli/main.cpp` | stdin/stdout wrapper |

## Build

Requires CMake >= 3.20, a C++17 compiler, and GoogleTest (for the tests only).

```
./build.sh                      # Release build into ./build
./build/bigint_tests            # or: ctest --test-dir build
```

Pass `-DBIGINT_BUILD_TESTS=OFF` to CMake to build without GoogleTest.

## Command-line tool

`./run.sh` (or `build/bigint_cli`) reads queries from stdin, one per line, in
the form `<a> <op> <b>` with `op` one of `+ - * / % ^ cmp`, and prints one
result per line. Operands match `-?[0-9]+` (leading zeros and `-0` allowed).
Division or remainder by zero and negative exponents print `error`. `cmp`
prints `-1`, `0` or `1`.

```
$ printf '12 + 30\n-7 / 2\n-7 %% 2\n2 ^ 100\n1 / 0\n3 cmp -2\n' | ./run.sh
42
-3
-1
1267650600228229401496703205376
error
1
```

The exit status is 0 on success, nonzero on malformed input.

## Library example

```cpp
#include <iostream>
#include "bigint/bigint.hpp"

int main() {
    using bigint::BigInt;
    BigInt a("123456789012345678901234567890");
    BigInt b = a * a - 1;
    auto [q, r] = BigInt::divmod(b, BigInt(97));
    std::cout << b << "\n" << q << " rem " << r << "\n";
    std::cout << BigInt::pow(BigInt(-2), 101) << "\n";
}
```

Link against the `bigint::bigint` CMake target (e.g. with `add_subdirectory`).
Division by zero throws `std::domain_error`; malformed text throws
`bigint::ParseError`.
