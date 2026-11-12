# typeinfer

Hindley-Milner type inference for a small ML-like language, as a Haskell
library plus a command-line tool.

It reads a program (a sequence of `;;`-terminated declarations) and prints the
principal type of each one, or `error: unify` / `error: occurs` /
`error: unbound` for declarations that do not type-check. The implementation
is Algorithm J: one left-to-right pass that unifies as it goes, over shared
type graphs with union-find unification, an occurs check, level-based
generalisation and let-polymorphism (no value restriction).

## Language

```
let id = fun x -> x;;
let compose f g x = f (g x);;
let rec len l = if null l then 0 else 1 + len (tl l);;
(id 1, id true, len [true]);;
```

* Types: `int`, `bool`, `unit`, functions, tuples (arity ≥ 2), lists.
* Expressions: integers, `true`/`false`, `()`, variables, application,
  `fun x y -> e`, `let [rec] f x y = e in e`, `if`, tuples `(a, b)`,
  lists `[a; b]`, `::`, `+ - * /`, `= < > <= >=`, `&& ||`.
* `let` and `let rec` are always generalised; lambda-bound variables and a
  recursive function inside its own body are monomorphic.
* Built-ins: `not fst snd hd tl null length map fold` (see
  `Language.TypeInfer.Builtins`).
* A declaration that fails binds nothing; later declarations are still
  processed.

The full grammar, typing rules and the order in which errors are detected are
in the problem specification (`problems/typeinfer/SPEC.md` in the repository
this project was built from).

## Building

Requires GHC 9.14 and cabal 3.18.

```
./build.sh          # cabal build, copies the executable to dist/typeinfer
cabal test          # unit and property tests (hspec + QuickCheck)
```

## Command line

`run.sh` (or the `typeinfer` executable) reads the program on stdin and writes
one line per declaration to stdout; the exit code is 0 unless the input cannot
be parsed.

```
$ printf 'let compose f g x = f (g x);;\nfun x -> x x;;\n1 + true;;\n' | ./run.sh
compose : ('a -> 'b) -> ('c -> 'a) -> 'c -> 'b
error: occurs
error: unify
```

Output lines are `name : type` for `let`/`let rec`, `- : type` for a bare
expression, or `error: <kind>`. Type variables are renamed per declaration in
order of first appearance: `'a`, `'b`, ..., `'z`, `'a1`, ...

## Library

```haskell
import Language.TypeInfer

main :: IO ()
main = do
  -- From source text:
  case inferSource "let twice f x = f (f x);; twice not;;" of
    Left err -> putStrLn (renderParseError err)
    Right rs -> mapM_ (putStrLn . renderResult) rs
  -- twice : ('a -> 'a) -> 'a -> 'a
  -- - : bool -> bool

  -- From a syntax tree:
  print (inferExpr (EFun "x" (EVar "x")))
  -- Right (TFun (TVar 0) (TVar 0))

  -- Types are plain values with a printer:
  putStrLn (renderType (TFun (TFun (TVar 0) (TVar 1)) (TList (TVar 1))))
  -- ('a -> 'b) -> 'b list
```

Modules:

| Module | Responsibility |
| --- | --- |
| `Language.TypeInfer` | Facade: parse + infer + render |
| `Language.TypeInfer.Syntax` | AST and a source printer |
| `Language.TypeInfer.Lexer`, `.Parser` | Tokeniser and recursive-descent parser |
| `Language.TypeInfer.Type` | Immutable `Type` and `renderType` |
| `Language.TypeInfer.Graph` | Mutable shared type graph: levels, generalisation, instantiation |
| `Language.TypeInfer.Unify` | Union-find unification with occurs check |
| `Language.TypeInfer.Infer` | Algorithm J over the AST |
| `Language.TypeInfer.Builtins` | Built-in type schemes |
| `Language.TypeInfer.Error` | `TypeError`, `ParseError` |

## Design notes

* Every walk over a type (occurs check, generalisation, instantiation,
  freezing for output) visits each *distinct* node once, using a per-walk stamp
  stored in the node, so types with exponentially large unfoldings but few
  distinct nodes are cheap. Instantiation shares every sub-term that contains
  no quantified variable.
* Successful unification of two constructed nodes forwards one to the other, so
  unifying large equal-but-distinct graphs does not unfold them.
* Generalisation never scans the environment (levels), and monomorphic
  bindings are used as-is.
* Deep inputs rely on GHC's growable stack; no explicit limit is imposed.
