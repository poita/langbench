# scheme

A small Scheme interpreter in Haskell, as a reusable library plus a thin
command-line tool. Integers are arbitrary precision, with the bignum
arithmetic written from scratch (no `Integer`, no bignum library).

## Design

* **Reader** (`Scheme.Reader`): recursive descent over the text, interning symbols.
* **Analyser** (`Scheme.Analyze`): each top-level form, including every
  `lambda` body, is turned once into a `Node` tree; the evaluator never
  looks at raw s-expressions again.
* **Evaluator** (`Scheme.Eval`): trampolined. A call in tail position is
  returned as a `TailCall` step and performed by the trampoline, so tail
  loops run in constant stack; non-tail calls nest (10,000-deep recursion
  is fine). Environments are chains of frames mapping symbols to values;
  variables are looked up by name at run time.
* **Bignums** (`Scheme.BigInt`): a machine-word fast path plus sign-magnitude
  base-2^32 limbs; schoolbook add/sub/mul, Knuth's Algorithm D for division,
  repeated division by 10^9 for decimal output.
* **Primitives** (`Scheme.Primitives`), **printer** (`Scheme.Printer`),
  **sessions** (`Scheme.Interpreter`); `Scheme` re-exports the public API.

The language is the subset described by the problem specification: `quote`,
`if`, `define`, `set!`, `lambda`, `let`, named `let`, `let*`, `letrec`,
`begin`, `cond`, `and`, `or`, and the primitives `+ - * quotient remainder
= < > <= >= cons car cdr list null? pair? not number? boolean? string?
symbol? procedure? eq? equal? apply error string-append string-length
number->string symbol->string display newline`.

## Build

Requires GHC 9.14 and cabal 3.18.

```
./build.sh          # cabal build, then copies the executable to bin/scheme
cabal test          # unit and property tests (hspec + QuickCheck)
```

## Command-line use

The program reads a whole Scheme program on stdin and writes to stdout the
printed value of every top-level form whose value is not void, interleaved
with `display`/`newline` output. A runtime error prints `error: <category>`
(`unbound-variable`, `type-error`, `arity-error`, `division-by-zero`,
`user-error`) and stops. The exit status is always 0.

```
$ echo '(define (fact n) (if (= n 0) 1 (* n (fact (- n 1))))) (fact 25) (car 5)' | ./run.sh
15511210043330985984000000
error: type-error
```

## Library use

```haskell
import Scheme

main :: IO ()
main = do
  -- Run a program exactly as the CLI does, collecting the output.
  out <- runProgramToString "(define (sq x) (* x x)) (sq 12) (display \"hi\")"
  putStr out                      -- 144\nhi

  -- Or keep a session: definitions persist between calls.
  it <- newInterpreter putStr
  _  <- evalSource it "(define x 20)"
  r  <- evalSource it "(+ x 22)"
  case r of
    Right [VInt n] -> print n     -- 42
    Left err       -> putStrLn (errorCategory err)
    _              -> pure ()
```

`Scheme.BigInt` can be used on its own:

```haskell
import qualified Scheme.BigInt as B
B.toDecimal (B.mul (B.fromInt maxBound) (B.fromInt maxBound))
```

## Layout

```
src/Scheme.hs            public API
src/Scheme/*.hs          BigInt, Types, Reader, Analyze, Eval, Primitives, Printer, Interpreter
app/Main.hs              the CLI
test/                    hspec specs (BigInt properties, reader/printer, evaluation)
```
