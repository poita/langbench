# template — Jinja-style template engine

Read a JSON context and a set of named templates from stdin, render the
first template, and print the result. The language is a subset of Jinja2
(variables, expressions, filters, `if`, `for`, `set`, macros, `include`,
template inheritance with `extends`/`block`/`super()`, comments and
whitespace control). Every expected output in the test suite was produced
by Jinja2 3.1 (`StrictUndefined`, `trim_blocks=False`,
`lstrip_blocks=False`, autoescape off); this document describes exactly what
it does on the supported subset, and the guarantees at the end list what
the tests never contain.

Write the template engine yourself: don't use a template engine (Jinja2 or any
other) from a library, the standard library or the language. The JSON context
is only input data and may be read with any JSON parser.

## Input

The entire stdin is UTF-8 text with LF (`\n`) line endings and no BOM.

```
<JSON context: one or more lines>
--
=== <name>
<template body>
=== <name>
<template body>
...
```

- Everything before the first line that is exactly `--` is one JSON
  document (RFC 8259) whose top-level value is an object. It may span
  several lines. Its members, in document order, are the initial variables
  of the render (member order matters: iterating a dict visits keys in this
  order). JSON numbers without a fraction or exponent part are **integers**;
  numbers with a `.` or an `e`/`E` are **floats**. Strings, arrays
  (**lists**), objects (**dicts**), `true`, `false` and `null` (**none**)
  map to the corresponding template values. Duplicate keys do not occur.
- After the `--` line come one or more templates. A template starts with a
  header line `=== ` (three `=` and one space) followed by its name
  (characters from `A-Z a-z 0-9 _ . / -`; names are unique). Its body is
  the text after the header line's LF up to the LF that precedes the next
  header line (that LF is not part of the body), or, for the last template,
  up to the end of input with one trailing LF removed if the input ends
  with LF. So in the example below the body of `main` is
  `Hello {{ name }}!` without a trailing newline; a body that should end
  with a newline is written with an empty line before the next header. A
  body line never starts with `===`.
- The **first** template is rendered. The others are available to
  `include` and `extends` by name. Nothing else is on stdin.

## Output

On success: the rendered text, followed by a single `\n`. On failure:
exactly one line `error: <kind>` where `<kind>` is one of `syntax`,
`filter`, `undefined`, `template`, `type` (defined below), and nothing
else (no partial rendering). The exit code is 0 in both cases. stderr is
ignored. The test runner ignores trailing whitespace at the end of each
output line and trailing newlines at the end of the output; everything
else must match exactly.

Rendering is all-or-nothing: an error anywhere (even after most of the
output has been produced) yields only the error line. Errors are
detected in a fixed order, described in "Loading and errors" below.

## Template syntax

A template body is a sequence of literal **text** and three kinds of tag:

| Tag | Meaning |
|-----|---------|
| `{{ expr }}` | print the value of `expr` (see "Printing") |
| `{% ... %}` | statement |
| `{# ... #}` | comment, produces nothing; its content is arbitrary text and ends at the first `#}` |

Anything outside tags is text and is copied to the output verbatim. A
tag begins at the first `{{`, `{%` or `{#` found scanning left to right
(so `{{{ x }}}` opens a tag whose content starts with `{`, a syntax
error). `{` not followed by `{`, `%` or `#` is text; `}` is text. A tag
opener that is never closed is a syntax error (this includes an unclosed
comment). Tags do not nest and are not recognised inside string literals:
the closing `}}`/`%}` is found by tokenizing the tag content, so a string
literal such as `"%}"` inside a tag does not end it.

### Whitespace control

An opener may be followed immediately by `-` (`{{-`, `{%-`, `{#-`) and a
closer may be preceded immediately by `-` (`-}}`, `-%}`, `-#}`).

- `-` after the opener removes all whitespace (any run of the characters
  space, TAB, LF, CR, FF, VT) at the end of the text immediately preceding
  the tag. Only the text is affected; nothing is removed across another tag.
- `-` before the closer removes all whitespace at the start of the text
  immediately following the tag.
- Both may be used on the same tag. Comments support both as well:
  `{#- ... -#}`.
