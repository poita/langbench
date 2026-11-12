# template-engine

A small Jinja2-style template engine written in Haskell, using only GHC's
bundled libraries (`base`, `containers`, `text`, `bytestring`).  It implements
a precisely specified subset of Jinja2 3.1 (with `StrictUndefined`, no
auto-escaping and no `trim_blocks`/`lstrip_blocks`):

* `{{ expr }}`, `{# comments #}` and `-` whitespace control (`{{-`, `-%}`, ...)
* expressions: arithmetic (`+ - * / // % **`), `~`, comparison chains, `in`,
  `and`/`or`/`not`, list literals, `a.b` / `a[i]`, calls, `is [not] defined`
* thirteen filters: `upper lower trim escape replace length int join first last
  reverse sort default`
* `if`/`elif`/`else`, `for`/`else` (with `loop`), `set`, `macro`, `include`
* inheritance: `extends`, `block`, `super()`
* the built-in `range`

Errors are one of `syntax`, `filter`, `undefined`, `template` or `type`;
rendering is all-or-nothing.

## Layout

| Module | Responsibility |
|--------|----------------|
| `Template` | public API (`render`, `renderIO`, `parseTemplate`, values, errors) |
| `Template.Lexer` | splits bodies into text/tags, whitespace control, tag tokens |
| `Template.Parser` | recursive-descent parser, block structure, filter-name check |
| `Template.Syntax` | the syntax tree |
| `Template.Value` | runtime values, scopes, printing (`repr`, Python-style floats) |
| `Template.Ops` | operators, truthiness, equality, comparison |
| `Template.Filters` | the built-in filters |
| `Template.Eval` | tree-walking interpreter, inheritance chains, macros |
| `Template.Json` | JSON parser producing template values |
| `Template.Document` | the stdin format used by the command-line tool |
| `app/Main.hs` | the command-line tool |

Each template is lexed, parsed and checked at most once (on first use);
values are shared and scopes are O(1) to create.

## Building

Requires GHC 9.14 and cabal 3.18.

```
./build.sh          # cabal build, then copies the executable to bin/template
cabal test          # runs the hspec/QuickCheck suite
```

## Command-line use

`run.sh` (or `bin/template`) reads a document on stdin and writes the result
of rendering its first template on stdout:

```
<JSON object: the initial variables>
--
=== main
<template body>
=== other
<template body, available to include/extends>
```

```
$ printf '{"name": "Ada", "tags": ["x", "y"]}\n--\n=== main\nHi {{ name|upper }}: {{ tags|join(", ") }}\n' | ./run.sh
Hi ADA: x, y
```

On success the output is the rendering followed by a newline.  On a template
error the output is the single line `error: <kind>` and the exit code is still
0.  Input that does not follow the document format (no `--` line, invalid
JSON) is reported on stderr with exit code 2.

A body runs from the line after its `=== name` header to the line before the
next header (the final body loses one trailing newline); a body that should
end with a newline needs a blank line before the next header.

## Library use

```haskell
{-# LANGUAGE OverloadedStrings #-}
import qualified Data.Text.IO as T
import qualified Data.Sequence as Seq
import Template

main :: IO ()
main = do
  let context   = [ ("user", VDict (dictFromList [("name", VStr "Ada")]))
                  , ("items", VList (Seq.fromList [VInt 3, VInt 1, VInt 2])) ]
      templates = [ ("page", "{% extends 'base' %}{% block body %}Hi {{ user.name }}{% endblock %}")
                  , ("base", "<main>{% block body %}{% endblock %}</main>") ]
  case render context templates "page" of
    Right out -> T.putStrLn out        -- <main>Hi Ada</main>
    Left err  -> putStrLn ("error: " ++ errorKindName err)
```

(Lists are `Seq Value`.)  Contexts can
also be read from JSON with `parseJson`, and `parseDocument`/`renderDocument`
implement the command-line input format.
