# typeinfer

Hindley-Milner (Damas-Milner) type inference with let-polymorphism for a tiny
ML-like language: integers, booleans, unit, lists, tuples, functions, `let`,
`let rec`, and a handful of built-ins (`map`, `fold`, `fst`, ...). It reads a
program, and prints the principal type of every top-level declaration, or
`error: unify | occurs | unbound` for each declaration that does not type-check.

The implementation is Algorithm J: a recursive-descent parser, one
left-to-right inference pass with in-place union-find unification (with an
occurs check), and level-based (Rémy) generalisation, so generalisation never
scans the environment and every walk over a type is linear in its number of
*distinct* nodes (types are shared graphs). It uses only the Python standard
library (Python 3.12+; developed on 3.14).

## Build

There is nothing to install. `./build.sh` byte-compiles the package:

```sh
./build.sh
```

## Command line

```sh
./run.sh < program.ml          # or: PYTHONPATH=src python3 -m typeinfer < program.ml
./run.sh program.ml            # a file argument is also accepted
```

Input is a sequence of `;;`-terminated declarations; the output has one line
per declaration:

```console
$ printf 'let id = fun x -> x;;\nlet compose f g x = f (g x);;\n(id 1, id true);;\nfun x -> x x;;\n' | ./run.sh
id : 'a -> 'a
compose : ('a -> 'b) -> ('c -> 'a) -> 'c -> 'b
- : int * bool
error: occurs
```

The exit status is 0 (type errors are normal results). Malformed input is
reported on stderr and gives exit status 2 after printing the results of the
declarations before it.

## Library

```python
from typeinfer import infer_program, Inferencer, parse_program, infer_type

for r in infer_program("let twice f x = f (f x);; twice (fun n -> n + 1) 0;;"):
    print(r.render())
# twice : ('a -> 'a) -> 'a -> 'a
# - : int

infer_type("fun p -> (snd p, fst p)")      # "'a * 'b -> 'b * 'a"

# Statefully, declaration by declaration:
checker = Inferencer()
for decl in parse_program("let x = 1;; x + true;;"):
    result = checker.check_decl(decl)
    print(result.name, result.ok, result.error)   # x True None / None False unify
```

Modules:

| module | responsibility |
| --- | --- |
| `typeinfer.lexer`, `parser`, `syntax` | tokens, recursive-descent parser, AST |
| `typeinfer.typerep` | types as a shared union-find graph (`TVar`, `TCon`) |
| `typeinfer.unify` | unification, occurs check, level adjustment |
| `typeinfer.scheme` | level-based generalisation and instantiation |
| `typeinfer.env`, `builtins` | environment with undo trail; initial bindings |
| `typeinfer.infer` | Algorithm J (`Inferencer`, `infer_program`, `DeclResult`) |
| `typeinfer.pretty` | printing types |
| `typeinfer.cli`, `runtime` | command line; deep-recursion helper |

Parsing, inference and printing recurse on nesting depth. Programs nested
thousands deep need a raised recursion limit; `typeinfer.run_deep(fn)` calls
`fn()` with one on a large-stack thread (the CLI does this).

Errors: `TypeCheckError` (with subclasses `UnifyError`, `OccursError`,
`UnboundVariableError`; `.kind` is the text printed after `error:`) and
`ParseError`, all under `TypeInferError`.

## Tests

```sh
python3 -m pytest        # needs pytest; pythonpath is configured in pyproject.toml
```
