# bigint

Signed arbitrary-precision integer arithmetic in pure Clojure, with a small
command-line calculator on top. It handles addition, subtraction,
multiplication, truncating division and remainder, exponentiation and
comparison of decimal integers with tens of thousands of digits.

The arithmetic is written from scratch: no `BigInteger`, `BigInt` or other
unbounded-integer type or routine is used. Only primitive `long` values and
`long[]` arrays appear in the implementation (the tests also use plain longs as
an oracle for small values).

## Design

- **Representation.** A number is a sign and a magnitude; the magnitude is a
  `long[]` of base-10^9 limbs, least significant first. A decimal base makes
  parsing and printing linear in the number of digits.
- **Algorithms.** Linear addition/subtraction/comparison; schoolbook O(n·m)
  multiplication; Knuth's Algorithm D for division (quotient and remainder
  together, one constant-time quotient-digit estimate per limb); binary
  exponentiation (left to right) for powers.
- **Canonical values.** Zero has no sign, so `-0` never exists; inputs with
  leading zeros or `-0` are normalised on parsing.

### Layout

| Namespace        | Responsibility                                              |
|------------------|-------------------------------------------------------------|
| `bigint.mag`     | Unsigned magnitude arithmetic on `long[]` (internal engine) |
| `bigint.core`    | Public API: the signed `Int` type and its operations        |
| `bigint.query`   | Evaluates one `<a> <op> <b>` query line                     |
| `bigint.cli`     | stdin/stdout driver (`-main`)                               |

## Requirements

Java and the Clojure CLI (`clojure`); developed with Clojure 1.12.6 on Java 27.

## Build

```sh
./build.sh      # AOT-compiles the CLI into ./classes (faster start-up)
```

`./run.sh` also works without building; it just starts a little slower.

## Command-line use

`run.sh` reads queries from standard input, one per line, and prints one result
per line.

```sh
$ printf '12 + 30\n-7 / 2\n-7 %% 2\n2 ^ 100\n1 / 0\n007 cmp 7\n' | ./run.sh
42
-3
-1
1267650600228229401496703205376
error
0
```

Each line is `<a> <op> <b>` with exactly one space between tokens, where `op` is
`+ - * / % ^ cmp` and operands match `-?[0-9]+` (leading zeros and `-0` are
fine). Results are canonical decimal (never `-0`); `cmp` prints `-1`, `0` or
`1`; division or remainder by zero and negative exponents print `error` and
processing continues. Division truncates toward zero and the remainder takes
the sign of the dividend. `0 ^ 0` is `1`.

## Library use

Add the project as a `deps.edn` dependency (e.g. as a `:local/root`) and:

```clojure
(require '[bigint.core :as bi])

(def a (bi/parse "-123456789012345678901234567890"))
(def b (bi/parse "987654321098765432109876543210"))

(bi/->string (bi/mul a b))
;; => "-121932631137021795226185032733622923332237463801111263526900"

(let [[q r] (bi/quot-rem a (bi/parse "1000000007"))]
  [(str q) (str r)])               ; truncating division, C semantics

(bi/->string (bi/pow (bi/parse "2") (bi/parse "1000")))   ; 302 digits
(bi/cmp a b)                                              ;=> -1
(= (bi/parse "-0") (bi/parse "0"))                        ;=> true
(sort [b a bi/zero])                                      ; Int is Comparable
```

Public functions in `bigint.core`: `parse`, `from-long`, `->string`, `zero`,
`one`, `int-value?`, `signum`, `zero?`, `neg?`, `pos?`, `negate`, `abs`, `add`,
`sub`, `mul`, `quot-rem`, `quot`, `rem`, `pow`, `cmp`. `Int` values implement
`equals`/`hashCode`/`Comparable` numerically and `toString` gives the canonical
decimal form.

Errors are `ex-info` exceptions with a `:type` in `ex-data`:
`:bigint.core/division-by-zero`, `:bigint.core/negative-exponent`,
`:bigint.core/parse-error`.

## Tests

```sh
clojure -M:test     # Cognitect test-runner; unit tests + test.check properties
```

The end-to-end suite lives in the parent repository:

```sh
python3 run_tests.py bigint -- bigint/run.sh
```