- There is no automatic trimming (Jinja2's `trim_blocks` and
  `lstrip_blocks` are off): without `-`, the newline after a `%}` and the
  indentation before a `{%` are ordinary text.

### Tag content lexing

Inside `{{ }}` and `{% %}` the content is tokenized. Whitespace (the six
characters above) separates tokens and is otherwise ignored. Tokens:

- **Names**: `[A-Za-z_][A-Za-z0-9_]*`. The words `and or not in is true
  false none` are keywords and cannot be used as variable, parameter, loop
  or macro names; `defined` is only meaningful after `is`.
- **Integers**: `[0-9]+`. **Floats**: `[0-9]+\.[0-9]+` (no exponent form,
  no leading or trailing bare `.`).
- **Strings**: `"..."` or `'...'`. Inside, a backslash introduces one of
  exactly these escapes: `\\` (backslash), `\"`, `\'`, `\n` (LF), `\t`
  (TAB). Any other character after a backslash is a syntax error. A string
  may contain the other quote character and any character except an
  unescaped backslash or its own quote; a string reaching the end of the
  template is a syntax error.
- **Operators/punctuation**: `** // == != <= >= ~ + - * / % < > ( ) [ ]
  , | . =`. Longest match wins (`**` before `*`). Any other character in a
  tag is a syntax error.
- The closer: `}}` or `-}}` for `{{`, `%}` or `-%}` for `{%`. At each token
  boundary the closer is checked before operators, so `{{ x -}}` ends the
  tag with whitespace control (it is not `x - }}`). `-` separated from the
  closer by whitespace is the minus operator (`{{ x - }}` is a syntax
  error: the expression is incomplete).

### Expressions

Grammar, lowest to highest precedence (all binary operators are
left-associative, including `**`):

```
expr     := or
or       := and ( "or" and )*
and      := not ( "and" not )*
not      := "not" not | compare
compare  := additive ( cmpop additive )*        cmpop: == != < <= > >= in "not in"
additive := concat ( ("+" | "-") concat )*
concat   := term ( "~" term )*
term     := power ( ("*" | "/" | "//" | "%") power )*
power    := filtered ( "**" filtered )*
filtered := unary ( "|" NAME [ "(" args ")" ] | "is" ["not"] "defined" )*
unary    := "-" unary | postfix
postfix  := primary ( "." NAME | "[" expr "]" | "(" callargs ")" )*
primary  := INT | FLOAT | STRING | "true" | "false" | "none" | NAME
          | "[" [ expr ("," expr)* ] "]" | "(" expr ")"
args     := [ expr ("," expr)* ]                (no trailing comma)
callargs := [ arg ("," arg)* ]   arg := expr | NAME "=" expr
```

Notes:

- Filters and `is defined` bind tighter than every binary operator but
  looser than unary minus and postfix operators: `a * b|int` is
  `a * (b|int)`, `-x|int` is `(-x)|int`, `x.y|f` is `(x.y)|f`,
  `1 + x is defined` is `1 + (x is defined)`. `not` binds looser than
  comparisons: `not a == b` is `not (a == b)`.
- Comparisons chain: `a < b < c` means `a < b and b < c` with `b` evaluated
  once; evaluation stops at the first false comparison (later operands are
  not evaluated). The result of a comparison chain is a boolean.
- `and`/`or` short-circuit and return the deciding **operand**, not a
  boolean: `0 or "x"` is `"x"`, `"" and 1` is `""`, `1 and 2` is `2`.
  `not` always returns a boolean.
- In `callargs`, keyword arguments (`name=expr`) must come after all
  positional arguments and no keyword may repeat; otherwise it is a syntax
  error. Filter arguments are positional only.
- A list literal `[a, b]` evaluates its elements left to right. No dict
  literals, slices, conditional expressions (`a if b else c`), or tuples
  exist; they are syntax errors.
- `-` directly before a number literal is the unary operator applied to the
  literal (`-2 ** 2` is `(-2) ** 2` = `4`; `2 ** -1` is `0.5`).

### Statements

