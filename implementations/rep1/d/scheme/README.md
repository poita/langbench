# scheme

A small Scheme interpreter written in D, packaged as a reusable library plus a
thin command-line tool. It supports arbitrary-precision integers (a
hand-written bignum, no library code), proper tail calls, closures, `define`
anywhere in a body, named `let`, and a small set of primitives. It depends only
on the D standard library and runtime.

## Design

Source text is parsed by a recursive-descent `Reader` into datums. Each
top-level datum is compiled once by `Compiler` into a tree of `Node`s, which a
single trampolined evaluation loop (`Interpreter`) executes. Tail positions
replace the current node and environment instead of recursing, so tail loops
run in constant stack. Values are 16-byte tagged structs with unboxed fixnums;
integers that overflow a `long` become sign-magnitude bignums in base 2^32
(schoolbook multiplication, Knuth Algorithm D division). Environments are
heap frames of `(symbol id, value)` slots; globals are an array indexed by
symbol id. All output goes to one in-memory buffer.

| module | responsibility |
|---|---|
| `scheme.bignum` | arbitrary-precision `BigInt` |
| `scheme.value` | tagged `Value`, `Pair`, strings |
| `scheme.numeric` | integer arithmetic on `Value`s (fixnum fast path, promotion) |
| `scheme.symbols` | symbol interning, ids of the special-form names |
| `scheme.reader` | text to datums |
| `scheme.compiler`, `scheme.node` | datums to node trees; frames and closures |
| `scheme.primitives` | built-in procedures |
| `scheme.interp` | the evaluator, `Interpreter` |
| `scheme.printer`, `scheme.output` | `write`/`display` text and the output buffer |
| `scheme.errors` | `SchemeError` and its categories |
| `scheme` (`package.d`) | public import of the above and `runProgram` |

## Build

Requires LDC and dub (developed with LDC 1.41.0 and dub 1.40.0).

```
./build.sh          # runs: dub build -b release --compiler=ldc2 --config=cli
dub test --compiler=ldc2
```

This produces `bin/scheme`. Unit tests live in `tests/`, separate from the
library sources in `source/`.

## Command-line use

The program is read from standard input, the output is written to standard
output, and the exit code is always 0. Each top-level form's value is printed
(unless void), `display`/`newline` output is interleaved, and a runtime error
prints `error: <category>` and stops evaluation (`unbound-variable`,
`type-error`, `arity-error`, `division-by-zero`, `user-error`).

```
$ echo '(define (fact n) (if (= n 0) 1 (* n (fact (- n 1))))) (fact 30) (display "hi")' | ./run.sh
265252859812191058636308480000000
hi
```

## Library use

Add the package as a dub dependency (`"scheme": {"path": "../scheme"}`, using
the `library` configuration) and import `scheme`:

```d
import std.stdio : write;
import scheme;

void main()
{
    // One-shot:
    write(runProgram(`(display "sum: ") (+ 1 2)`));    // sum: 3

    // Keep state between calls:
    auto interp = new Interpreter;
    interp.run("(define (sq x) (* x x))");
    write(interp.run("(sq 123456789012)"));            // 15241578753153483936144
}
```

`Interpreter.run` returns everything written so far including the final
`error: ...` line if the program failed; it does not throw for Scheme errors.
Non-tail recursion uses the host stack, so `run` evaluates on a helper thread
with a 256 MB stack (`runHere` uses the caller's stack instead).
