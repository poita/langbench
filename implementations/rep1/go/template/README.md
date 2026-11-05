# template

A small Jinja2-style template engine written in Go, using only the standard
library. It supports a precisely specified subset of Jinja2: variables and
expressions, thirteen filters, `if` / `for` / `set`, macros, `include`, and
template inheritance (`extends`, `block`, `super()`), plus comments and
whitespace control. The template engine is written from scratch (no
`text/template`, no third-party code); the JSON context is the only input
data and is parsed by a small ordered JSON parser.

The behaviour is defined by `problems/template/SPEC.md` and the design by
`problems/template/APPROACH.md`: templates are lexed and parsed once into an
AST (cached by name, loaded lazily) and rendered by a tree-walking
interpreter over a chain of lexical scopes into a single append buffer.
Rendering is all-or-nothing.

## Layout

| Path | Contents |
|------|----------|
| `*.go` (package `template`) | the library |
| `cmd/template` | the command-line tool |
| `build.sh`, `run.sh` | build the tool to `bin/template` / run it |
| `*_test.go` | unit tests |

Library modules: `errors.go` (error kinds), `value.go` / `scope.go` (values,
ordered dicts, scopes), `lexer.go` / `parser.go` / `ast.go` (source to AST),
`eval.go` / `interp.go` / `ops.go` (interpreter and operators), `filters.go`,
`print.go` (value printing, shortest round-trip float formatting), `json.go`
(order-preserving JSON), `bundle.go` (stdin format), `engine.go` /
`convert.go` (public API).

## Build and test

```
./build.sh              # go build -o bin/template ./cmd/template
go test ./...           # unit tests
```

Requires Go 1.27.1 or later.

## Command line

`template` reads everything from stdin and writes to stdout:

```
<JSON object: the context>
--
=== main
Hello {{ name|upper }}!
=== other
...templates available to include / extends...
```

The first template is rendered and printed followed by a newline. On a
template error the single line `error: <kind>` is printed instead (kinds:
`syntax`, `filter`, `undefined`, `template`, `type`). The exit status is 0 in
both cases; it is non-zero only if the input bundle itself is malformed or
I/O fails.

```
$ printf '{"name": "ada"}\n--\n=== main\nHello {{ name|upper }}!\n' | ./run.sh
Hello ADA!
```

## Library

```go
package main

import (
	"errors"
	"fmt"

	"example.com/template"
)

func main() {
	eng := template.NewEngine(map[string]string{
		"main": `{% extends "base" %}{% block body %}{{ super() }} and {{ items|length }} items{% endblock %}`,
		"base": `[{% block body %}{{ title|default("untitled") }}{% endblock %}]`,
	})
	ctx := template.ContextFromMap(map[string]any{"items": []any{1, 2, 3}})
	out, err := eng.Render("main", ctx)
	if err != nil {
		var te *template.Error
		if errors.As(err, &te) {
			fmt.Println("template failed:", te.Kind)
		}
		return
	}
	fmt.Println(out) // [untitled and 3 items]
}
```

Main entry points:

- `NewEngine(sources map[string]string) *Engine` and `(*Engine).Render(name, ctx *Dict) (string, error)`.
  An `Engine` caches parsed templates and is safe for concurrent use.
- `ParseJSON([]byte) (Value, error)`: JSON to template values, keeping object
  member order and the integer / float distinction. `NewDict`, `NewList` and
  `FromGo` / `ContextFromMap` build contexts from Go values.
- `ParseBundle` / `Process`: the stdin format and the whole CLI contract as a
  function.
- `*Error` with `Kind` (`ErrSyntax`, `ErrFilter`, `ErrUndefined`,
  `ErrTemplate`, `ErrType`).