Statement keywords are the first token of a `{% %}` tag. Anything else
(including `raw`, `import`, `call`, `with`, `filter`, or a tag with no
tokens) is a syntax error, as is a closing tag with no matching opener, a
body that reaches the end of the template without its closing tag, and
any extra tokens after the forms shown.

```
{% if expr %} body {% elif expr %} body ... {% else %} body {% endif %}
{% for NAME in expr %} body {% else %} body {% endfor %}
{% set NAME = expr %}
{% macro NAME ( params ) %} body {% endmacro %}
{% include expr %}
{% extends expr %}
{% block NAME %} body {% endblock %}       or   {% endblock NAME %}
```

- `if`: `elif` and `else` are optional (`elif` any number of times, then at
  most one `else`, which must be last). The first branch whose condition is
  truthy runs.
- `for`: iterates over the **sequence view** of the value (see "Values"),
  binding `NAME` and `loop` for each element, in order. If the sequence is
  empty the `else` body (if any) runs instead, once, without `loop`.
  `loop` is a dict-like value with exactly these members: `index` (1-based
  position), `index0` (0-based), `first`, `last` (booleans), `length`
  (number of elements). In nested loops `loop` refers to the innermost
  loop. `loop` is not defined outside a loop body (using it there is an
  `undefined` error, like any unknown name). A loop iterates over the
  sequence as it was when the loop started.
- `set` evaluates the expression and binds the name in the **current
  scope** (see "Scopes").
- `macro` defines a macro (see "Macros"). `params` is a comma-separated
  list of `NAME` or `NAME = expr`; parameter names are distinct.
- `include` evaluates `expr` (which must be a string naming a template)
  and inserts the rendering of that template. `extends` evaluates `expr`
  likewise and makes that template the parent (see "Inheritance"). An
  `extends` tag may appear only at the top level of a template (not inside
  any `if`, `for`, `block` or `macro` body) and at most once per template;
  otherwise it is a syntax error.
- `block` defines a named block (see "Inheritance"). `{% endblock NAME %}`
  must repeat the block's own name. Two blocks with the same name in one
  template are a syntax error. Blocks may appear anywhere, including inside
  other blocks.

The rest of a tag after its keyword must be exactly the form shown: e.g.
`{% for a, b in x %}`, `{% for x in y if z %}`, `{% set a, b = ... %}`,
`{% include "x" ignore missing %}`, `{% block x scoped %}` are syntax
errors.

## Values

Kinds of value: **integer** (arbitrary precision in principle; tests stay
within signed 64-bit), **float** (IEEE double), **boolean** (`true`,
`false`), **none**, **string** (sequence of Unicode code points), **list**,
**dict** (string keys, insertion-ordered), **macro**, and the
**undefined** value. Booleans are integers for every purpose except
printing: `true` is `1` and `false` is `0` in arithmetic, comparisons,
indexing and `in`; `true == 1` is true.

**Truthiness**: `false`, `none`, `0`, `0.0`, `""`, `[]` and `{}` are
falsy; every other defined value (including macros) is truthy. Testing
the truthiness of the undefined value is an `undefined` error.

**Sequence view** (used by `for`, `in`, and the filters `join`, `first`,
`last`, `reverse`, `sort`): a list is its elements; a dict is the list of
its keys in insertion order; a string is the list of its characters (each
a one-character string). Any other value where a sequence is required is
a `type` error.

### Attribute and subscript access

`a.NAME` and `a[expr]` are the same operation on the value `a` with a key
(for `.NAME` the key is the string `NAME`):

- `a` is a dict and the key is a string: the member's value, or
  **undefined** if there is no such member.
- `a` is a list or string and the key is an integer `i`: the element /
  one-character string at index `i`, where negative `i` counts from the
  end (`-1` is the last); **undefined** if out of range.
- any other combination of a defined `a` and a defined key (e.g. `none.x`,
  `5.x`, `list.x`, `list["a"]`, `dict[0]`, `list[1.0]`): **undefined**.
- `a` undefined, or the key undefined: `undefined` error.

### The undefined value

