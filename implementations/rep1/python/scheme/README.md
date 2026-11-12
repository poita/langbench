# scheme-interp

An interpreter for a small Scheme subset, written in pure Python (standard
library only), with its own arbitrary-precision integer arithmetic.

It reads a program on stdin, evaluates the top-level forms in order and prints
the value of every non-void form plus whatever `display`/`newline` emit. A
runtime error prints `error: <category>` and stops (exit code is still 0).
Proper tail calls run in constant host stack, and non-tail recursion 10,000
deep works.

## Design

* `reader.py` – iterative reader (interned symbols, quote shorthand, dotted lists).
* `analyzer.py` – each form is analysed **once** into a tree of Python
  closures; variables are looked up by name, innermost frame first.
* `evaluator.py` – the trampoline: tail-position applications return a
  `(procedure, args)` request that `call` performs in a loop.
* `primitives.py` – the primitive procedures.
* `bignum.py` – integers: a Python `int` while the value fits a machine word
  (`|n| < 2**62`), otherwise a `BigInt` (sign + base-2**30 limbs) with
  schoolbook `+ - *`, Knuth's Algorithm D for division and repeated division
  by 10**9 for printing. Python's unbounded `int` is never used for large values.
* `printer.py` – *write* and *display* forms.
* `interpreter.py` – the `Interpreter` class; `runner.py` runs programs in a
  big-stack thread; `cli.py` is the command-line tool.

## Build and run

There is nothing to install. `build.sh` just byte-compiles the sources;
`run.sh` runs the package with `PYTHONPATH` pointing at `src/`:

```
./build.sh
echo '(display (* 99999999999 99999999999)) (newline) (+ 1 2)' | ./run.sh
```

Output:

```
9999999999800000000001
3
```

## Tests

```
python3 -m pytest          # from this directory
```

## Library example

```python
from scheme_interp import Interpreter, run_program

print(run_program('(define (sq x) (* x x)) (display (sq 12)) (sq 100000000000)'))
# 144 followed by 10000000000000000000000

interp = Interpreter()          # globals persist across run() calls
interp.run("(define (fact n) (if (= n 0) 1 (* n (fact (- n 1)))))")
print(interp.run("(fact 25)"), end="")   # 15511210043330985984000000
```

`run_program` runs in a thread with a large stack so that deep recursion
works; use `scheme_interp.call_with_deep_stack` to do the same around an
`Interpreter` you manage yourself. `read_all`, `write_string`,
`display_string` and `scheme_interp.bignum` are also public.

## Notes

Malformed input (not covered by the spec) reports `error: syntax-error`.
