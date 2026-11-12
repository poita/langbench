# template

A small Jinja2-style template engine in Rust, with no dependencies beyond the
standard library. It is a library (`template`) plus a thin command-line tool.

Supported: `{{ expr }}` with arithmetic, comparison chains, `and`/`or`/`not`,
`in`, `~`, attribute/subscript access, 13 filters (`upper lower trim escape
replace length int join first last reverse sort default`), `is defined`;
`if`/`elif`/`else`, `for`/`else` with `loop`, `set`, `macro`, `include`,
inheritance with `extends`/`block`/`super()`, `{# comments #}` and `-`
whitespace control. Behaviour follows Jinja2 3.1 with `StrictUndefined`: any
use of an undefined value is an error.

## Build

```sh
./build.sh            # or: cargo build --release
cargo test            # unit, integration and doc tests
```

Needs Rust 1.96 (or any recent stable). The binary is
`target/release/template`; `run.sh` runs it from any directory.

## Command-line usage

The program reads all of stdin and writes the result to stdout:

```
<JSON context object>
--
=== main
<body of the template to render>
=== other
<body of a template available to include / extends>
```

The first template is rendered. A body runs up to the newline before the next
`=== ` header (the last body loses one trailing newline), so a body that
should end with a newline is followed by an empty line. The output is the
rendering plus one `\n`, or, on failure, a single line `error: <kind>` with
kind `syntax`, `filter`, `undefined`, `template` or `type` (exit status is 0
either way; a diagnostic goes to stderr).

```sh
$ printf '{"user": "ada", "items": [3, 1, 2]}\n--\n=== main\nHi {{ user|upper }}: {% for i in items|sort %}{{ i }} {% endfor %}\n' | ./run.sh
Hi ADA: 1 2 3
```

## Library usage

```rust
use template::{json, Engine, ErrorKind};

fn main() -> Result<(), template::Error> {
    let context = json::parse(r#"{"user": {"name": "Ada"}, "items": [3, 1, 2]}"#)?;
    let engine = Engine::new(
        context,
        [
            ("page".to_string(), r#"{% extends "base" %}{% block body %}Hi {{ user.name }}{% endblock %}"#.to_string()),
            ("base".to_string(), "<{% block body %}{% endblock %}>".to_string()),
        ],
    )?;
    assert_eq!(engine.render("page")?, "<Hi Ada>");

    // Errors carry a kind matching the CLI's `error: <kind>` line.
    let broken = Engine::new(json::parse("{}")?, [("t".to_string(), "{{ missing }}".to_string())])?;
    assert_eq!(broken.render("t").unwrap_err().kind(), ErrorKind::Undefined);
    Ok(())
}
```

`template::render_input(text)` runs the whole stdin protocol on a string.

## Layout

| Module | Responsibility |
|--------|----------------|
| `input` | split the stdin framing into JSON text and named templates |
| `json` | JSON parser producing `Value`s (ordered objects) |
| `lexer` | text/tag splitting, whitespace control, tag tokens |
| `parser`, `ast` | recursive-descent parser, syntax tree, filter check |
| `engine` | tree-walking interpreter: scopes, macros, include, inheritance |
| `scope` | O(1) scope creation, per-rendering block chains |
| `value`, `ops`, `filters` | values and printing, operators, built-in filters |
| `error` | `Error` / `ErrorKind` |

Design notes: each template is lexed, parsed and filter-checked at most once,
on first use; values are reference-counted so binding, passing and iterating
never copies; dicts are insertion-ordered with an index for O(1) lookup.
The CLI renders on a thread with a large stack so deeply nested data and
macro recursion cannot overflow it.