It results from: a name that is not bound in any enclosing scope; an
attribute/subscript miss as above; `first`/`last` of an empty sequence; a
macro parameter with no default that the call did not supply. It can be
stored with `set`, passed as a macro argument, and examined with
`is defined`, `is not defined` and `|default(x)`. **Any other use** —
printing it, testing its truthiness, any operator (`==` included), `in`,
attribute/subscript access on it, iterating it, calling it, or passing it
to any filter other than `default` — is an `undefined` error.

### Operators

Let "number" mean integer, float or boolean. Mixed integer/float
arithmetic and comparison converts the integer to float (integer/integer
operations stay exact integers).

- `+`: two numbers → sum; two strings → concatenation; two lists →
  concatenation. Else `type` error.
- `-` (binary), unary `-`: numbers only, else `type` error.
- `*`: two numbers → product; a string and an integer (either order) → the
  string repeated that many times (`""` if the integer is ≤ 0). Else `type`
  error.
- `/`: numbers; the result is **always a float** (`6 / 3` is `2.0`).
- `//`: floor division (rounds toward −∞); integer result for two
  integers, float otherwise (`-7 // 2` is `-4`, `7.0 // 2` is `3.0`).
- `%`: modulo with the sign of the divisor (`-7 % 3` is `2`, `7 % -3` is
  `-2`); float if either operand is a float.
- Division or modulo by zero (`/`, `//`, `%`) is a `type` error.
- `**`: power. Integer base and non-negative integer exponent → exact
  integer; integer base and negative integer exponent → float
  (`2 ** -1` is `0.5`); any float operand → float. `0 ** negative` is a
  `type` error. (Tests only use small non-negative exponents.)
- `~`: converts both operands to strings as for printing and concatenates.
- `==`, `!=`: two numbers → numeric equality (`1 == 1.0`, `true == 1`);
  two strings → equal contents; two lists → same length and pairwise `==`;
  two dicts → same key set and `==` values per key; `none == none` is
  true; any other pair of defined values is not equal (`1 == "1"` is
  false; `none == 0` is false). Never a `type` error.
- `<`, `<=`, `>`, `>=`: two numbers → numeric; two strings → lexicographic
  by code point (a proper prefix is smaller). Anything else is a `type`
  error.
- `in`, `not in`: right operand a string → left must be a string (else
  `type` error), substring test (`"" in "abc"` is true); right operand a
  dict → true iff the left is a string that is a key; right operand a list
  → true iff some element `==` the left; anything else on the right is a
  `type` error.

### Calls

`f(args)` where `f` evaluates to:

- a **macro**: see "Macros".
- the built-in **`range`**: `range(stop)`, `range(start, stop)` or
  `range(start, stop, step)` with integer arguments produces the list of
  integers `start, start+step, ...` below `stop` (above `stop` for a
  negative step); `start` defaults to `0`, `step` to `1`; `step == 0`,
  non-integer arguments, no arguments, more than three, or keyword
  arguments are `type` errors. The checks run in this order: keyword
  arguments, then the argument count, then each argument left to right
  (an undefined argument is an `undefined` error, any other non-integer a
  `type` error), then `step == 0`. `range` is looked up like any name: a
  variable named `range` shadows the built-in (never done in tests).
- **`super`** inside a block body: see "Inheritance". Passing any
  arguments to `super` is a `type` error.
- anything else defined (number, string, list, dict, none): `type` error.
  Calling the undefined value (e.g. an unknown macro name) is an
  `undefined` error.

Arguments (positional, then keyword) are evaluated left to right, after
the callee, and before anything about the callee is checked: an error
raised while evaluating an argument wins over an undefined or non-callable
callee.

### Filters

`value|name` or `value|name(arg, ...)`. The filter name must be one of the
thirteen below; any other name is a `filter` error (checked when the
template is loaded, see "Loading and errors"). Calling a filter with the
wrong number of arguments is a `type` error. Except for `default`, an
undefined input value is an `undefined` error. The input and then the
arguments are evaluated first (left to right); then, except for `default`,
an undefined input is reported, and only then the argument count is
checked, so `x|upper(1)` with `x` undefined is an `undefined` error, while
`x|default(1, 2)` is a `type` error. "As a string" below means
converted as for printing.

