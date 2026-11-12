# scheme

A small Scheme interpreter written in D: a reusable library (`scheme`) and a
thin command-line tool on top of it.

It implements a deliberately small Scheme subset: arbitrary-precision
integers (the bignum code is written from scratch, with schoolbook
multiplication and Knuth's Algorithm D), strings, symbols, pairs, closures,
`define`/`set!`/`lambda`/`let`/`let*`/`letrec`/named `let`/`begin`/`cond`/`and`/`or`,
proper tail calls and a fixed set of primitives. Runtime errors are reported
as `error: <category>` on the output.

## Design

* **Reader** (`scheme.reader`): recursive-descent parser producing datums,
  with interned symbols.
* **Analyzer** (`scheme.analyzer`, `scheme.ast`): every form, including every
  `lambda` body, is converted once into a tree of `Node`s; `cond`, `let*` and
  friends are lowered there.
* **Evaluator** (`scheme.evaluator`): tail calls are a loop (trampoline), so
  tail loops run in constant host stack. Variables are looked up by name,
  innermost frame first, then in the global environment.
* **Numbers** (`scheme.bignum`, `scheme.numeric`): machine words with overflow
  checks that spill into a `BigNum`; schoolbook multiplication, Algorithm D
  division, decimal output by repeated division by 10^9.
* **Primitives** (`scheme.primitives`), **printer** (`scheme.printer`),
  **values** (`scheme.value`, `scheme.environment`, `scheme.output`).
* `scheme.interpreter` is the entry point: `Interpreter`, `runToString`,
  `withLargeStack`.

Non-tail recursion nests on the host stack. The command-line tool runs the
interpreter on a thread with a 1 GiB stack (`withLargeStack`), so recursion
10,000 deep (and far beyond) works.

## Building

Requires LDC 1.41 and dub 1.40.

```
dub build -b release --compiler=ldc2     # produces bin/scheme
./build.sh                               # the same, from any directory
dub test --compiler=ldc2                 # unit and black-box tests
```

## Command-line usage

The program reads a Scheme program from standard input and writes to standard
output; it takes no arguments and always exits with status 0.

```
$ cat prog.scm
(define (fact n) (if (= n 0) 1 (* n (fact (- n 1)))))
(fact 25)
(display "done") (newline)
'(1 "two" (3 . 4) #t)
(car '())
$ ./run.sh < prog.scm
15511210043330985984000000
done
(1 "two" (3 . 4) #t)
error: type-error
```

The write form of every non-void top-level value is printed on its own line;
`display` and `newline` write immediately. On a runtime error the line
`error: <category>` is appended and evaluation stops. The categories are
`unbound-variable`, `type-error`, `arity-error`, `division-by-zero` and
`user-error`. (A malformed program, which the specification does not cover,
yields `error: syntax-error`.)

## Library usage

Add the package as a dependency (`dependency "scheme" path="..."` with
`subConfiguration "scheme" "library"`) and:

```d
import std.stdio;
import scheme;

void main()
{
    // Collect output in memory...
    auto interp = new Interpreter;
    interp.run(`(define (sq x) (* x x)) (display (sq 12)) (newline) (sq 100000000000)`);
    write(interp.takeOutput());      // "144\n" then "10000000000000000000000\n"

    // ...or evaluate and inspect values directly.
    Value v = interp.eval("(list 1 \"two\" 'three)");
    writeln(toWriteString(v));       // (1 "two" three)

    // Runtime errors surface as exceptions from eval().
    try interp.eval("(car 5)");
    catch (SchemeError e) writeln(categoryName(e.kind)); // type-error

    // Stream output to your own sink, and give deep recursion a big stack.
    auto streaming = new Interpreter((const(char)[] chunk) { stdout.rawWrite(chunk); });
    withLargeStack({ streaming.run("(display \"hello\")"); });
}
```

`Interpreter.run` follows the command-line contract (printing results and the
`error:` line); `Interpreter.eval` returns the last value and throws
`SchemeError` / `SyntaxError` instead. Definitions persist across calls.

## Layout

```
dub.sdl            package manifest (configurations: application, library, unittest)
source/app.d       the command-line tool
source/scheme/     the library
tests/             black-box tests (whole Scheme programs); unit tests are in source/
build.sh run.sh    build and run scripts
```

## Tests

Tests use D's built-in `unittest` blocks (no external framework): unit tests
sit beside the code they test, and `tests/conformance.d` runs whole programs
through the interpreter and checks their output against the specification.
