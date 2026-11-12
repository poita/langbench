# jtemplate

A small Jinja2-style template engine written in pure Python (standard library
only), with a command-line tool on top.

It supports variables and expressions, filters, `if`/`for`/`set`, macros,
`include`, template inheritance (`extends`, `block`, `super()`), comments and
whitespace control. Rendering is a tree-walking interpreter over a syntax tree
built by a hand-written lexer and recursive-descent parser; each template is
lexed, parsed and filter-checked at most once, when first needed.

## Build

Requires Python 3.14. There is nothing to install; the build step only
byte-compiles the sources:

```sh
./build.sh
```

Tests need `pytest`:

```sh
python3 -m pytest
```

(`pyproject.toml` sets `pythonpath = ["src"]`, so no installation is needed.)

## Command-line use

`run.sh` reads one document on stdin and writes the rendering of its first
template to stdout:

```
<JSON context object, one or more lines>
--
=== main
Hello {{ user.name|upper }}!
=== footer
-- bye --
```

```sh
printf '{"user": {"name": "Ada"}}\n--\n=== main\nHello {{ user.name|upper }}!\n' | ./run.sh
# Hello ADA!
```

- The text before the first line that is exactly `--` is the JSON context.
- Each `=== NAME` line starts a template; the first is rendered, the others are
  available to `include` and `extends`. A body ends at the LF before the next
  header (or at the end of input, minus one trailing LF).
- On success the output is the rendering plus a newline. On failure it is a
  single line `error: <kind>` with kind `syntax`, `filter`, `undefined`,
  `template` or `type`. The exit status is 0 either way.

The same program is available as `python3 -m jtemplate` with
`PYTHONPATH=src`.

## Library use

```python
from jtemplate import Environment, TemplateError, render

# One-shot: the first template is rendered.
render({"main": "{{ 1 + 2 }}"})                       # '3'

# Several named templates, rendered by name.
env = Environment({
    "page": '{% extends "base" %}{% block body %}{{ super() }}, {{ user|upper }}{% endblock %}',
    "base": "<{% block body %}hi{% endblock %}>",
})
env.render("page", {"user": "ada"})                   # '<hi, ADA>'

try:
    env.render("page", {})
except TemplateError as exc:
    print(exc.kind)                                   # 'undefined'
```

Public API (`jtemplate`):

| Name | Purpose |
|------|---------|
| `Environment(templates)` | named template sources; `.render(name, context)`, `.load(name)` |
| `render(templates, context, main=None)` | convenience wrapper around `Environment` |
| `parse_document(text)` | split the CLI input format into a `Document(context, templates)` |
| `TemplateError` and subclasses | `.kind` is `syntax`, `filter`, `undefined`, `template` or `type` |

Context values are plain Python data: `int`, `float`, `bool`, `None`, `str`,
`list` and `dict`.

## Layout

```
src/jtemplate/
  lexer.py        template text -> text/tag items, whitespace control, tag tokens
  parser.py       tokens -> syntax tree; filter-name check
  nodes.py        syntax tree classes
  interpreter.py  scopes, statements, expressions, macros, inheritance
  operators.py    arithmetic, comparison and membership operators
  filters.py      the thirteen filters
  values.py       value helpers: undefined, printing, truthiness, sequence view
  environment.py  Environment: lazy template loading and rendering
  inputformat.py  parser of the CLI input document
  cli.py          command-line entry point
tests/            pytest suite
```

## Language summary

- Tags: `{{ expr }}`, `{% statement %}`, `{# comment #}`; `-` next to a
  delimiter strips adjacent whitespace (`{{- x -}}`).
- Expressions: literals, lists, `.attr`/`[index]`, calls, `+ - * / // % **`,
  `~`, comparisons (chained), `in`/`not in`, `and`/`or`/`not`, filters,
  `is defined`.
- Filters: `upper lower trim escape replace length int join first last reverse
  sort default`.
- Statements: `if`/`elif`/`else`, `for`/`else` (with `loop.index`,
  `index0`, `first`, `last`, `length`), `set`, `macro`, `include`, `extends`,
  `block`.
- Undefined values are strict: using one other than via `is defined` or
  `default` is an `undefined` error.
