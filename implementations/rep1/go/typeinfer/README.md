# typeinfer

Hindley-Milner type inference for a small ML-like language, as a Go library
and a command-line tool. It reads a program (a sequence of declarations ending
in `;;`) and reports the principal type of every declaration, or the kind of
type error it contains.

It is classic Damas-Milner inference with let-polymorphism and no value
restriction: Algorithm J over a shared type graph, union-find unification with
an occurs check, and level-based (Rémy) generalisation. Generalisation never
scans the environment, and every walk over a type visits each distinct node
once, so large and heavily shared types are cheap. Deep nesting (thousands of
levels) is fine. Only the Go standard library is used.

## Build

Requires Go 1.27 or later.

```sh
./build.sh            # builds bin/typeinfer
go test ./...         # runs the tests
```

(`build.sh` is `go build -o bin/typeinfer ./cmd/typeinfer`.)

## Command-line use

`typeinfer` reads the whole program from standard input and writes one line
per declaration to standard output; `run.sh` is a wrapper that runs the built
binary from any directory.

```console
$ printf 'let compose f g x = f (g x);;\nlet rec len l = if null l then 0 else 1 + len (tl l);;\n(len [true], compose);;\nfun f -> (f 1, f true);;\n' | ./run.sh
compose : ('a -> 'b) -> ('c -> 'a) -> 'c -> 'b
len : 'a list -> int
- : int * (('a -> 'b) -> ('c -> 'a) -> 'c -> 'b)
error: unify
```

Output lines are `name : type` for `let`/`let rec`, `- : type` for a bare
expression, and `error: unify`, `error: occurs` or `error: unbound` for a
declaration that fails (it then binds nothing). Type errors are normal results:
the exit status is 0. If the input is syntactically malformed, the lines for
the declarations before the error are printed, a message goes to stderr and the
exit status is 1.

## The language

```
decl   := "let" ident ident* "=" expr ";;"
        | "let" "rec" ident ident+ "=" expr ";;"
        | expr ";;"
expr   := "let" ["rec"] ident ident* "=" expr "in" expr
        | "fun" ident+ "->" expr
        | "if" expr "then" expr "else" expr
        | operators, loosest to tightest:  ||   &&   = < > <= >= (non-assoc)
          ::  (right)   + -   * /   application
atom   := integer | true | false | ident | "()" | "(" expr ")"
        | "(" expr ("," expr)+ ")" | "[" "]" | "[" expr (";" expr)* "]"
```

Built-ins: `not fst snd hd tl null length map fold`. Types are `int`, `bool`,
`unit`, `'a`, `t -> t`, `t * t * ...` and `t list`. Error kinds are reported
in the order a single left-to-right pass would meet them.

## Library

```
github.com/example/typeinfer          facade: Infer, Run, Result
github.com/example/typeinfer/syntax   lexer, AST, recursive-descent parser
github.com/example/typeinfer/types    type graph, unification, generalisation,
                                      instantiation, printing
github.com/example/typeinfer/infer    the inference engine and environment
```

Quick use of the facade:

```go
package main

import (
	"fmt"

	"github.com/example/typeinfer"
)

func main() {
	results, err := typeinfer.Infer(`
let id = fun x -> x;;
let g = id id;;
(g 1, g true);;
fun x -> x x;;
`)
	if err != nil { // syntax error; results holds the declarations before it
		fmt.Println(err)
	}
	for _, r := range results {
		fmt.Println(r) // id : 'a -> 'a / g : 'a -> 'a / - : int * bool / error: occurs
	}
}
```

Using the layers directly, to infer one declaration at a time:

```go
decls, _ := syntax.ParseProgram("let twice f x = f (f x);;")
in := infer.New()                 // environment with the built-ins
res, err := in.Infer(decls[0])    // err is an *infer.Error on failure
fmt.Println(res.Name, res.Scheme) // twice ('a -> 'a) -> 'a -> 'a
```

A declaration that fails leaves the `Inferer`'s environment unchanged.

## Layout

```
cmd/typeinfer/   the command-line tool
syntax/          lexer.go, ast.go, parser.go
types/           types.go, context.go (unify/generalise/instantiate), print.go
infer/           infer.go, env.go, builtins.go, errors.go
testdata/golden/ input/expected-output pairs run by the root package's tests
build.sh run.sh  build and run scripts
```
