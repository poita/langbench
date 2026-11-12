# bigint

Signed arbitrary-precision integer arithmetic in C++20, with no dependencies
beyond the standard library. Handles decimal numbers with tens of thousands of
digits: addition, subtraction, multiplication, truncating division, remainder,
exponentiation and comparison.

Numbers are a sign plus a magnitude stored as little-endian base-10^9 limbs, so
parsing and printing are linear. Algorithms are the classical ones:
schoolbook multiplication, Knuth's Algorithm D for division (quotient and
remainder together), and binary exponentiation.

## Layout

| Path | Contents |
|------|----------|
| `include/bigint/magnitude.hpp`, `src/magnitude.cpp` | unsigned limb-vector arithmetic |
| `include/bigint/bigint.hpp`, `src/bigint.cpp` | signed `bigint::BigInt` class |
| `include/bigint/query.hpp`, `src/query.cpp` | text query evaluation (`a op b`) |
| `cli/main.cpp` | command-line tool |
| `tests/` | GoogleTest unit tests |

## Build

Requires CMake >= 3.20, a C++20 compiler, and GoogleTest (for tests only).

```sh
./build.sh                     # Release build into build/
# or by hand:
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release && cmake --build build
ctest --test-dir build         # run the unit tests
cmake -S . -B build -DBIGINT_BUILD_TESTS=OFF   # skip tests / GoogleTest
```

## Command-line use

`./run.sh` (or `build/bigint`) reads queries from stdin, one per line, and
writes one result line per query to stdout.

```
<a> <op> <b>      op is one of  +  -  *  /  %  ^  cmp
```

Operands match `-?[0-9]+` (leading zeros and `-0` are accepted). Results are
canonical (no leading zeros, never `-0`). `/` truncates toward zero, `%` takes
the sign of the dividend, `cmp` prints `-1`, `0` or `1`. Division or remainder
by zero and negative exponents print `error`. `0 ^ 0` is `1`.

```
$ printf '12 + 30\n-7 / 2\n-7 %% 2\n1 / 0\n2 ^ 100\n' | ./run.sh
42
-3
-1
error
1267650600228229401496703205376
```

## Library use

```cpp
#include <iostream>
#include "bigint/bigint.hpp"

int main() {
  using bigint::BigInt;
  BigInt a("-123456789012345678901234567890");
  BigInt b("987654321098765432109876543210");

  std::cout << a * b << '\n';                       // product
  auto [q, r] = BigInt::divmod(b, BigInt(12345));   // quotient and remainder at once
  std::cout << q << " rem " << r << '\n';
  std::cout << BigInt::pow(BigInt(2), 200) << '\n'; // 2^200
  std::cout << (a < b) << '\n';                     // full set of comparisons
  try { a / BigInt(0); } catch (const bigint::ArithmeticError& e) { /* division by zero */ }
}
```

Link against the `bigint::bigint` CMake target (`target_link_libraries(app PRIVATE bigint::bigint)`);
`BigInt(std::string_view)` throws `std::invalid_argument` on malformed text, and
division, remainder and negative exponents throw `bigint::ArithmeticError`.
