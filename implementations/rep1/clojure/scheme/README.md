# scheme

An interpreter for a small Scheme subset, written in Clojure. It is both a
reusable library (`scheme.core`) and a command-line tool that reads a program
on stdin and prints its output on stdout. The language is defined in
`problems/scheme/SPEC.md`: integers of arbitrary precision, closures, proper
tail calls, `let`/`let*`/`letrec`/named `let`, `cond`, `and`/`or`, and a small
set of primitives. Runtime errors are reported as `error: <category>`.

The design follows `problems/scheme/APPROACH.md`: a pre-analysing interpreter
with a trampoline, name-based variable lookup through frame chains, and
hand-written bignum arithmetic (schoolbook multiplication, Knuth's Algorithm D
for division). No `BigInteger`/`BigInt`/`BigDecimal` is used in the library.

## Requirements

Clojure 1.12.6 (CLI tools) on a JDK (developed with Java 27). Dependencies are
resolved from `deps.edn`; the library itself uses only Clojure and the JDK.

## Build

```
./build.sh
```

AOT-compiles the interpreter into `classes/` (which is on the classpath in
`deps.edn`), which makes start-up faster. The scripts work from any directory.

## Command-line use

```
echo '(display (* 6 7)) (newline) (+ 1 2)' | ./run.sh
42
3
```

`run.sh` reads the whole program from stdin, evaluates the top-level forms in
order, and writes the printed value of every non-void form, interleaved with
`display`/`newline` output. A runtime error prints `error: <category>`
(`unbound-variable`, `type-error`, `arity-error`, `division-by-zero`,
`user-error`) directly after the output so far and stops evaluation. The exit
code is 0 either way. (Beyond the spec: text that is not well-formed Scheme
prints `error: syntax-error` after the output of the forms before it.)

## Library use

```clojure
(require '[scheme.core :as scheme])

;; Run a whole program, collecting what the CLI would print:
(scheme/run-string "(display \"hi\") (newline) (* 6 7)")
;; => "hi\n42\n"

;; Or keep an interpreter around and evaluate forms one at a time:
(def interp (scheme/make-interpreter))        ; display writes to *out*
(scheme/eval-string interp "(define (sq x) (* x x))")
(scheme/eval-string interp "(sq 12)")          ;; => 144
(scheme/eval-string interp "(car '())")        ;; throws; see below

(try (scheme/eval-string interp "(quotient 1 0)")
     (catch Exception e (scheme/error-category e)))
;; => :division-by-zero
```

Values are plain JVM objects (see `scheme.types`): integers are `Long`, or
`scheme.number.Bignum` beyond 64 bits; strings are `String`; booleans are
`Boolean`; symbols are interned `Sym`s; lists are `Pair`s ending in `NIL`.
`scheme.printer/write-str` and `display-str` print them.

Note that deep non-tail recursion needs a large stack; `run-string` and
`run-program-big-stack` run on a thread with a 1 GiB stack, while
`eval-string` runs on the caller's thread.

### Modules

| namespace | responsibility |
|---|---|
| `scheme.core` | public API: interpreters, evaluating strings, running programs |
| `scheme.reader` | text to datums |
| `scheme.analyzer` | datums to a tree of executable `Node`s (once per form) |
| `scheme.runtime` | procedure application and the tail-call trampoline |
| `scheme.primitives` | the initial global environment |
| `scheme.printer` | write/display forms |
| `scheme.number` | the integer tower: `Long` with overflow into `Bignum` |
| `scheme.bignum` | magnitude arithmetic (add, sub, schoolbook mul, Knuth D, decimal I/O) |
| `scheme.types` | value representations, frames, errors |
| `scheme.main` | the command-line tool |

## Tests

```
clojure -M:test
```

runs the Cognitect test-runner over `test/`: unit tests for the reader and the
interpreter, and `test.check` property tests that compare the bignum
arithmetic with `java.math.BigInteger` (used only as a test oracle). The
conformance suite in `problems/scheme/tests` is run from the repository root:

```
python3 run_tests.py scheme -- scheme/run.sh
```
