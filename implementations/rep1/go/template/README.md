# template

A small Jinja-style template engine in Go: a reusable library plus a
command-line tool. It implements a strict subset of Jinja2 3.1
(`StrictUndefined`, no automatic trimming, no autoescaping): variables and
expressions, thirteen filters, `if`/`for`/`set`, macros, `include`, template
inheritance (`extends`/`block`/`super()`), comments and whitespace control.
The template engine itself is written from scratch on the Go standard library
only; there are no third-party dependencies.

## Build

Requires Go 1.27.1.

```sh
./build.sh          # builds bin/template
go test ./...       # runs the unit and golden tests
```

`build.sh` runs `go build -o bin/template ./cmd/template`; `run.sh` runs the
resulting binary and can be called from any directory.

## Command-line use

The tool reads everything from stdin: a JSON object (the context), a line
`--`, then one or more named templates, each introduced by `=== <name>`. The
first template is rendered; the others can be `include`d or `extends`ed.

```sh
./run.sh <<'EOT'
{"user": {"name": "Ada", "tags": ["x", "y"]}, "n": 3}
--
=== main
Hi {{ user.name|upper }}!
{% for t in user.tags -%}
  {{ loop.index }}. {{ t }}
{% endfor -%}
{% if n > 2 %}big{% else %}small{% endif %} {{ 7 / 2 }}
EOT
```

```
Hi ADA!
1. x
2. y
big 3.5
```

On success the output is the rendering followed by one newline. If the
rendering fails, the output is the single line `error: <kind>` with kind one of
`syntax`, `filter`, `undefined`, `template` or `type`, and nothing else; the
exit status is 0 either way. Malformed input (no `--` line, invalid JSON)
is reported on stderr with exit status 2.

## Library use

```go
package main

import (
	"fmt"

	"example.com/template"
)

func main() {
	env := template.NewEnvironment()
	env.Add("base", `<h1>{% block title %}Untitled{% endblock %}</h1>`)
	env.Add("page", `{% extends "base" %}{% block title %}{{ super() }} - {{ name|upper }}{% endblock %}`)

	out, err := env.Render("page", map[string]any{"name": "ada"})
	if err != nil {
		if kind, ok := template.KindOf(err); ok {
			fmt.Println("template failure:", kind)
		}
		return
	}
	fmt.Println(out) // <h1>Untitled - ADA</h1>
}
```

Templates are parsed lazily, at most once per `Environment`, and an
`Environment` may be used from several goroutines. The context passed to
`Render` is a `*value.Dict` (insertion-ordered, as produced by
`jsonctx.Parse`), a `map[string]any`, or `nil`.

## Layout

| Package | Responsibility |
|---------|----------------|
| `template` (root) | `Environment`, scopes and the tree-walking interpreter (statements, expressions, macros, inheritance) |
| `syntax` | lexer, parser and syntax tree; `Parse` reports every `syntax` error |
| `value` | dynamic values (`Dict`, `List`, ...), printing, equality, ordering, arithmetic, attribute access |
| `filters` | the thirteen built-in filters |
| `jsonctx` | JSON reader that keeps member order and tells integers from floats |
| `bundle` | the stdin format of the command-line tool |
| `tplerr` | the shared `Error` type and its `Kind`s |
| `cmd/template` | the command-line tool |

## Language summary

* Tags: `{{ expr }}`, `{% statement %}`, `{# comment #}`; `-` next to a
  delimiter (`{{-`, `-%}`) strips adjacent whitespace.
* Expressions: literals, lists, `.attr` and `[index]`, arithmetic
  (`+ - * / // % **`), `~`, comparisons (chainable, plus `in`/`not in`),
  `and`/`or`/`not`, `x is [not] defined`, filters (`x|join(", ")`), and calls
  of macros, `range` and `super`.
* Statements: `if`/`elif`/`else`, `for`/`else` (with `loop.index`, `index0`,
  `first`, `last`, `length`), `set`, `macro`, `include`, `extends`, `block`.
* Filters: `upper lower trim escape replace length int join first last
  reverse sort default`.
* Using the undefined value for anything but `is defined` and `|default` is an
  `undefined` error.

The authoritative description is `problems/template/SPEC.md`.
