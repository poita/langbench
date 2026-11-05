# jtemplate

A small Jinja2-style template engine written in D, packaged as a reusable
library (`jtemplate`) plus a thin command-line tool. It implements a
well-defined subset of Jinja2 (strict undefined values, no auto-escaping):
variables and expressions, filters, `if` / `for` / `set`, macros, `include`,
template inheritance (`extends` / `block` / `super()`), comments and
whitespace control. It uses only the D standard library and runtime — the
engine itself (lexer, parser, interpreter, filters) is written from scratch.

## Building

Requires LDC 1.41 and dub 1.40.

```sh
./build.sh                                  # or:
dub build -b release --compiler=ldc2        # produces ./jtemplate
dub test --compiler=ldc2                    # runs the unit tests
```

## Command-line tool

`jtemplate` (or `./run.sh`) reads one document on stdin and writes the result
to stdout:

```
<JSON context: one object, possibly over several lines>
--
=== main
<body of the first template; this one is rendered>
=== other
<body of another template, available to include / extends>
```

* The JSON object is everything before the first line that is exactly `--`.
  Integers (no `.`/`e`) and floats are distinct; member order is preserved.
* A template starts at a line `=== <name>`; its body runs to the LF before the
  next header (or the end of input, minus one trailing LF).
* On success the rendered text is printed followed by `\n`. On failure exactly
  one line `error: <kind>` is printed, where kind is `syntax`, `filter`,
  `undefined`, `template` or `type`. The exit status is 0 either way.

```console
$ printf '{"user": {"name": "Ada"}, "n": 3}\n--\n=== main\nHi {{ user.name|upper }}! {{ n * 2 }}' | ./run.sh
Hi ADA! 6
```

## Library

Add the package as a dub dependency (`dependency "jtemplate" path="..."`,
using the `library` configuration) and `import jtemplate;`:

```d
import std.stdio : writeln;
import jtemplate;

void main()
{
    auto engine = new Engine;
    engine.addTemplate("base",
        "<h1>{% block title %}Untitled{% endblock %}</h1>\n{% block body %}{% endblock %}");
    engine.addTemplate("page",
        `{% extends "base" %}
{% block title %}{{ title|upper }}{% endblock %}
{% block body %}{% for item in items|sort %}{{ loop.index }}. {{ item }}
{% endfor %}{% endblock %}`);

    try
    {
        // The context is JSON text, or a Value built with Value.from*.
        writeln(engine.renderJson("page", `{"title": "Fruit", "items": ["pear", "apple"]}`));
    }
    catch (TemplateError e)
    {
        writeln("error: ", e.kind); // ErrorKind.syntax / filter / undefined / ...
    }
}
```

Public API (all re-exported by `import jtemplate;`):

| Symbol | Purpose |
|--------|---------|
| `Engine` | holds named template sources; `addTemplate`, `render`, `renderJson`; templates are parsed lazily and cached |
| `Value`, `DictObj`, `Kind` | the dynamic value type (`Value.fromInt`, `fromString`, `fromList`, ...) |
| `parseJson` | JSON text to `Value` (ordered objects, integer/float distinction) |
| `TemplateError`, `ErrorKind` | thrown for every template error; `kind` says which |
| `parseDocument`, `renderDocument` | the stdin document format used by the CLI |
| `lex`, `parseTemplate`, AST types | the front end, for tools that want to inspect templates |

Rendering is all-or-nothing: an error anywhere throws a `TemplateError` and no
partial output is returned.

## Source layout

```
source/jtemplate/
  package.d    public import of the API
  engine.d     Engine: template registry, lazy loading, render entry points
  document.d   stdin document format and renderDocument
  errors.d     ErrorKind, TemplateError
  value.d      Value, DictObj (insertion-ordered, hash-indexed), macro / super objects
  json.d       JSON reader
  lexer.d      one-pass lexer: text/tag segments, tokens, whitespace control
  parser.d     recursive-descent parser, filter-name check
  ast.d        tagged node classes (operators and filters resolved at parse time)
  scopes.d     lexical scopes, per-rendering block chains
  interp.d     tree-walking interpreter
  ops.d        operators, truthiness, subscripts, sequence views
  filters.d    the thirteen filters
  format.d     printing, repr, shortest-round-trip float formatting
  buffer.d     growable output buffer
app/main.d     the command-line tool
tests/         unit tests (one module per area; run by `dub test`)
```

## Design notes

* Templates are lexed in a single pass and parsed once; the AST is cached by
  name and walked directly, with all output appended to one buffer that is
  written in a single call.
* Values are a 24-byte tagged union; strings, lists and dicts are shared by
  reference and never mutated, so copying a value is O(1).
* Scopes are small linear arrays (with a hash index only when large); a loop
  reuses one scope across iterations; the root scope wraps the JSON object.
* `loop` is a tiny record whose members are computed on access.
