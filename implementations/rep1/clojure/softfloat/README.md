# softfloat

IEEE-754 binary32 (single precision) addition, subtraction, multiplication,
division and square root in pure Clojure, using only bounded-width (64-bit)
integer arithmetic. Round-to-nearest-even, full gradual underflow (denormals),
infinities, signed zeros and NaNs (all NaN results are the canonical quiet NaN
`0x7fc00000`). Values are exchanged as raw 32-bit bit patterns.

No host floating point, big integers, or float libraries are used to compute
results. Each operation yields a truncated integer result plus a sticky bit; one
shared round-and-pack step rounds once onto the binary32 grid. Division is one
integer divide with remainder; square root is the restoring digit-by-digit
method.

## Layout

| Namespace | Responsibility |
|---|---|
| `softfloat.core`   | public API: `add sub mul div sqrt eval-op` |
| `softfloat.fields` | bit fields, classification, unpacking |
| `softfloat.round`  | the single round-and-pack step |
| `softfloat.add` / `mul` / `div` / `sqrt` | the operations |
| `softfloat.hex`    | 8-digit hex parsing/formatting |
| `softfloat.cli`    | stdin/stdout command-line tool |

## Build

Requires Java and the Clojure CLI (`clojure`).

    ./build.sh

AOT-compiles the CLI into `classes/`.

## Command line

`run.sh` reads operations from stdin, one per line, and prints one 8-digit hex
result per line:

    $ printf 'add 3f800000 3f800000\nsqrt 40000000\ndiv 3f800000 40400000\n' | ./run.sh
    40000000
    3fb504f3
    3eaaaaab

Input lines are `add|sub|mul|div <a> <b>` or `sqrt <a>`, operands being
8 lowercase hex digits (the bit pattern). See the problem's `SPEC.md` for the
full contract.

## Library

```clojure
(require '[softfloat.core :as sf])

(sf/add 0x3f800000 0x3f800000)   ;=> 0x40000000  (1 + 1 = 2)
(sf/div 0x3f800000 0x40400000)   ;=> 0x3eaaaaab  (1 / 3)
(sf/sqrt 0x40000000)             ;=> 0x3fb504f3  (sqrt 2)
(sf/mul 0x7f800000 0)            ;=> 0x7fc00000  (inf * 0 = NaN)
(sf/eval-op "sub" [0x3f800000 0x3f800000]) ;=> 0
```

Use the library from another project via `deps.edn`
(`{:local/root "path/to/softfloat"}`).

## Tests

    clojure -X:test

Unit tests, tests for each internal module, and property tests
(`test.check`) comparing against the JVM's hardware float arithmetic. The
hardware oracle lives only in `test/softfloat/oracle.clj`; the library itself
never uses it.
