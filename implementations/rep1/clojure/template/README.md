# template

A Jinja2-style template engine written in Clojure: variables, expressions,
thirteen filters, `if` / `for` / `set`, macros, `include`, template inheritance
(`extends` / `block` / `super()`), comments and whitespace control. It is a
small library (`template.core`) with a thin command-line tool on top.
Everything is implemented here (lexer, parser, interpreter, JSON reader) using
only the Clojure standard library; no template engine is used.

The supported language and its exact semantics (a strict subset of Jinja2 3.1
with `StrictUndefined`, no autoescape, no `trim_blocks`) are described in
`problems/template/SPEC.md`.

## Requirements

* Java 27 and the `clojure` CLI
* Clojure 1.12.6 (resolved by `deps.edn`)

## Build

```
./build.sh
```

AOT-compiles the command-line tool into `classes/` and records the runtime
classpath in `.classpath` so `run.sh` can start a JVM directly.

## Command line

```
./run.sh < input
```

The whole of stdin is a JSON object (the context), a line `--`, then one or
more templates, each introduced by `=== name`. The first template is rendered
and printed, followed by a newline:

```
$ ./run.sh <<'EOF'
{"user": {"name": "Ada", "tags": ["x", "y"]}, "n": 3}
--
=== main
Hi {{ user.name|upper }}!
{% for t in user.tags -%}
  {{ loop.index }}. {{ t }}
{% endfor -%}
{% include "footer" %}
=== footer
{{ n * 2 }} {{ missing|default("none") }}
EOF
Hi ADA!
1. x
2. y
6 none
```

On failure nothing but one line `error: <kind>` is printed (exit status 0), with
kind one of `syntax`, `filter`, `undefined`, `template`, `type`.

## Library

```clojure
(require '[template.core :as t])

(t/render-string "Hello {{ name|upper }}! {{ items|sort|join(', ') }}"
                 {:name "ada" :items [3 1 2]})
;=> "Hello ADA! 1, 2, 3"

;; several named templates: include, extends, blocks, macros
(t/render {"page" "{% extends 'base' %}{% block body %}[{{ super() }}]{% endblock %}"
           "base" "<{% block body %}{{ title }}{% endblock %}>"}
          "page"                      ; the template to render
          {:title "T"})               ; the context
;=> "<[T]>"

;; errors are ex-info exceptions carrying the kind
(try (t/render-string "{{ nope }}")
     (catch clojure.lang.ExceptionInfo e (t/error-kind e)))
;=> :undefined
```

Public functions of `template.core`:

| function | purpose |
|----------|---------|
| `(render templates main-name context)` | render a named template from a map of name -> source |
| `(render-string source [context])`     | render one template |
| `(render-json templates main-name json)` | like `render`, context is a JSON object string (member order is kept) |
| `(render-input text)`                  | render a complete program text in the CLI format |
| `(parse-template source)`              | parse and check a template, returning its syntax tree |
| `(error-kind e)`                       | `:syntax`, `:filter`, `:undefined`, `:template`, `:type` or nil |

Context maps may use keyword or string keys; maps, sequential collections,
strings, numbers, booleans and `nil` are converted to template values.

### Modules

| namespace | responsibility |
|-----------|----------------|
| `template.core`    | public API |
| `template.main`    | command-line tool |
| `template.input`   | splitting the stdin format into context and templates |
| `template.json`    | recursive-descent JSON parser producing template values |
| `template.lexer`   | text/tag splitting, whitespace control, tag tokenizer |
| `template.parser`  | recursive-descent parser, block table, filter check |
| `template.interp`  | tree-walking interpreter, macros, inheritance |
| `template.scope`   | lexical scopes (O(1) creation) |
| `template.ops`     | arithmetic, comparison and membership operators |
| `template.filters` | the built-in filters |
| `template.values`  | value model, truthiness, printing, equality |
| `template.errors`  | error kinds |

A template is lexed, parsed and filter-checked at most once per render; values
are shared, never copied.

## Tests

```
clojure -M:test
```

runs the unit and property tests (`test/`) with the Cognitect test-runner and
test.check. The end-to-end conformance suite is run from the repository root:

```
template/build.sh && python3 run_tests.py template -- template/run.sh
```
