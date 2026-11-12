# bigint

Arbitrary-precision signed integer arithmetic in Clojure, written from scratch
(no `BigInteger`, `BigInt` or other unbounded-integer type is used by the
library), plus a small command-line calculator on top of it.

Numbers are a sign and a magnitude held as base-10^9 limbs in primitive
`long[]` arrays, so decimal parsing and printing are linear. Algorithms are the
classical ones:

| operation         | algorithm                                              |
|-------------------|--------------------------------------------------------|
| parse / print     | linear in the digit count                              |
| compare, `+`, `-` | linear                                                 |
| `*`               | schoolbook long multiplication, O(n·m)                 |
| `/`, `%`          | Knuth's Algorithm D (quotient and remainder together)  |
| `^`               | binary exponentiation (repeated squaring)              |

## Layout

```
deps.edn                    project manifest (clojure CLI)
build.sh / run.sh           build and run the CLI
src/bigint/magnitude.clj    unsigned limb-array arithmetic (internal)
src/bigint/decimal.clj      decimal string <-> magnitude
src/bigint/core.clj         public API: signed BigInt type and operations
src/bigint/cli.clj          stdin/stdout query processor
test/bigint/*_test.clj      clojure.test + test.check tests
```

## Build

Requires Clojure 1.12 (the `clojure` CLI) and a JDK (developed on Java 27).

```
./build.sh
```

AOT-compiles the CLI into `target/classes` and records the classpath in
`target/classpath`.

## Command-line use

```
./run.sh < queries.txt
```

Each input line is `<a> <op> <b>` with `op` one of `+ - * / % ^ cmp`; operands
match `-?[0-9]+` (leading zeros and `-0` are accepted). One result line is
printed per query, in canonical decimal form (no leading zeros, never `-0`).
`/` and `%` truncate toward zero (C semantics; `%` takes the sign of `a`);
`cmp` prints `-1`, `0` or `1`. Division or remainder by zero, and a negative
exponent, print `error`.

```
$ printf '12 + 30\n-7 / 2\n-7 %% 2\n2 ^ 100\n007 cmp 7\n1 / 0\n' | ./run.sh
42
-3
-1
1267650600228229401496703205376
0
error
```

Without building, `clojure -M:run < queries.txt` works too.

## Library use

```clojure
(require '[bigint.core :as bi])

(def a (bi/parse "-123456789012345678901234567890"))
(def b (bi/parse "987654321098765432109876543210"))

(bi/->string (bi/mul a b))
;=> "-121932631137021795226185032733622923332237463801111263526900"

(let [[q r] (bi/quot-rem (bi/parse "-7") (bi/of-long 2))]
  [(bi/->string q) (bi/->string r)])
;=> ["-3" "-1"]

(bi/->string (bi/pow (bi/of-long 2) 100))   ;=> "1267650600228229401496703205376"
(bi/compare (bi/parse "007") (bi/parse "7")) ;=> 0
```

Public functions in `bigint.core`: `parse`, `of-long`, `->string`, `->long`,
`add`, `sub`, `mul`, `quot-rem`, `quot`, `rem`, `pow`, `negate`, `abs`,
`compare`, `signum`, `zero?`, `neg?`, `pos?`, plus the constants `zero` and
`one`. `BigInt` values implement `equals`/`hashCode`/`Comparable`, and zero is
canonical, so `-0` cannot be represented. Division by zero throws
`ArithmeticException`; a negative exponent throws `IllegalArgumentException`.

## Tests

```
clojure -M:test
```

Runs the Cognitect test-runner over `test/`: unit tests, CLI tests built from
the spec examples, and generative `test.check` properties checked against
`java.math.BigInteger` (used **only** as a test oracle, never by the library).
