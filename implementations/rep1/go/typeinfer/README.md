# typeinfer

Hindley-Milner type inference with let-polymorphism for a small ML-like
language, as a Go library and a command-line tool. Standard library only.

It reads a program (a sequence of `;;`-terminated declarations) and reports
the principal type of each declaration, or the kind of error that made it
fail: `unbound`, `occurs` (infinite type) or `unify`. Every `let` is
generalised (no value restriction); lambda-bound variables and the name of a
`let rec` inside its own body are monomorphic.

The implementation is Algorithm J with destructive union-find unification over
a shared type graph, Rémy-style level-based generalisation, per-name binding
stacks for the environment, and memoised DAG-sharing instantiation, so
generalisation never scans the environment and shared types are never expanded
into trees except when printed.

## Build

```
./build.sh          # go build -o bin/typeinfer ./cmd/typeinfer
go test ./...       # unit tests
```

Requires Go 1.27 or later.

## Command line

```
./run.sh < program.ml        # or: bin/typeinfer < program.ml
```

Standard input is the whole program; standard output gets one line per
declaration:

- `name : <type>` for `let` / `let rec`
- `- : <type>` for a bare expression
- `error: unify`, `error: occurs` or `error: unbound` for a failing
  declaration (it binds nothing; later declarations still run)

The exit status is 0 (type errors are normal results). A syntax error is
reported on stderr after the results that precede it.

```
$ printf 'let compose f g x = f (g x);;\nfun f -> (f 1, f true);;\nlet rec len l = if null l then 0 else 1 + len (tl l);;\n' | ./run.sh
compose : ('a -> 'b) -> ('c -> 'a) -> 'c -> 'b
error: unify
len : 'a list -> int
```

## Language

```
decl  := "let" ["rec"] ident ident* "=" expr ";;" | expr ";;"
expr  := "let" ["rec"] ident ident* "=" expr "in" expr
       | "fun" ident+ "->" expr | "if" expr "then" expr "else" expr
       | binary operators over applications and atoms
atom  := integer | true | false | ident | () | (e) | (e, e, ...) | [] | [e; e; ...]
```

Operators, loosest to tightest: `||`, `&&`, comparison (`= < > <= >=`,
non-associative), `::` (right-associative), `+ -`, `* /`, application.
Arithmetic and comparison take `int`s; `&&`/`||` take `bool`s. Built-ins:
`not fst snd hd tl null length map fold`. Types are `int`, `bool`, `unit`,
`'a`, `t -> t`, `t * t * ...` and `t list`. The full specification is in
`problems/typeinfer/SPEC.md` of the surrounding repository.

## Library

Import path `example.com/typeinfer` (module name in `go.mod`).

| Package | Responsibility |
| --- | --- |
| `example.com/typeinfer` | `Checker`, `Result`, `ErrorKind`: inference, generalisation, printing |
| `example.com/typeinfer/syntax` | `Lex`, `Parse`, the index-based AST, the identifier `Interner` |
| `cmd/typeinfer` | the command-line tool |

Source layout of the root package: `types.go` (type arena, union-find),
`unify.go` (unification, occurs check fused with level adjustment),
`generalize.go` (generalisation and instantiation), `env.go` (binding
stacks), `infer.go` (the inference pass), `builtins.go`, `print.go`,
`checker.go` (public API).

```go
package main

import (
	"fmt"

	"example.com/typeinfer"
)

func main() {
	c := typeinfer.NewChecker()
	results, err := c.Check([]byte(`
let id x = x;;
(id 1, id true);;
fun x -> x x;;
`))
	if err != nil { // only for syntax errors
		fmt.Println(err)
	}
	for _, r := range results {
		fmt.Println(r) // id : 'a -> 'a / - : int * bool / error: occurs
		if !r.OK() {
			fmt.Println("kind:", r.Err) // "occurs"
		}
	}

	// Bindings persist in the Checker across calls.
	ty, _ := c.TypeOf("id") // "'a -> 'a"
	fmt.Println(ty)
}
```

`typeinfer.Infer(src)` is a shortcut that uses a fresh `Checker`. A `Checker`
is not safe for concurrent use; create one per goroutine.
