# typeinfer

Hindley-Milner type inference for a small ML-like language, as a Clojure
library with a thin command-line tool on top.

Given a program (a sequence of `;;`-terminated declarations) it prints the
principal type of every top-level declaration, or `error: unify`,
`error: occurs` or `error: unbound` for each declaration that does not
type-check. `let` and `let rec` are generalised (let-polymorphism, no value
restriction); lambda-bound variables are monomorphic.

The implementation is Algorithm J: a recursive-descent parser, one
left-to-right inference pass that unifies as it goes, union-find unification
with an occurs check, level-based (Rémy) generalisation, and instantiation
that preserves sharing. Types are shared graphs, so every walk visits each
distinct node once and the cost of generalisation does not depend on the size
of the environment. It uses only the Clojure standard library.

## Requirements and build

Clojure 1.12.6 (the `clojure` CLI) on a recent JDK.

```
./build.sh          # AOT-compiles the CLI into ./classes
```

## Command-line use

```
./run.sh < program.ml
```

The program is read from stdin (UTF-8); one line per declaration is written to
stdout:

| declaration                | output line                         |
|----------------------------|-------------------------------------|
| `let` / `let rec` binding  | `name : <type>`                     |
| bare expression            | `- : <type>`                        |
| failing declaration        | `error: unify` / `occurs` / `unbound` |

A type error is a normal result: the exit code is 0 and processing continues
with the next declaration (a failed `let` binds nothing). Syntax errors are not
part of the language contract; the CLI reports declarations preceding the
malformed one, prints a message on stderr and exits with status 1.

```
$ cat example.ml
let compose f g x = f (g x);;
let rec len l = if null l then 0 else 1 + len (tl l);;
fun f -> (f 1, f true);;
$ ./run.sh < example.ml
compose : ('a -> 'b) -> ('c -> 'a) -> 'c -> 'b
len : 'a list -> int
error: unify
```

The language, its built-ins (`not fst snd hd tl null length map fold`), the
typing rules and the exact output format are described in the problem
specification.

## Library use

Add the project as a `deps.edn` dependency (`:local/root`) and require
`typeinfer.core`:

```clojure
(require '[typeinfer.core :as ti])

;; Whole program in, report out
(print (ti/infer-source "let id x = x;; id 1;; fun x -> x x;;"))
;; id : 'a -> 'a
;; - : int
;; error: occurs

;; Structured results
(vec (ti/infer-program "let k x y = x;; k 1;; nope;;"))
;; => [{:name "k", :type "'a -> 'b -> 'a"}
;;     {:name nil, :type "'a -> int"}
;;     {:error :unbound}]

;; One declaration at a time, threading the environment yourself
(let [[d1 d2] (typeinfer.parser/parse-program "let k x y = x;; k 1;;")
      [env r1] (ti/infer-decl (ti/initial-env) d1)
      [_   r2] (ti/infer-decl env d2)]
  [r1 r2])
```

Inference is recursive and the language allows thousands of nesting levels,
so run deep programs inside `ti/with-deep-stack` (the CLI does):

```clojure
(ti/with-deep-stack #(ti/infer-source big-program))
```

### Modules

| namespace            | responsibility                                                   |
|----------------------|------------------------------------------------------------------|
| `typeinfer.core`     | public API: `infer-source`, `infer-program`, `infer-decl`, `initial-env`, `format-result`, `type->string`, `with-deep-stack` |
| `typeinfer.lexer`    | source text → tokens                                             |
| `typeinfer.parser`   | tokens → syntax tree of plain maps (`parse-program`, `parse-decls`) |
| `typeinfer.types`    | type graph, union-find, unification, generalisation, instantiation |
| `typeinfer.infer`    | the inference pass, environments, built-ins                      |
| `typeinfer.printer`  | rendering types (`'a`, `'b`, ..., minimal parentheses)           |
| `typeinfer.main`     | the command-line tool                                            |

## Tests

```
clojure -X:test
```

runs the unit tests and the `test.check` property tests with the Cognitect
test-runner.