| Filter | Result |
|--------|--------|
| `upper`, `lower` | the value as a string with ASCII letters `a-z`/`A-Z` converted; other characters unchanged |
| `trim` | the value as a string with leading and trailing whitespace (the six characters) removed |
| `escape` | the value as a string with each `&` → `&amp;`, `<` → `&lt;`, `>` → `&gt;`, `"` → `&#34;`, `'` → `&#39;` (each input character is replaced once; the output is never re-escaped) |
| `replace(old, new)` | the value as a string with every non-overlapping occurrence of `old` (as a string) replaced, left to right, by `new` (as a string) |
| `length` | number of code points of a string, elements of a list, members of a dict; any other value is a `type` error |
| `int` | integer → itself; float → truncated toward zero; boolean → `1`/`0`; string → after trimming whitespace, if it matches `[+-]?[0-9]+` that integer, else if it matches `[+-]?([0-9]+\.?[0-9]*|\.[0-9]+)([eE][+-]?[0-9]+)?` that decimal value truncated toward zero, else `0`; any other value → `0` |
| `join`, `join(sep)` | the elements of the sequence view, each as a string, joined by `sep` as a string (default `""`) |
| `first`, `last` | first/last element of the sequence view, or **undefined** if it is empty |
| `reverse` | a string → the reversed string; otherwise the sequence view reversed, as a list |
| `sort` | the sequence view sorted ascending as a new list: all numbers → numeric order; all strings → ordered by the string with ASCII letters lowercased (code point order on that key; equal keys keep their original relative order); any other mix → `type` error |
| `default`, `default(x)` | `x` (default `""`) if the value is undefined, else the value unchanged |

Filters chain left to right: `x|trim|upper`.

## Printing

`{{ expr }}` appends the string form of the value:

- string: as-is. integer: decimal, `-` prefix if negative. boolean:
  `True`/`False`. none: `None`.
- float: the shortest string of significant decimal digits that, converted
  back to a double with correct rounding, gives the same double (when
  several digit strings of that length do, the one nearest the double's
  exact value), laid out as follows. With the value written
  as `d.ddd × 10^e` (one nonzero digit before the point, `e` the decimal
  exponent): if `-4 <= e < 16` use positional notation with at least one
  digit after the point (`3.0`, `0.5`, `1000000000000000.0`, `0.0001`,
  `0.30000000000000004`); otherwise scientific notation `d[.ddd]e±XX` with
  a sign and at least two exponent digits (`1e+16`, `1e-05`, `1.5e+300`).
  Zero prints as `0.0`, negative zero as `-0.0`.
