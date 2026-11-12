# jinjalite

A small Jinja2-style template engine for D, with a command-line tool on top.

It implements a well-defined subset of Jinja2 (strict undefined values, no
autoescape, no automatic whitespace trimming): `{{ expressions }}`, thirteen
filters, `if`/`elif`/`else`, `for`/`else` with `loop`, `set`, macros, `include`,
template inheritance with `extends`/`block`/`super()`, comments and `-`
whitespace control. Templates are lexed and parsed by recursive descent once,
then rendered by a tree-walking interpreter over a chain of lexical scopes.
Values are shared, never copied, so binding, passing and returning them is O(1).

The engine is written from scratch; it depends only on the D standard library
(`unittest` is the test framework).

## Build

Requires LDC and dub (developed with LDC 1.41.0 and dub 1.40.0).

```sh
./build.sh          # runs: dub build -b release --compiler=ldc2 --config=application
```

This produces `bin/jinjalite`. Run the tests with:

```sh
dub test --compiler=ldc2
```

## Command-line use

`./run.sh` (or `bin/jinjalite`) reads all of stdin and writes the result to
stdout:

```
<JSON context: an object, possibly over several lines>
--
=== main
<body of the template that is rendered>
=== other
<bodies of templates available to include / extends>
```

The first template is rendered. On success the output is the rendered text and
a newline; on any template error it is a single line `error: <kind>` with kind
one of `syntax`, `filter`, `undefined`, `template`, `type`. The exit status is
0 in both cases, and nothing is printed for a failed render beyond that line.
Malformed input (no `--` line, invalid JSON) is reported as `error: syntax`
with details on stderr.

```console
$ printf '{"user": {"name": "Ada"}}\n--\n=== main\nHi {{ user.name|upper }}!\n' | ./run.sh
Hi ADA!
```

## Library use

Add the package as a dependency (`dependency "jinjalite" path="..."` or
`version`) and select its `library` configuration if you do not want the CLI:

```d
import std.stdio : writeln;
import jinjalite;

void main()
{
    auto env = new Environment;
    env.addTemplate("base", "<h1>{% block title %}Untitled{% endblock %}</h1>");
    env.addTemplate("page",
        `{% extends "base" %}{% block title %}{{ user.name|upper }}'s {{ super() }}{% endblock %}`);

    // A context is a dict `Value`; `parseJson` keeps member order.
    auto ctx = parseJson(`{"user": {"name": "ada"}}`);

    try
        writeln(env.render("page", ctx));       // <h1>ADA's Untitled</h1>
    catch (TemplateError e)
        writeln("failed: ", kindName(e.kind));  // syntax, filter, undefined, template or type
}
```

Contexts can also be built by hand with `Value.integer`, `Value.text`,
`Value.list`, `Value.dict(Dict)` and friends.

### Modules

| Module | Responsibility |
|--------|----------------|
| `jinjalite.environment` | `Environment`: template registry, lazy loading, `render` |
| `jinjalite.value` | `Value`, `List`, `Dict`, truthiness, printing (`toStr`), equality |
| `jinjalite.json` | `parseJson`: JSON to `Value`, order-preserving |
| `jinjalite.errors` | `TemplateError`, `ErrorKind` |
| `jinjalite.document` | the combined stdin format used by the CLI |
| `jinjalite.lexer` | splitting into text/tags, whitespace control, tokens |
| `jinjalite.parser`, `jinjalite.ast` | recursive-descent parser and syntax tree |
| `jinjalite.interpreter`, `jinjalite.scoping` | tree-walking evaluation, scopes, blocks, macros |
| `jinjalite.operators`, `jinjalite.filters` | operator semantics, subscripts, the built-in filters |
| `jinjalite.floatfmt` | shortest round-trip float printing |

## Layout

```
dub.sdl            manifest (configurations: application, library, unittest)
source/jinjalite/  the library
cli/main.d         the command-line tool
tests/             end-to-end unit tests (more unittest blocks live in each module)
build.sh run.sh    build and run wrappers
```
