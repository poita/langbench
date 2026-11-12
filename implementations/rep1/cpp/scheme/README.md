# scheme

A small Scheme interpreter in C++17: a reusable library plus a thin
command-line tool. It reads a program on stdin, evaluates the top-level forms
in order, and prints each non-void result (and everything `display`/`newline`
emit) on stdout. Runtime errors print `error: <category>` and stop evaluation;
the exit code is always 0.

Highlights:

- arbitrary-precision integers, implemented from scratch (schoolbook
  multiplication, Knuth Algorithm D division, decimal output by repeated
  division by 10^9); 64-bit fast path for small values;
- proper tail calls (the evaluator loops rather than recursing in every tail
  position, including through `apply`); non-tail recursion 10,000 deep works;
- pre-analysis: each form is turned into a node tree once, then evaluated;
- only the C++ standard library (plus POSIX threads for a big-stack worker).

## Layout

```
include/scheme/   public headers
  bigint.hpp        BigInt: arbitrary-precision integers
  errors.hpp        ErrorKind, SchemeError
  value.hpp         Value, heap objects (Pair, String, Symbol, Closure...), SymbolTable
  numeric.hpp       integer arithmetic on Values (fixnum / bignum)
  reader.hpp        Reader: text -> datums
  printer.hpp       write / display forms
  ast.hpp           analysed node types
  analyzer.hpp      Analyzer: datums -> nodes
  interpreter.hpp   Interpreter: evaluator and top-level driver
  primitives.hpp    built-in procedures
  stack.hpp         run code on a large-stack thread
src/              implementations
cli/main.cpp      the command-line tool
tests/            GoogleTest unit tests
```

## Build

Requires a C++17 compiler and CMake >= 3.20; GoogleTest is needed for the tests.

```sh
./build.sh                       # Release build into ./build (tests included)
ctest --test-dir build           # run the unit tests
cmake -S . -B build -DSCHEME_BUILD_TESTS=OFF   # skip the tests (no GoogleTest needed)
```

## Command line

```sh
echo '(display (* 99999999999 99999999999)) (newline) (list 1 "two" (quote c))' | ./run.sh
# 9999999999800000000001
# (1 "two" c)
```

`run.sh` (or `build/scheme`) takes no arguments: the program is all of stdin.
Each non-void top-level value is printed in `write` form followed by LF.
Errors append `error: unbound-variable | type-error | arity-error |
division-by-zero | user-error` and stop evaluation.

The language: integers, booleans, strings, symbols, pairs, procedures;
special forms `quote 'x`, `if`, `define`, `set!`, `lambda`, `let`, named `let`,
`let*`, `letrec`, `begin`, `cond`, `and`, `or`; primitives `+ - * quotient
remainder = < > <= >= cons car cdr list null? pair? not number? boolean?
string? symbol? procedure? eq? equal? apply error string-append
string-length number->string symbol->string display newline`.

## Library example

```cpp
#include <iostream>
#include <sstream>
#include "scheme/interpreter.hpp"
#include "scheme/printer.hpp"

int main() {
  scheme::Interpreter interp;

  // Evaluate forms and inspect the last value.
  scheme::Value v = interp.eval_string(
      "(define (fact n) (if (= n 0) 1 (* n (fact (- n 1))))) (fact 25)");
  std::cout << scheme::write_string(v) << "\n";   // 15511210043330985984000000

  // Run a whole program with the CLI's output contract.
  std::ostringstream out;
  scheme::RunResult r = interp.run("(display \"hi\") (car '())", out);
  std::cout << out.str();                          // hi error: type-error
  // r.ok == false, *r.error == scheme::ErrorKind::TypeError

  // Add a native procedure.
  interp.define_primitive("twice", 1, 1, [](scheme::Interpreter&, scheme::Value* a, size_t) {
    return scheme::Value::integer(a[0].as_fixnum() * 2);
  });
}
```

Link against the `scheme::scheme` CMake target (`add_subdirectory` this
project, or `cmake --install` and use the installed library and headers).

## Notes and limits

- Memory is reference counted. Objects in reference cycles (a closure stored in
  the frame it captures, e.g. a recursive inner `define`, `letrec` or named
  `let`) are not reclaimed until the interpreter is destroyed.
- Deep non-tail recursion uses the native stack. The CLI runs the interpreter
  on a thread with a 512 MiB stack (`scheme::run_with_stack_size`); library
  users who recurse deeply should do the same.
- A `Value` must not outlive the `Interpreter` that produced it.
- Variable lookup is by symbol at run time through a chain of small frames,
  then the global slot stored in the symbol.