- list: `[` + elements' **repr** joined by `, ` + `]`; dict: `{` +
  `'key': value` pairs (key repr, `: `, value repr) joined by `, ` + `}`.
  Empty: `[]`, `{}`. The repr of a value equals its string form, except
  that a string's repr is quoted: with `'` unless the string contains `'`
  and no `"`, in which case with `"`; inside, `\` → `\\`, LF → `\n`, CR →
  `\r`, TAB → `\t`, and the chosen quote character → `\'` (only `'` ever
  needs this); every other character is copied as-is.
  Example: `[1, 'a', True, None, 1.5, "it's", {'k': [2.0]}]`.
- undefined: `undefined` error. A macro: never printed in tests.

The same conversion is used by `~`, by string-taking filters, and by
`join` for elements.

## Scopes

A scope is a mapping from names to values plus a parent scope. Looking a
name up walks from the current scope to its ancestors and yields the
undefined value if none binds it. `set` and `macro` bind in the current
scope only (they never modify a binding of an ancestor: a `set` inside a
loop body of a name bound outside creates a new inner binding that
disappears with the iteration).

- The **root scope** holds the JSON context members.
- Rendering a template (the main one, or one named by `include`) creates
  its **template scope**, whose parent is the root scope for the main
  template and the scope current at the `include` tag for an included
  template. The template's top-level statements run in the template scope.
  Everything visible at the `include` point is therefore visible in the
  included template, and nothing the included template binds is visible
  to the includer.
- `if` bodies run in the current scope (no new scope).
- Each iteration of a `for` body runs in a **new scope** whose parent is
  the current scope, holding the loop variable and `loop`. The `else`
  body runs in the current scope.
- A macro body runs in a new scope whose parent is the scope in which the
  `macro` tag executed (lexical capture; the macro sees later `set`s in
  that scope because lookup happens at call time). It does not see the
  caller's local variables.
- A block body runs in a new scope whose parent is the **template scope**
  of the rendering (not the scope where the `block` tag appears): a block
  never sees loop variables, macro parameters or `set`s of an enclosing
  block, but does see top-level `set`s and macros that ran before it was
  rendered. `super` is bound in that new scope.

## Macros

`{% macro name(p1, p2=default, ...) %}body{% endmacro %}` binds `name` in
the current scope. A call `name(a, b, k=v)`:

1. creates the macro scope (parent: the defining scope);
2. binds positional arguments to parameters in order; more positional
   arguments than parameters is a `type` error;
3. binds each keyword argument to the parameter of that name; a keyword
   that is not a parameter name, or that names a parameter already bound
   positionally, is a `type` error;
4. for each still-unbound parameter, in declaration order: if it has a
   default, evaluates the default expression **in the macro scope** (so it
   may refer to parameters bound earlier) and binds it; otherwise binds the
   undefined value (an error only if the body then uses it);
5. runs the body with its own output buffer and returns the produced text
   as a **string** (so `n * f(n-1)|int` is how a recursive numeric macro is
   written).

Macros may call themselves and each other. Text produced by the body is
not affected by whitespace outside the macro.

## Inheritance

Every template has a static **block table**: the bodies of all `block`
tags it contains, by name, wherever they appear. A rendering (main
template or one `include`) keeps, per block name, a **chain** of bodies
ordered from most derived to least derived. The chain starts as the
rendered template's own blocks. When an `extends` tag executes, the named
parent template is loaded and each of its blocks is appended to the chain
of the same name (creating the chain if needed).

- Executing a `{% block NAME %}` tag renders the **first** body in the
  chain for `NAME` (the most derived override), in a fresh block scope as
  described in "Scopes", and appends the result to the output. (A
  template's own blocks are always in the chain by the time its body
  runs.)
- Inside a block body being rendered as entry `k` of the chain, `super()`
  renders entry `k+1` (the next less derived body) the same way and
  returns the result as a string; if there is no entry `k+1` this is an
  `undefined` error. Outside a block body, `super` is an unbound name.
- `extends` does not render the parent immediately. The child continues
  executing to its end with the following rule: after the `extends` tag,
  text and `{{ }}` outside blocks are skipped (not evaluated), and no
  other statement outside blocks produces output either, but `set` and
  `macro` statements still take effect (a macro called from such a `set`
  still returns its rendered text: the suppression applies only to the
  template's own output, never to a macro's buffer). Text and tags
  **before** the
  `extends` tag are rendered normally. When the child's body is finished,
  the parent template's body is executed **in the same template scope**
  (so the child's top-level `set`s and macros are visible to the parent,
  and the parent's top-level `set`s and macros before a block tag are
  visible inside the child's override of that block), with output
  appended after whatever the child produced before its `extends` tag. If
  the parent itself contains `extends`, the same happens again with its
  parent (chains are extended in order, so a three-level hierarchy yields
  chains `[grandchild, child, base]`).
- A block defined in a child but absent from every ancestor is simply
  never rendered (unless the child executes it before `extends`).
- A block body may contain `include`; an included template may itself
  use `extends` and blocks (it has its own chains).

## Loading and errors

A template is **loaded** the first time it is needed: the main template
before rendering starts; a template named by `include`/`extends` when that
tag executes. Loading means:

1. lexing and parsing the whole template; any problem is `error: syntax`;
2. then checking every filter name used anywhere in the template (inside
   macros, blocks, unexecuted branches, defaults) against the thirteen
   filters; an unknown name is `error: filter`.

A template that is never loaded is never checked, so an unused template
may be broken. `error: template` is an `include`/`extends` naming a
template that does not exist (a non-string name is `error: type`; an
undefined name is `error: undefined`). Runtime errors (`undefined`,
`type`, `template`, and `syntax`/`filter` from a template loaded by an
`include`/`extends` tag) arise in execution order: statements top to
bottom, sub-expressions left to right as described above, callee before
arguments, filter input before filter arguments, `and`/`or`/comparison
chains short-circuiting. The first error wins and rendering stops. Tests
with an error contain exactly one error.

Summary of kinds:

| kind | when |
|------|------|
| `syntax` | unlexable/unparsable template (as loaded), including unknown statement keywords, unknown `is` tests (only `defined` exists), unbalanced tags, bad escapes, `extends` misplaced or repeated, duplicate block names |
| `filter` | unknown filter name in a loaded template |
| `undefined` | forbidden use of the undefined value; `super()` with no less-derived block |
| `template` | `include`/`extends` of a name with no template |
| `type` | operand/argument of the wrong kind for an operator, filter, `range`, `for`, `in` or call; division/modulo by zero; wrong argument count for a filter, `range` or macro; unknown/duplicate keyword argument; calling a non-callable |

## Worked examples

Input:
```
{"user": {"name": "Ada", "tags": ["x", "y"]}, "n": 3}
--
=== main
Hi {{ user.name|upper }}!
{% for t in user.tags -%}
  {{ loop.index }}. {{ t }}
{% if n > 2 %}big{% endif %}
```
Output:
```
error: syntax
```
(The `for` is never closed; the error is detected when `main` is loaded,
so the greeting is not printed.)

Input:
```
{"user": {"name": "Ada", "tags": ["x", "y"]}, "n": 3}
--
=== main
Hi {{ user.name|upper }}!
{% for t in user.tags -%}
  {{ loop.index }}. {{ t }}
{% endfor -%}
{% if n > 2 and user.tags|length == 2 %}big{% elif n %}small{% else %}none{% endif %} {{ 7 / 2 }} {{ 7 // 2 }} {{ [n, "s"] }}
```
Output:
```
Hi ADA!
1. x
2. y
big 3.5 3 [3, 's']
```
(The `-%}` on the `for` tag removes the newline and indentation before
`{{ loop.index }}`; the newline after `{{ t }}` is kept; the `-%}` on
`endfor` removes the newline before `{% if %}`.)

Input:
```
{"title": "T", "items": [3, 1, 2]}
--
=== page
{% extends "base" %}
{% set count = items|length %}
{% block body %}{{ super() }}<ul>{% for i in items|sort %}<li>{{ item(i) }}</li>{% endfor %}</ul>{% endblock %}
=== base
{% macro item(v) %}#{{ v }}{% endmacro -%}
<h1>{% block title %}{{ title }}{% endblock %}</h1>
{% block body %}{{ count }} items{% endblock %}
{% include "footer" %}
=== footer
-- {{ title|lower }} {{ missing|default("end") }}
```
Output:
```
<h1>T</h1>
3 items<ul><li>#1</li><li>#2</li><li>#3</li></ul>
-- t end
```
(`page` sets `count` after `extends`; that still runs. `base`'s macro
`item` is visible in `page`'s block override because both execute in the
same template scope. The newline after `{% endmacro -%}` is stripped.)

Input:
```
{"a": {"b": 1}}
--
=== main
{{ a.b }}{{ a.c.d }}
```
Output:
```
error: undefined
```
(`a.c` is undefined and attribute access on it is an error.)

## Guarantees (what the tests never contain)

Implementations may rely on all of the following.

1. Input is valid UTF-8; the JSON is a valid object whose strings contain
   no escaped surrogates; template bodies never contain a CR character or
   a line starting with `===`; the first template exists. Text near tags
   uses only space, TAB and LF as whitespace; template text may contain
   non-ASCII characters but strings passed to `upper`, `lower` and `sort`
   are ASCII, strings passed to `trim` contain only the six whitespace
   characters at their ends, and strings passed to `int` contain no `_`
   and no non-ASCII characters. Integer literals have no leading zeros
   (`0` itself is fine).
2. Attribute names (`a.NAME`) and dict keys accessed via `.` are never
   names that Jinja2 resolves to built-in methods of dicts, lists or
   strings (`items`, `keys`, `values`, `get`, `pop`, `update`,
   `copy`, `clear`, `count`, `index`, `append`, `upper`, ...), and no
   variable is named `range`, `super`, `loop`, `self`, `varargs`,
   `kwargs`, `caller`, `True`, `False` or `None`.
3. Integer values and results fit in a signed 64-bit integer; floats never
   overflow to infinity or become NaN; `**` exponents are small
   non-negative integers.
4. Outside `for` bodies, a `set` never assigns a name that is already
   bound in an enclosing scope (a JSON context member, a name bound at the
   top level of the template, or a variable visible at an include point).
   Inside a `for` body a `set` may shadow anything (it creates an
   iteration-local binding). Consequently every name has at most one
   binding visible from any point, apart from loop-local shadowing and
   macro parameters.
5. The result of `escape` is only ever printed or `join`ed (never fed to
   another filter or operator). Strings given to `replace` as `old` are
   non-empty. The result of `reverse` applied to a list or dict is only
   iterated, `join`ed, `sort`ed or passed to `first`; it is never printed
   directly, indexed, or passed to `last`/`length`. The result of `range`
   is only iterated, indexed, or passed to `length`, `join`, `first`,
   `last`, `sort`, `reverse` or `in`; it is never printed directly or
   compared.
6. In a child template, after the `extends` tag there are only blocks,
   `set`, `macro`, comments and text (no `{{ }}`, `if`, `for`, `include`).
   `extends` appears at the top level, at most once.
7. Included templates never refer to `loop`. Blocks never appear inside
   `for` or `macro` bodies. Macros are defined at the top level of a
   template or inside blocks, never inside loops.
8. Lists never contain the undefined value; printed lists/dicts contain
   only the value kinds listed under "Printing", and strings inside printed
   lists/dicts contain no character whose Unicode general category is Cc
   (control), Cf (format), Cs (surrogate), Co (private use), Cn
   (unassigned), Zl (line separator), Zp (paragraph separator) or Zs (space
   separator), except LF, CR, TAB and the ordinary space U+0020. The key of a subscript `a[expr]` is never the undefined
   value. The name expression of `include` evaluates to a string, the
   undefined value or a nonzero integer; that of `extends` to a string or
   the undefined value.
9. An unknown filter name in a test either is evaluated while rendering,
   or appears outside every `if`/`elif`/`else` body (directly in a macro
   body, a loop body or a macro parameter default); it is never only
   inside a conditional branch that is not taken.
10. Macro recursion depth never exceeds 100 and template
    include/extends nesting never exceeds 10.
11. Tests never use syntax outside the grammar above, even where Jinja2
    would accept it (conditional expressions, slices, dict or tuple
    literals, trailing commas, exponent number literals such as `1e3`,
    dotted filter names, `{% raw %}`, `{%+`/`+%}`, `is` tests other than
    `defined`, `loop` members other than the five listed (and `loop`
    itself is never printed, compared or passed to a filter), `{% set %}`
    block form, `extends` inside `if`, integer attribute names such as
    `x.0`, adjacent string literals, keyword or extra arguments to
    filters, a call directly after a filter, string escapes other than the
    five listed, keywords as `set`/`for`/`macro` names, `*args`/`**kwargs`
    splats, ...). Every `error: syntax` test is a template that Jinja2
    also rejects. Likewise `*` is never applied to a list, the left
    operand of `%` is never a string, `<` `<=` `>` `>=` are never applied
    to lists, and no filter is applied to a value kind for which the table
    above does not define a result.

## Sizes and performance

The largest tests: a context of about 1 MB, a loop over 20 000 items
printing several filtered values per item (output ~1 MB), nested loops
with ~50 000 iterations in total, a 1 MB template body with ~50 000 tags,
and macro-based recursive rendering of a tree with a few thousand nodes.
(The long benchmark tier goes further: contexts of up to 28 MB, about
17,000 products with 5,000 featured lookups, 10,000 x 24 sales series,
and 190 trees.)
A straightforward tree-walking interpreter in a compiled language finishes
every test in well under a second; the reference implementation (in
Python) takes under a second on each. Suggested per-test timeout: 30 seconds.
