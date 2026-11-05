# buildsys — Kiln, an incremental build system

Kiln is a build system. It reads a *workspace* — a directory containing build
files written in the **Kiln Build Language** (KBL) and ordinary source files —
evaluates the build files into a graph of build *steps*, and executes the steps
that are out of date on a simulated set of parallel workers against a virtual
file system. Nothing is ever executed by a real shell: Kiln's sixteen built-in
commands are implemented by the engine itself, and every command has an integer
*cost* that drives a fully deterministic scheduling simulation.

Your program drives a whole *session*: a scripted sequence of builds and
workspace mutations. It writes a log of everything that happened and the final
state of the workspace.

Nothing here is Make, Ninja, Bazel, CMake, Meson, Buck, Shake, Please, Tup or
Jam. The syntax, the file formats, the command set, the hash, the state file,
the error messages and the scheduler are all defined only by this document.
Where this document is silent, the behaviour is unconstrained — but that
situation never occurs in the test suite, because the test suite only contains
inputs this document fully determines.

## Contents

1. [I/O contract](#io-contract)
2. [The workspace](#the-workspace)
3. [Bytes, strings and lines](#bytes-strings-and-lines)
4. [Content hashing](#content-hashing)
5. [session.txt](#sessiontxt)
6. [KBL: lexical structure](#kbl-lexical-structure)
7. [KBL: grammar](#kbl-grammar)
8. [KBL: values](#kbl-values)
9. [KBL: expressions](#kbl-expressions)
10. [KBL: string literals and interpolation](#kbl-string-literals-and-interpolation)
11. [KBL: glob patterns](#kbl-glob-patterns)
12. [KBL: built-in functions](#kbl-built-in-functions)
13. [KBL: statements and scoping](#kbl-statements-and-scoping)
14. [Steps, targets and the graph](#steps-targets-and-the-graph)
15. [The command set](#the-command-set)
16. [Depfiles and discovered dependencies](#depfiles-and-discovered-dependencies)
17. [The state file](#the-state-file)
18. [Change detection](#change-detection)
19. [The scheduler](#the-scheduler)
20. [The build algorithm](#the-build-algorithm)
21. [Errors](#errors)
22. [log.txt](#logtxt)
23. [Worked examples](#worked-examples)
24. [Guarantees](#guarantees)
25. [Architecture and size](#architecture-and-size)
26. [Limits and performance](#limits-and-performance)

---

## I/O contract

This is a **directory-mode** problem as defined by `CONVENTIONS.md`. The program
is invoked with exactly two arguments:

```
<command> <input directory> <output directory>
```

Nothing is read from standard input. Anything written to standard output or
standard error is ignored. The exit code must be `0`, for every input in the
suite, including the inputs whose sessions contain build errors: a build error
is normal, expected output, not a program failure.

The input directory contains:

```
<input>/
    session.txt        required — the session script
    main.kiln          the root build file (see note below)
    <anything else>    the initial workspace
```

The output directory already exists and is empty (an implementation may also
create it if it is missing). The program writes exactly this into it and
nothing anywhere else:

```
<output>/
    log.txt            the session log
    workspace/<path>   every file of the final workspace, at its workspace path
```

- `log.txt` is described in [log.txt](#logtxt).
- `workspace/` is a faithful copy of the final virtual file system: for every
  file at workspace path `p`, a file at `<output>/workspace/p` with exactly the
  same bytes. Intermediate directories are created as needed. No other files
  are written; in particular an empty workspace produces an empty (or absent)
  `workspace/` directory.

`main.kiln` is not required to be present in the input: a session may `create`
it, and a build with no `main.kiln` is a defined error.

No external data files are needed. `problems/buildsys/data/` exists but is
empty; every test input is self-contained.

---

## The workspace

The **workspace** is a flat map from *workspace paths* to file contents. It is
loaded from the input directory at the start of the session and mutated by the
session; directories have no independent existence — a path's parent
directories are implied by the path.

### Workspace paths

A workspace path is a non-empty sequence of *components* joined by `/`:

```
path      = component { "/" component } ;
component = (1..255 of pchar) ;
pchar     = "A".."Z" | "a".."z" | "0".."9" | "_" | "." | "+" | "-" ;
```

and additionally:

- no component is `.` or `..`;
- the whole path is at most 1024 bytes;
- there is no leading `/`, no trailing `/` and no empty component.

Note that `*`, `?`, `[`, `]`, `@`, space and `/` cannot occur inside a
component, so glob metacharacters never need escaping and a path can never be
confused with a phony target name (which always starts with `@`).

A string that is not a workspace path, used where one is required, is the error
[`E_BAD_PATH`](#e_bad_path).

### Loading the workspace

The input directory is walked recursively. Every regular file found becomes a
workspace entry whose path is the file's path relative to the input directory,
with `/` as the separator, except:

- `session.txt` at the top level, which is the session script and is **not**
  part of the workspace;
- nothing else is excluded — dot files, `.kiln-state`, anything.

Symbolic links, empty directories, and files whose relative path is not a
workspace path never occur in the test suite.

### The reserved `out` tree and the state file

Two parts of the workspace are reserved:

- **`out/…`** — every path whose first component is exactly `out` is a
  *generated* path. Every output of every step must be a generated path
  ([`E_OUTPUT_PATH`](#e_output_path) otherwise), `glob` never matches a
  generated path, and `clean` deletes every generated path.
- **`.kiln-state`** — the single top-level file in which Kiln persists its
  build state ([The state file](#the-state-file)). `glob` never matches it.

The initial workspace may contain files under `out/` and may contain
`.kiln-state` (sessions that begin mid-build are legal and occur in the tests).

### Mutating the workspace

Only the session script and the execution of commands change the workspace.
Writing a file replaces its content entirely and creates it if absent; deleting
a file removes the entry. Each file also carries a *modification stamp*, which
the session's `touch` step updates and which Kiln never records, compares or
prints — change detection is purely content based, so `touch` can never cause a
rebuild.

---

## Bytes, strings and lines

**All strings are byte strings.** Source files are UTF-8 and the test suite
contains non-ASCII text, but every operation defined here — `len`, `substr`,
`upper`, comparison, hashing, glob matching, line splitting — is defined on
bytes, never on code points. `upper` and `lower` only ever change the 26 ASCII
letters.

### Lines of a file

The **lines** of a byte string `c` are defined as:

- if `c` is empty, there are no lines;
- otherwise, split `c` at every `0x0A` byte; if the final piece is empty (i.e.
  `c` ends with `0x0A`), discard that final empty piece. The remaining pieces,
  in order, are the lines. A line never contains `0x0A`. A line may contain
  `0x0D` — carriage returns are ordinary content and are never stripped.

So `"a\nb\n"` has lines `["a", "b"]`; `"a\nb"` has lines `["a", "b"]`;
`"a\n\nb\n"` has lines `["a", "", "b"]`; `"\n"` has lines `[""]`; `""` has no
lines.

Whenever a command is specified as producing lines, the output content is the
concatenation of each produced line followed by one `0x0A` byte. Commands that
produce lines therefore always emit content that is empty or ends with a
newline.

---

## Content hashing

Every content hash in Kiln is a **64-bit FNV-1a** hash, printed as exactly 16
lowercase hexadecimal digits with leading zeros.

```
hash(bytes):
    h = 0xcbf29ce484222325
    for each byte b of bytes, in order:
        h = h XOR b                       # b is 0..255, zero-extended
        h = (h * 0x100000001b3) mod 2^64
    return h
```

The empty byte string hashes to `cbf29ce484222325`. `"hello\n"` hashes to
`a9bc80cca21f28b3`. `"abc\n"` hashes to `fc17b183ee074373`.

Hashes are only ever used for equality comparison and for printing (in the
state file and by the `hash` command).

---

## session.txt

`session.txt` is UTF-8 text with `0x0A` line endings. It is a sequence of
*session steps*. Lines are read one at a time:

- A line that is empty or whose bytes are all spaces and tabs is skipped.
- A line whose first non-space, non-tab byte is `#` is skipped (a comment).
- Any other line begins a session step and must match one of the forms below.
  Leading and trailing spaces and tabs on the line are stripped first; the
  remainder is split into *words* on runs of spaces and tabs.

Blank and comment lines are **not** skipped inside a content block (see
`create` / `edit`).

### `build`

```
build [TARGET ...] [-j N]
```

The first word is `build`. The remaining words are targets, except that if the
second-to-last word is exactly `-j` then the last word is a decimal integer
`N` (the worker count) and neither is a target. If `-j` is absent, `N` is 1.
Targets are taken in the order written; duplicates are allowed. A target is
either a workspace path or `@` followed by a phony target name.

Runs a build. See [The build algorithm](#the-build-algorithm).

### `create` and `edit`

```
create PATH
<content line>
<content line>
...
---
```

The step line has exactly two words. Every following line, up to but not
including the first line whose entire content is exactly `---`, is a *content
line*. Content lines are taken verbatim: nothing is stripped from them, so
leading and trailing spaces and tabs are part of the content. The new content of `PATH` is the concatenation of each content line
followed by one `0x0A` byte; with zero content lines the new content is empty.

`edit` is written and behaves identically to `create`. The two spellings differ
only in intent and in the header line written to the log: in every test,
`create` names a path that does not currently exist and `edit` names a path
that does.

A `create` or `edit` whose path's first component is `out` is allowed; it is how
tests check that a hand-modified output is rebuilt.

### `delete`

```
delete PATH
```

Removes `PATH` from the workspace. In every test the path exists.

### `touch`

```
touch PATH
```

Updates `PATH`'s modification stamp and nothing else. In every test the path
exists. Because Kiln is content based, this must never cause a rebuild.

### `clean`

```
clean
```

Removes, from the workspace, every path whose first component is `out`, and
also removes `.kiln-state` if present. Nothing else is touched. No build files
are read, so `clean` succeeds even when the build files are broken.

### Example

```
# build everything, then poke at it
build @all -j 4
touch src/a.txt
build @all -j 4
edit src/a.txt
line one
line two
---
build @all -j 2
delete src/b.txt
build @all
clean
build @all -j 8
```

---

## KBL: lexical structure

A build file is UTF-8 text with `0x0A` line endings. It is read in three stages:
comment stripping, logical-line assembly, tokenisation.

### Stage 1 — comment stripping

Each *physical line* (the text between `0x0A` bytes; the last physical line may
be unterminated) is scanned left to right by the **literal scanner**, which all
three stages share so that they can never disagree about what is inside a
string literal:

- Outside a string literal, `"` opens a double-quoted literal and `'` opens a
  single-quoted literal.
- Inside a single-quoted literal, `''` is two bytes of content and a single `'`
  closes it.
- Inside a double-quoted literal:
  - `\` consumes the next byte unconditionally;
  - `{{` and `}}` are two bytes of content;
  - `{` opens an **interpolation region**. Inside such a region, a brace depth
    starts at 1; `"` and `'` open nested string literals which the scanner
    skips by these same rules; outside those nested literals, `{` increments the
    depth and `}` decrements it, and the region ends at the `}` that brings the
    depth to 0;
  - a `}` that is not part of `}}` and does not close an interpolation region
    is, *to the scanner*, an ordinary byte of content: the scanner's only job
    is to find where literals and comments end. The string-literal reader
    rejects such a `}` later, when the literal is parsed (see
    [string literals](#kbl-string-literals-and-interpolation)), so the error is
    attributed to the logical line the literal ends up on;
  - `"` closes the literal — but only when the scanner is not inside an
    interpolation region, nor inside a literal nested in one.
- A string literal may not contain a raw `0x0A`: if the scanner reaches the end
  of the physical line while inside a literal, or inside an interpolation region
  of one, that is [`E_PARSE`](#e_parse).
- Outside a string literal, `#` begins a comment: the `#` and everything after
  it on that physical line is discarded. A `#` inside a string literal,
  including inside an interpolation region, is ordinary content.

After stripping, trailing spaces and tabs are removed from each physical line.

So `cmd write("{join(xs, ", ")}\n")` is one `cmd` field whose single argument is
one double-quoted literal: the inner `", "` is a nested literal inside the
interpolation region and does not close the outer one.

### Stage 2 — logical-line assembly

Physical lines are grouped into *logical lines*. A running *bracket depth*
starts at 0 for each logical line. Scanning the physical lines of the group in
order with the literal scanner of stage 1, outside string literals (and so also
outside interpolation regions, whose brackets never count), each `(` or `[`
adds 1 and each `)` or `]`
subtracts 1. Braces `{` and `}` never affect the depth.

- If the depth becomes negative at any point, that is `E_PARSE`.
- If the depth is 0 at the end of a physical line, the logical line ends there.
- Otherwise the next physical line joins the same logical line, appended after
  a single space (`0x20`).
- If the end of file is reached with depth greater than 0, that is `E_PARSE`.

A logical line whose text is empty or all spaces and tabs is discarded. The
**line number** of a logical line is the 1-based number of its first physical
line; this is the number reported by `E_PARSE` for any error attributed to that
logical line.

Stages 1 and 2 are one pass over the physical lines: each physical line is
scanned once, which both finds its comment and updates the bracket depth. Every
`E_PARSE` either stage raises — an unterminated literal, a negative bracket
depth, a bracket still open at end of file — is reported at the **line number of
the logical line being assembled**, which is the first physical line of the
group, not the physical line the scanner was on. So

```
let b = f(
  "unterminated
)
```

is `E_PARSE <file>:1`.

### Stage 3 — tokenisation

A logical line is split into tokens. Spaces and tabs separate tokens and are
otherwise insignificant. The token kinds are:

| Kind | Form |
|------|------|
| identifier | `[A-Za-z_][A-Za-z0-9_]*` |
| integer | `[0-9]+` (leading zeros allowed; value is decimal) |
| string | a double-quoted or single-quoted literal (see [below](#kbl-string-literals-and-interpolation)) |
| punctuation | `( ) [ ] { } , =` |
| operator | `|> || && == != <= >= < > ++ ~ + - * / % !` |

Operators are matched longest-first, so `||` beats `|`, `++` beats `+`, `<=`
beats `<`, and `|>` is a single token. A bare `|` or `&` is `E_PARSE`. Any other
byte outside a string literal is `E_PARSE`.

The following identifiers are **reserved words** and may not be used as
variable names, parameter names, rule names or loop variables:

```
abort   after   cmd     cost    default  depfile  each     elsewhen
false   in      include let     otherwise out     phony    rule
set     step    true    use     when
```

Reserved words may still be used as built-in function names and as command
names — those are separate namespaces, and none of the built-in functions or
commands is spelled like a reserved word anyway.

Precisely: wherever the grammar requires an `IDENT`, a reserved word is
`E_PARSE`, with these exceptions, which are name positions in a namespace of
their own:

- the name of a call: an identifier immediately followed by `(`, and every
  `|>` target, with or without an argument list (so `1 |> cost` is
  `E_UNKNOWN_FUNC cost`, not `E_PARSE`);
- the command name of a `cmd` field;
- the rule name of a `use` statement.

Because no built-in function, command or declarable rule has a reserved word's
spelling, those three cases always end in `E_UNKNOWN_FUNC`, `E_UNKNOWN_CMD` or
`E_UNKNOWN_RULE` rather than `E_PARSE`. `true` and `false` are reserved words
that are also the two `bool` literals and are of course accepted as primaries —
unless immediately followed by `(`, in which case they are call names like any
other reserved word. Everywhere else — a variable reference, a `let` / `set` /
`phony` name, a `rule` name being defined, a parameter name, a loop variable, a
keyword-argument name — a reserved word is `E_PARSE`. A `|>` target is never in this
list: it is always a call name.

### Which `E_PARSE` is reported

A file may contain several syntax errors; exactly one is reported, chosen like
this:

1. **Lexical errors first.** Stages 1–3 run over the whole file before any
   parsing: the physical lines are scanned in order, and each logical line is
   tokenised as soon as it is complete. The lexical errors are an unterminated
   literal, a negative bracket depth, a bracket still open at end of file, and
   a byte that cannot begin a token (including a bare `|` or `&`). If the file
   has any, the one belonging to the earliest logical line is reported, even
   when an earlier logical line also has a grammar error.
2. **Then the first grammar error in file order.** Otherwise the logical lines
   are parsed in order, and the error reported is the one on the first logical
   line that cannot be parsed in its context. Everything inside a string
   literal — a bad escape, a lone `}`, an empty interpolation, and any token or
   grammar error inside an interpolation body — is a grammar error of the
   logical line containing the literal, not a lexical error.
3. **Unterminated blocks last.** A missing terminator is only discovered at end
   of file, so it is reported only when no logical line of the file has any
   other error; it is then reported at the innermost open block's header.

So a file whose line 1 is `let = 1` and whose line 2 is `let x = "abc` reports
`E_PARSE <file>:2`.

### Block layout

KBL uses braces for blocks, but constrains where they may appear so that the
structure of a file is determined by its logical lines:

- A logical line whose **last** token is `{` is a **block header**. Its other
  tokens must form one of exactly four shapes: `step`, `when EXPR`,
  `each IDENT [, IDENT] in EXPR`, or `rule IDENT ( params )`.
- A logical line whose **first** token is `}` is a **block terminator**. It must
  be exactly one of:
  - `}` — closes the innermost open block;
  - `} elsewhen EXPR {` — closes a `when` or `elsewhen` block and opens the next;
  - `} otherwise {` — closes a `when` or `elsewhen` block and opens an
    `otherwise` block.
- A `{` or `}` token anywhere else is `E_PARSE`.
- Every other logical line is a **simple statement**.
- A block header with no matching terminator at end of file is `E_PARSE`,
  reported at the header's line number. When several blocks are still open at
  end of file, the **innermost** one (the most recently opened) is reported. A `} elsewhen EXPR {` or `} otherwise {`
  line is itself a block header, so when *its* body runs to end of file the
  error is reported at that line.
- A block terminator with no open block is `E_PARSE`, reported at the
  terminator's own line number, and so is every other malformed terminator:
  `} elsewhen` or `} otherwise` closing a block that is not a `when` or
  `elsewhen` block, `} elsewhen` after `} otherwise`, a second `} otherwise`,
  and anything else following a `}` that is not one of the two accepted forms
  (for example `} foo`).
- A logical line whose only token is `{` is neither a header (its other tokens
  form none of the four shapes) nor a terminator, so it is `E_PARSE`.

Example:

```
rule bundle(name, parts) {
    step {
        out "out/{name}.txt"
        in parts
        cmd concat()
    }
}
when count(parts) > 3 {
    default ["out/big.txt"]
} elsewhen count(parts) > 0 {
    default ["out/small.txt"]
} otherwise {
    abort "nothing to build"
}
```

---

## KBL: grammar

Terminals are written in `UPPERCASE` (token kinds) or quoted. `NL` is implicit:
every production below that is marked *(line)* occupies exactly one logical
line; every production marked *(header)* is a block header; the matching
terminator is a block-terminator logical line.

```ebnf
file            = { statement } ;

statement       = let_stmt | set_stmt | include_stmt | abort_stmt
                | default_stmt | phony_stmt | use_stmt
                | when_stmt | each_stmt | rule_stmt | step_stmt ;

(* simple statements, one logical line each *)
let_stmt        = "let" IDENT "=" expr ;                        (* line *)
set_stmt        = "set" IDENT "=" expr ;                        (* line *)
include_stmt    = "include" expr ;                              (* line *)
abort_stmt      = "abort" expr ;                                (* line *)
default_stmt    = "default" expr ;                              (* line *)
phony_stmt      = "phony" IDENT "=" expr ;                      (* line *)
use_stmt        = "use" IDENT "(" [ arg_list ] ")" ;            (* line *)

arg_list        = arg { "," arg } [ "," ] ;
arg             = expr | IDENT "=" expr ;

(* block statements *)
when_stmt       = "when" expr "{" { statement }
                  { "}" "elsewhen" expr "{" { statement } }
                  [ "}" "otherwise" "{" { statement } ]
                  "}" ;
each_stmt       = "each" IDENT [ "," IDENT ] "in" expr "{"      (* header *)
                      { statement }
                  "}" ;
rule_stmt       = "rule" IDENT "(" [ param_list ] ")" "{"       (* header *)
                      { statement }
                  "}" ;
param_list      = param { "," param } [ "," ] ;
param           = IDENT [ "=" expr ] ;
step_stmt       = "step" "{"                                    (* header *)
                      { step_field }
                  "}" ;

step_field      = "out" expr                                    (* line *)
                | "in" expr                                     (* line *)
                | "after" expr                                  (* line *)
                | "cost" expr                                   (* line *)
                | "depfile" expr                                (* line *)
                | "cmd" IDENT "(" [ expr { "," expr } [ "," ] ] ")" ; (* line *)

(* expressions, lowest precedence first *)
expr            = pipe_expr ;
pipe_expr       = or_expr { "|>" pipe_target } ;
pipe_target     = IDENT [ "(" [ expr { "," expr } [ "," ] ] ")" ] ;
or_expr         = and_expr { "||" and_expr } ;
and_expr        = cmp_expr { "&&" cmp_expr } ;
cmp_expr        = cat_expr { ( "==" | "!=" | "<" | "<=" | ">" | ">=" ) cat_expr } ;
cat_expr        = str_expr { "++" str_expr } ;
str_expr        = add_expr { "~" add_expr } ;
add_expr        = mul_expr { ( "+" | "-" ) mul_expr } ;
mul_expr        = unary_expr { ( "*" | "/" | "%" ) unary_expr } ;
unary_expr      = [ "!" | "-" ] unary_expr | postfix_expr ;
postfix_expr    = primary { "(" [ expr { "," expr } [ "," ] ] ")" | "[" expr "]" } ;
primary         = INT | STRING | "true" | "false" | IDENT
                | "(" expr ")"
                | "[" [ expr { "," expr } [ "," ] ] "]" ;
```

An `arg` in a `use_stmt` is a **keyword argument** exactly when its first token
is an identifier that is not a reserved word and its second token is the
punctuation `=`; otherwise it is a positional argument, parsed as an `expr`.
(`==` is a single token, so `f(a == b)` is positional.) A `param` is likewise
recognised by an identifier optionally followed by `=` and a default `expr`.

All binary operators are left-associative. A call `f(...)` is only legal when
`f` is an identifier naming a built-in function — there are no first-class
functions and no user-defined functions, so `postfix_expr` applies a call only
to an identifier primary; a call applied to anything else is `E_PARSE`.
Indexing `x[i]` applies to any expression.

Any logical line that does not match one of the productions above, in the
context where it appears, is `E_PARSE`. In particular:

- a `step_field` outside a `step` block is `E_PARSE`;
- a statement other than a `step_field` inside a `step` block is `E_PARSE`;
- trailing tokens after a complete statement are `E_PARSE`;
- a positional argument after a keyword argument in a `use_stmt` arg list is
  `E_PARSE`;
- a duplicated parameter name in a `rule_stmt` parameter list is `E_PARSE`;
- a `param` without a default following a `param` with a default is `E_PARSE`.

---

## KBL: values

A KBL value is one of:

| Type token | Values |
|------------|--------|
| `str` | a byte string |
| `int` | a signed 64-bit integer |
| `bool` | `true` or `false` |
| `list` | an ordered sequence of values (elements may be of any type, including `list`) |

Integer arithmetic is on signed 64-bit two's-complement integers and wraps on
overflow. No test overflows. `/` truncates toward zero; `a % b` has the sign of
`a` and satisfies `a == (a / b) * b + (a % b)`. Division or modulo by zero is
[`E_DIV_ZERO`](#e_div_zero).

### The total order

Values are totally ordered; this order drives `<`, `<=`, `>`, `>=` and `sort`.

1. Across types: `bool` < `int` < `str` < `list`.
2. Two `bool`s: `false` < `true`.
3. Two `int`s: numerically.
4. Two `str`s: by unsigned byte comparison; if one is a prefix of the other,
   the shorter is smaller.
5. Two `list`s: element by element using this same order; the first differing
   pair decides; otherwise the shorter list is smaller.

Equality (`==`, `!=`, `uniq`, `has`, `indexof`) is deep structural equality:
values of different types are never equal; lists are equal when they have the
same length and corresponding elements are equal.

---

## KBL: expressions

Precedence, lowest binding first:

| Level | Operators | Operand types | Result |
|-------|-----------|---------------|--------|
| 1 | `\|>` | see below | see below |
| 2 | `\|\|` | `bool`, `bool` | `bool` |
| 3 | `&&` | `bool`, `bool` | `bool` |
| 4 | `==` `!=` | any, any | `bool` |
| 4 | `<` `<=` `>` `>=` | any, any | `bool` |
| 5 | `++` | `list`, `list` | `list` |
| 6 | `~` | `str`, `str` | `str` |
| 7 | `+` `-` | `int`, `int` | `int` |
| 8 | `*` `/` `%` | `int`, `int` | `int` |
| 9 | unary `!` | `bool` | `bool` |
| 9 | unary `-` | `int` | `int` |
| 10 | `f(...)`, `x[i]` | — | — |

An operand of the wrong type is [`E_TYPE`](#e_type) with site `operator <op>`
(for unary `-` the site is `operator -` and for unary `!` it is `operator !`).
Apart from the short-circuit operators below, a binary operator evaluates its
left operand, then its right operand, and then checks the left operand's type
before the right's, so `"a" + [1]` is
`E_TYPE operator +: expected int, got str`.

- `||` and `&&` **short-circuit**: the left operand is evaluated and must be
  `bool`; if `||`'s left operand is `true`, or `&&`'s left operand is `false`,
  the right operand is not evaluated at all (so it cannot raise an error).
- `~` concatenates two byte strings. It never converts; use interpolation or
  `str()` for numbers.
- `++` concatenates two lists.
- `a |> f(b, c)` means exactly `f(a, b, c)`. `a |> f` means `f(a)`. The right
  operand of `|>` must be an identifier, optionally applied to an argument
  list; anything else is `E_PARSE`. `|>` is left-associative, so
  `x |> f |> g(1)` is `g(f(x), 1)`.
- `x[i]` evaluates `x`, then `i`; it then requires `i` to be `int`
  ([`E_TYPE`](#e_type) site `index` otherwise) and only then `x` to be `str` or
  `list` (site `index target`), so `5["a"]` is
  `E_TYPE index: expected int, got str`. A negative `i` counts
  from the end (`-1` is the last element). An index outside
  `-len(x) .. len(x)-1` is [`E_ARG`](#e_arg) `fn index: out of range`. Indexing
  a `str` yields a one-byte `str`.

---

## KBL: string literals and interpolation

### Single-quoted literals

A single-quoted literal is `'`, then content, then `'`. The only escape is `''`,
which denotes one `'`. There is no interpolation and no other escape
processing: `'a\nb{x}'` is the seven bytes `a\nb{x}`.

### Double-quoted literals

A double-quoted literal is `"`, then a sequence of *parts*, then `"`. Scanning
the content:

- `\` followed by one of `\ " n t r 0` produces, respectively, `\`, `"`, `0x0A`,
  `0x09`, `0x0D`, `0x00`. `\` followed by anything else is `E_PARSE`.
- `{{` produces one literal `{`; `}}` produces one literal `}`.
- `{` begins an **interpolation**. Scan forward for the matching `}`: maintain a
  brace depth starting at 1; outside string literals, `{` increments it and `}`
  decrements it, and the interpolation body ends at the `}` that brings the
  depth to 0. While scanning, `'` and `"` open nested string literals which are
  skipped with the same rules as stage 1 of lexing (so an interpolation body may
  contain string literals, and braces inside them are not counted). Reaching the
  end of the literal without closing the interpolation is `E_PARSE`; so is an
  empty body — one that tokenises to no tokens, which covers both `"{}"` and
  `"{ }"`. The body is then tokenised and parsed as a complete `expr`; leftover
  tokens are `E_PARSE`. The body is parsed when the enclosing file is parsed,
  whether or not the literal is ever evaluated.
- A `}` that is not part of `}}` and not closing an interpolation is `E_PARSE`.
- Any other byte, including `#`, `0x09` and bytes ≥ 0x80, stands for itself.

Evaluating a double-quoted literal concatenates its parts in order. A literal
part contributes its bytes. An interpolation part evaluates its expression and
contributes:

| Type | Contribution |
|------|--------------|
| `str` | its bytes |
| `int` | its decimal representation, with a leading `-` when negative |
| `bool` | `true` or `false` |
| `list` | [`E_INTERP`](#e_interp) `list` |

Examples (with `n = 7`, `xs = ["a","b"]`):

| Literal | Value |
|---------|-------|
| `"out/x{n}.txt"` | `out/x7.txt` |
| `"{n * 2 + 1}"` | `15` |
| `"{{literal}}"` | `{literal}` |
| `"{xs[0]}-{xs[1]}"` | `a-b` |
| `"{len(xs) == 2}"` | `true` |
| `"{join(xs, ", ")}"` | `a, b` |
| `"{xs}"` | error `E_INTERP list` |

---

## KBL: glob patterns

A glob pattern is used by `glob`, `filter` and `reject`. It is matched against a
whole candidate string, which is treated as `/`-separated components.

### Pattern syntax

A pattern is split on `/` into pattern components. The pattern is **malformed**
— [`E_ARG`](#e_arg) `fn <name>: bad pattern` — if it is empty, has a leading or
trailing `/`, has an empty component, or contains a malformed character class.
A component is one of:

- `**` (exactly those two bytes) — matches zero or more whole components;
- otherwise a sequence of items, each of which is:
  - `*` — matches zero or more bytes other than `/`;
  - `?` — matches exactly one byte other than `/`;
  - `[` … `]` — a character class;
  - any other byte — matches itself.

A character class is `[`, an optional `!`, then one or more *items*, then `]`.
Each item is either `X-Y` (two bytes separated by `-`, matching any byte `b`
with `X ≤ b ≤ Y`; `X > Y` is malformed) or a single byte other than `]`. A
class with `!` matches exactly the bytes its item set does not. An unterminated
class, or a class with no items (`[]`, `[!]`), is malformed.

Items are scanned left to right by exactly this algorithm, starting just after
the `[` and the optional `!`:

- if there is no byte left, the class is malformed (unterminated);
- if the current byte is `]`, the class ends here; it is malformed if no item
  was collected;
- otherwise, if the next two bytes exist, the next byte is `-`, and the byte
  after that is not `]`, the three bytes are a range item `X-Y` (malformed when
  `X > Y`) and scanning advances by 3;
- otherwise the current byte is a single-byte item and scanning advances by 1.

So `*`, `?` and `-` inside a class are ordinary bytes whenever the algorithm
reaches them as single-byte items: `[-a]` matches `-` or `a`, `[a-]` matches `a`
or `-`, `[a-z]` is a range, and `[*?]` matches `*` or `?`.

### Matching

The candidate is split at **every** `/` byte into components, and empty
components are kept: `""` is one empty component, `x/` is the two components
`x` and `""`, `/x` is `""` and `x`, and `a//b` is `a`, `""` and `b`. An empty
candidate component is matched like any other, so `*` and `**` match `""`,
`?` does not, and `*` does not match `a//b` (three components). Only `filter`
and `reject` ever see such candidates; workspace paths have no empty
components.

Matching is greedy-independent: the pattern matches the candidate iff there is
*some* assignment of components to `**` segments and bytes to `*`/`?` items
that consumes both exactly. (A straightforward recursive or dynamic-programming
matcher is correct; the relation is purely declarative.) Each non-`**` pattern
component must match exactly one candidate component, and matching inside a
component never crosses a `/`.

Examples:

| Pattern | Matches | Does not match |
|---------|---------|----------------|
| `src/*.txt` | `src/a.txt`, `src/.txt` | `src/sub/a.txt`, `a.txt` |
| `src/**` | `src/a.txt`, `src/x/y/z.txt`, `src` | `other/a.txt`, `srcx` |
| `**/*.txt` | `a.txt`, `src/a.txt`, `a/b/c.txt` | `a.text` |
| `src/**/t_*.txt` | `src/t_1.txt`, `src/a/b/t_2.txt` | `src/t.txt` |
| `src/?.txt` | `src/a.txt` | `src/ab.txt` |
| `src/[ab]*.txt` | `src/a1.txt`, `src/b.txt` | `src/c.txt` |
| `src/[!ab]*.txt` | `src/c.txt` | `src/a.txt` |
| `src/[0-9].txt` | `src/7.txt` | `src/x.txt` |
| `a**b` | `axyzb`, `ab` | `a/b` |

Because `**` matches *zero* or more components, `src/**` matches the single
component `src` as well as everything beneath it, and `**/*.txt` matches
`a.txt` as well as `src/a.txt`. A `**` is only a component wildcard when the
whole pattern component is exactly those two bytes; `a**b` is one ordinary
component holding two `*` items, which is why it cannot match across a `/`.

### `glob`

`glob(pattern)` returns the sorted list of workspace paths `p` such that:

1. a file exists at `p` in the workspace at the moment the call is evaluated;
2. `p`'s first component is not `out`;
3. `p` is not `.kiln-state`;
4. `pattern` matches `p`.

The result is sorted ascending by the `str` total order (byte order). Duplicates
are impossible. An empty result is not an error.

---

## KBL: built-in functions

There are 39 built-in functions. They are the only callable things in KBL.
Calling an unknown name is [`E_UNKNOWN_FUNC`](#e_unknown_func); calling with the
wrong number of arguments is [`E_ARITY`](#e_arity) with kind `fn`. An argument
of the wrong type is [`E_TYPE`](#e_type) with site `fn <name> argument <i>`
(`i` is 1-based).

A call is performed in exactly this order, which fixes which error a bad call
reports:

1. the name is looked up — an unknown name is `E_UNKNOWN_FUNC` and **no
   argument is evaluated**, so `nope(undefined)` is `E_UNKNOWN_FUNC nope`;
2. the argument expressions are evaluated left to right, so an error inside an
   argument beats the arity check: `upper(undefined, 2)` is `E_UNKNOWN_VAR`;
3. the argument count is checked (`E_ARITY`);
4. the argument types are checked in ascending argument order (`E_TYPE`);
5. the function runs, and raises its own `E_ARG` or `E_TYPE … element <i>`
   errors.

In the table, `S` = `str`, `I` = `int`, `B` = `bool`, `L` = `list`, `V` = any.

| Signature | Result | Notes |
|-----------|--------|-------|
| `len(V: S\|L)` | `I` | byte length of a string, element count of a list |
| `count(L)` | `I` | element count; `list` only |
| `upper(S)` | `S` | ASCII `a`–`z` → `A`–`Z`, other bytes unchanged |
| `lower(S)` | `S` | ASCII `A`–`Z` → `a`–`z`, other bytes unchanged |
| `trim(S)` | `S` | remove leading and trailing bytes `0x20`, `0x09`, `0x0A`, `0x0D` |
| `replace(S, S, S)` | `S` | see below |
| `starts_with(S, S)` | `B` | byte prefix test; empty prefix → `true` |
| `ends_with(S, S)` | `B` | byte suffix test; empty suffix → `true` |
| `contains(S, S)` | `B` | byte substring test; empty needle → `true` |
| `substr(S, I, I)` | `S` | see below |
| `split(S, S)` | `L` of `S` | see below |
| `join(L, S)` | `S` | see below |
| `str(V: S\|I\|B)` | `S` | same text as interpolation produces |
| `int(V: S\|I)` | `I` | see below |
| `dirname(S)` | `S` | text before the last `/`; `""` if there is no `/` |
| `basename(S)` | `S` | text after the last `/`; the whole string if there is no `/` |
| `stem(S)` | `S` | see below |
| `ext(S)` | `S` | see below |
| `pathjoin(S, …)` | `S` | 1 to 8 arguments; see below |
| `map(L, S)` | `L` of `S` | see below |
| `filter(L, S)` | `L` | keep elements matching the glob pattern |
| `reject(L, S)` | `L` | keep elements not matching the glob pattern |
| `sort(L)` | `L` | ascending by the total order |
| `uniq(L)` | `L` | keep the first occurrence of each distinct value, order preserved |
| `reverse(L)` | `L` | elements in reverse order |
| `first(L)` | `V` | element 0; empty list → `E_ARG fn first: empty list` |
| `last(L)` | `V` | last element; empty list → `E_ARG fn last: empty list` |
| `slice(L, I, I)` | `L` | same clamping rules as `substr` |
| `has(L, V)` | `B` | deep equality membership |
| `indexof(L, V)` | `I` | index of the first deep-equal element, else `-1` |
| `range(I)` | `L` of `I` | `[0, 1, …, n-1]`; `n = 0` → `[]`; `n < 0` → `E_ARG fn range: negative` |
| `sum(L)` | `I` | every element must be `int` (site `fn sum element <i>`); empty → `0` |
| `flatten(L)` | `L` | one level: each `list` element is spliced in, others kept |
| `zip(L, L)` | `L` of `L` | `[[a0,b0], [a1,b1], …]`, length `min(len(a), len(b))` |
| `is_str(V)` | `B` | |
| `is_int(V)` | `B` | |
| `is_bool(V)` | `B` | |
| `is_list(V)` | `B` | |
| `glob(S)` | `L` of `S` | see [glob](#glob) |

### `replace(s, from, to)`

Scan `s` left to right. At each position, if `from` occurs there, emit `to` and
advance by `len(from)`; otherwise emit the current byte and advance by 1.
`from` empty is `E_ARG fn replace: empty pattern`.

### `substr(s, start, count)` and `slice(l, start, count)`

Let `n` be `len(s)` (or the element count). If `start < 0`, set
`start = n + start`. Then clamp `start` to `0 .. n`. Clamp `count` to
`0 .. n - start` (so a negative `count` yields an empty result). Return the
`count` bytes (elements) beginning at `start`. No error is ever raised.

Examples: `substr("abcdef", 1, 3)` = `bcd`; `substr("abcdef", -2, 5)` = `ef`;
`substr("abcdef", 10, 2)` = `""`; `substr("abcdef", 2, -1)` = `""`.

### `split(s, sep)`

`sep` empty is `E_ARG fn split: empty separator`. Repeatedly find the leftmost
occurrence of `sep`; the text before it is a piece, and scanning resumes after
it. The remainder is the final piece. The result always has at least one
element: `split("", ",")` is `[""]`, `split("a,,b", ",")` is `["a", "", "b"]`,
`split("abc", "x")` is `["abc"]`.

### `join(l, sep)`

Elements must be `str` or `int`; anything else is `E_TYPE` with site
`fn join element <i>` (0-based index of the offending element). `int` elements
contribute their decimal form. The pieces are joined with `sep`. `join([], "x")`
is `""`.

### `int(v)`

If `v` is `int`, it is returned unchanged. If `v` is `str`, it must match
`-?[0-9]+` exactly (no spaces, no `+`, at least one digit; leading zeros
allowed) and must fit in a signed 64-bit integer; otherwise
`E_ARG fn int: bad integer`.

### `stem(p)` and `ext(p)`

Let `b = basename(p)`. Find the last `.` in `b` that is not at index 0. If there
is none, `stem(p)` is `b` and `ext(p)` is `""`. Otherwise `stem(p)` is `b` up to
(not including) that `.`, and `ext(p)` is that `.` and everything after it.

| `p` | `basename` | `stem` | `ext` |
|-----|-----------|--------|-------|
| `src/a.txt` | `a.txt` | `a` | `.txt` |
| `src/a.b.txt` | `a.b.txt` | `a.b` | `.txt` |
| `src/a` | `a` | `a` | `""` |
| `src/.hidden` | `.hidden` | `.hidden` | `""` |
| `a.txt` | `a.txt` | `a` | `.txt` |
| `src/x.` | `x.` | `x` | `.` |

### `pathjoin(a, b, …)`

Arguments that are the empty string are dropped. The remaining arguments are
joined with a single `/`. No normalisation, no deduplication of slashes beyond
that, no path validation. `pathjoin("out", "", "a.txt")` is `out/a.txt`;
`pathjoin("out/")` is `out/`.

### `map(l, pat)`

Every element must be `str` (site `fn map element <i>`). For each element,
produce a string by scanning `pat`: `%%` emits one `%`, a single `%` emits the
element, any other byte emits itself. `map(["a","b"], "out/%.o")` is
`["out/a.o", "out/b.o"]`; `map(["a"], "100%%-%")` is `["100%-a"]`.

### `filter(l, pat)` and `reject(l, pat)`

The pattern is compiled first: a malformed pattern is `E_ARG` before any
element is looked at, so `filter([1], "")` is `E_ARG fn filter: bad pattern` and
not an element type error. Then each element, in order, must be `str` (site
`fn filter element <i>` / `fn reject element <i>`, 0-based) and is tested
against the pattern. `filter` keeps the matching elements and `reject` keeps the
rest; both preserve order and keep duplicates.

---

## KBL: statements and scoping

### Scopes

A **scope** is a mutable mapping from variable name to value, with a pointer to
its parent scope. Looking a name up searches the scope then its ancestors; a
name found nowhere is [`E_UNKNOWN_VAR`](#e_unknown_var).

There is one **root scope**, created empty at the start of each build and
destroyed at its end. Child scopes are created by:

- a `when` / `elsewhen` / `otherwise` block (one scope for the branch taken);
- each iteration of an `each` loop (a fresh scope per iteration, holding the
  loop variables);
- each instantiation of a rule (a fresh scope whose **parent is the scope in
  which the `rule` statement was executed**, not the scope containing the `use`;
  it holds the parameters).

`include` does **not** create a scope: the included file's statements run in the
scope containing the `include`.

### `let IDENT = expr`

Evaluates `expr` and binds `IDENT` in the current scope. If `IDENT` is already
bound **in the current scope**, that is [`E_REDEFINE`](#e_redefine). The
expression is evaluated first, so an error raised while evaluating it is
reported instead of `E_REDEFINE`. Shadowing a
binding from an ancestor scope is allowed and is how shadowing is tested.

### `set IDENT = expr`

Evaluates `expr`, then finds the innermost scope (starting from the current one)
that already binds `IDENT` and replaces the value there. If no scope binds it,
that is [`E_SET_UNDEFINED`](#e_set_undefined).

### `include expr`

`expr` must evaluate to `str` (site `include path`) and be a workspace path
([`E_BAD_PATH`](#e_bad_path)). The path is **relative to the workspace root**,
never to the including file. If no file exists at that path, that is
[`E_INCLUDE_MISSING`](#e_include_missing).

The file is lexed, parsed and executed immediately, in the current scope. If the
file is already on the include stack, that is
[`E_INCLUDE_CYCLE`](#e_include_cycle). Including the same file twice *without*
nesting is allowed and executes it twice — which normally raises `E_REDEFINE` on
the second pass, and the tests rely on that.

### `abort expr`

`expr` must evaluate to `str` (site `abort message`). Raises
[`E_ABORT`](#e_abort) with that message.

### `default expr`

`expr` must evaluate to `str` or a `list` whose elements are all `str` (site
`default`; the type token for this combination is `strlist`). Appends those
target names, in order, to the build's default target list. Several `default`
statements accumulate; duplicates are allowed and are deduplicated later.

### `phony IDENT = expr`

Declares a phony target named `IDENT`, referenced everywhere else as
`"@IDENT"`. `IDENT` must additionally match `[A-Za-z_][A-Za-z0-9_]*` — which the
lexer already guarantees — and must not be a reserved word (also guaranteed).
`expr` must be `str` or a list of `str` (site `phony <name>`); those are the
phony target's dependencies, which are **ordering-only** (see
[Steps, targets and the graph](#steps-targets-and-the-graph)).

The statement runs in this order: `expr` is evaluated and type-checked; then
each dependency string is validated, in order, exactly as a step's `in` entries
are: it must be `@` followed by an identifier-shaped name, or a
workspace path, otherwise [`E_BAD_PATH`](#e_bad_path). Whether the referenced
target exists is checked later, during whole-graph validation.

Finally the name is checked: declaring a phony name that is already declared
is [`E_DUP_PHONY`](#e_dup_phony), so an error in the second declaration's
expression or dependency strings is reported instead. Phony names live
in one global table shared by all build files and all rule instantiations.

### `when` / `elsewhen` / `otherwise`

```
when expr {
    …
} elsewhen expr {
    …
} otherwise {
    …
}
```

Each condition is evaluated in turn, in the enclosing scope, and must be `bool`
(site `when condition`). The first `true` branch's body runs in a fresh child
scope; later conditions are not evaluated. If no condition is `true` and an
`otherwise` branch is present, it runs; otherwise nothing runs.

### `each`

```
each name in expr {
    …
}
each index, name in expr {
    …
}
```

`expr` must be a `list` (site `each subject`). For each element, in order, a
fresh child scope is created binding `name` to the element and, in the two-name
form, `index` to the 0-based position as an `int`; the body runs in that scope.
The two names must differ (otherwise `E_PARSE`). A loop over an empty list runs
the body zero times.

### `rule`

```
rule name(p1, p2, p3 = expr) {
    …
}
```

Defines a rule template. The body is *not* executed now; it is stored, together
with the scope in which the `rule` statement ran. The scope is kept by
reference, not copied: bindings added to it by later `let`s, and values
changed in it by later `set`s, are visible to every later instantiation. Rules live in one global table
shared by all build files; defining a rule name twice is
[`E_REDEFINE`](#e_redefine) (with the rule name as the detail). A rule name may
coincide with a variable name — they are separate namespaces.

Parameters without a default must precede parameters with one. Default
expressions are not evaluated at definition time.

### `use`

```
use name(positional, …, kw = expr, …)
```

Instantiates the rule `name`:

0. The rule is looked up. An unknown name is
   [`E_UNKNOWN_RULE`](#e_unknown_rule). A `use` that would make the
   instantiation depth 65 is [`E_RULE_RECURSION`](#e_rule_recursion). Both are
   raised **before any argument expression is evaluated**.
1. All argument expressions are evaluated left to right in the current scope.
2. A new scope is created, whose parent is the rule's stored defining scope.
3. Positional arguments are bound to the parameters in order. More positional
   arguments than parameters is [`E_ARITY`](#e_arity)
   `rule <name>: expected <p>, got <a>`, where `p` is the number of parameters
   and `a` the number of positional arguments.
4. Each keyword argument binds the parameter of that name. An unknown name is
   [`E_ARG`](#e_arg) `rule <name>: unknown argument <kw>`; a parameter already
   bound positionally or by an earlier keyword is `E_ARG rule <name>: duplicate
   argument <kw>`. Keyword arguments are processed in source order.
5. Each still-unbound parameter, in declaration order, is bound by evaluating
   its default expression **in the new scope** (so a default may refer to
   parameters declared before it). A still-unbound parameter with no default is
   `E_ARG rule <name>: missing argument <param>`.
6. The rule body executes in the new scope.

Rule instantiation may nest: a rule body may contain `use`. The outermost `use`
runs at depth 1 and the depth is limited to 64, so the `use` that would run at
depth 65 is [`E_RULE_RECURSION`](#e_rule_recursion) naming the rule it is
entering.

### `step`

```
step {
    out  expr
    in   expr
    after expr
    cmd  name(expr, …)
    cost expr
    depfile expr
}
```

Executing a `step` block creates one build step and appends it to the build's
step list, assigning it the next **serial number** (0, 1, 2, … in order of
creation across the whole build, including steps created inside rules and
loops). Fields may appear in any order and are processed top to bottom:

- `out expr` — `expr` must be `str` or a list of `str` (site `field out`). The
  strings are appended, in order, to the step's declared output list. `out` may
  appear any number of times; at least one output must result, otherwise
  [`E_STEP_FIELD`](#e_step_field) `missing out`.
- `in expr` — same typing (site `field in`); appends to the declared input
  list. May appear any number of times, including zero.
- `after expr` — same typing (site `field after`); appends to the declared
  order-only list. May appear any number of times, including zero.
- `cost expr` — at most once (`E_STEP_FIELD duplicate cost`); then `expr` must
  be `int` (site `field cost`) and ≥ 0 (`E_ARG field cost: negative`). If the
  field is absent, the command's default cost is used.
- `depfile expr` — at most once (`E_STEP_FIELD duplicate depfile`); then `expr`
  must be `str` (site `field depfile`). Whether the string is a workspace path
  under `out/` is checked at the closing brace, with the declared outputs, not
  here.
- `cmd name(args)` — exactly once (`E_STEP_FIELD missing cmd`,
  `E_STEP_FIELD duplicate cmd`). In order: the duplicate check; then `name`
  must be one of the sixteen commands
  ([`E_UNKNOWN_CMD`](#e_unknown_cmd)); then the argument expressions are
  evaluated left to right in the step's enclosing scope; then their count must
  fit ([`E_ARITY`](#e_arity) kind `cmd`); then their types must fit, in
  ascending argument order (site `cmd <name> argument <i>`).

A field's `duplicate` check always happens **before** that field's expression is
evaluated, so a second `cost` whose expression would itself fail still reports
`E_STEP_FIELD duplicate cost`.

When the block's closing `}` is reached, the step is **validated** immediately,
in this order:

1. `missing cmd`, then `missing out` (`E_STEP_FIELD`).
2. Every declared output path, in order, then the `depfile` path if present,
   must be a workspace path (`E_BAD_PATH`) whose first component is `out`
   ([`E_OUTPUT_PATH`](#e_output_path)). The two checks are applied path by
   path — `E_BAD_PATH` then `E_OUTPUT_PATH` for the first path, then for the
   second, and so on — so the first offending path decides which error is
   reported.
3. Every declared input and every `after` entry, in order (inputs first), must
   be either `@` followed by an identifier-shaped phony name, or a workspace
   path (`E_BAD_PATH` otherwise). Whether the referenced target *exists* is
   checked later.
4. The command's shape constraints ([`E_CMD_SHAPE`](#e_cmd_shape)): the number
   of *file inputs* and of declared outputs must fit the command, and the
   `depfile` field must be present exactly when the command requires one. A
   **file input** is a declared input that is not a phony reference; phony
   references among the inputs are ordering-only and are not counted.
5. Command-specific argument checks (`E_ARG` kind `cmd`).

The step's **primary output** is the first path in its declared output list.
Its full output list is the declared outputs followed by the `depfile` path, if
any.

---

## Steps, targets and the graph

### Nodes

After evaluation the build has a step list (serials `0 … S-1`), a phony table
and a default target list. From these, a dependency graph of three kinds of node
is built:

| Node kind | Created from | Name used in messages |
|-----------|--------------|-----------------------|
| step | each `step` block executed | its primary output path |
| phony | each `phony` statement | `@` + its name |
| source | each referenced path that exists in the workspace and is not any step's output | its path |

### Resolving a target reference

A target reference is a string appearing in `in`, `after`, a phony's dependency
list, `default`, or on a session `build` line. It resolves like this:

1. If it begins with `@`, the rest must name a declared phony target; the
   reference resolves to that phony node. If no such phony exists, it is an
   error.
2. Otherwise it is a path. If some step's full output list contains that exact
   path, it resolves to that step's node. (Output paths are unique, so at most
   one step matches.)
3. Otherwise, if a file exists at that path in the workspace, it resolves to a
   source node.
4. Otherwise it is an error.

The error is [`E_MISSING_INPUT`](#e_missing_input) when the reference comes from
`in`, `after` or a phony dependency list, and
[`E_UNKNOWN_TARGET`](#e_unknown_target) when it comes from `default` or a
`build` line.

References in `in`, `after` and phony dependency lists are checked for *shape*
earlier, when the `step` or `phony` statement is executed, so a malformed string
there raises `E_BAD_PATH` and never reaches resolution. References from
`default` and from `build` lines are **not** shape-checked: a malformed string
simply matches nothing in the three clauses above and yields
`E_UNKNOWN_TARGET`.

### Edges and dependency classes

- A step's **hashed dependencies** are its file inputs — the declared inputs
  that do not begin with `@` — in declaration order, duplicates kept. These are
  the files whose content participates in change detection.
- A step's **ordering dependencies** are, in order: the nodes its declared
  inputs resolve to (both file and phony), then the nodes its `after` entries
  resolve to. These determine when the step may run but, for the `after`
  entries and the phony inputs, nothing about freshness.
- A phony node's ordering dependencies are the nodes its dependency list
  resolves to, in order. A phony has no hashed dependencies.
- A source node has no dependencies.

For graph traversal the **successor list** of a node is its ordering
dependencies with duplicates removed, keeping the first occurrence.

### Whole-graph validation

These checks consider every step and every phony target, whether or not it is
reachable from the requested targets:

1. **Duplicate outputs.** Walk steps in serial order; within a step walk its
   full output list in order (declared outputs, then the depfile). The first
   path that a previous entry already claimed is
   [`E_DUP_OUTPUT`](#e_dup_output).
2. **Reference resolution.** Walk steps in serial order; for each step resolve
   its declared inputs in order, then its `after` entries in order. Then walk
   phony targets in declaration order and resolve each dependency list in
   order. The first failure is `E_MISSING_INPUT`.
3. **Default list.** Resolve the default target list in order. The first failure
   is `E_UNKNOWN_TARGET`. This happens even when the `build` line names its own
   targets.

### Requested targets and reachability

If the `build` line names targets, those are the **requested targets**, in the
order written, with duplicates removed keeping the first occurrence. If it names
none, the requested targets are the default target list with duplicates removed
the same way; if that is empty, the build fails with
[`E_NO_DEFAULT`](#e_no_default). Requested targets are then resolved
(`E_UNKNOWN_TARGET` on failure) in order.

The **reachable set** is every node reachable from the requested target nodes by
following successor lists. Only steps in the reachable set are considered by the
scheduler; unreachable steps are never executed and never touch the state file.

### Cycle detection

Cycles are searched for only within the reachable set, using this exact
depth-first search so that the reported cycle is deterministic.

```
colour[n] = white for all n
for root in requested target nodes, in order:
    if colour[root] != white: continue
    colour[root] = grey
    stack = [ (root, 0) ]
    while stack is not empty:
        (n, i) = top of stack
        if i < length(successors(n)):
            top of stack becomes (n, i + 1)
            m = successors(n)[i]
            if colour[m] == grey:
                # cycle found
                let j be the position of m in the stack (it is present)
                report E_CYCLE with the node names
                    stack[j], stack[j+1], …, stack[top], m
                stop the whole search
            if colour[m] == white:
                colour[m] = grey
                push (m, 0)
        else:
            colour[n] = black
            pop
```

The cycle is reported as [`E_CYCLE`](#e_cycle) with the node names joined by
` -> ` (space, hyphen, greater-than, space), starting and ending with the same
name. A step that lists its own output among its inputs produces a cycle of
length 2, e.g. `out/a.txt -> out/a.txt`.

The reachable set used by the scheduler is the set of nodes coloured grey or
black when the search completes without finding a cycle.

---

## The command set

There are sixteen commands. Each has a fixed argument signature, a required
number of file inputs, a required number of declared outputs, a flag for
whether it uses a depfile, and a default cost.

| Command | Arguments | File inputs | Outputs | Depfile | Default cost |
|---------|-----------|-------------|---------|---------|--------------|
| `write` | `text: str` | 0 | 1 | no | 1 |
| `copy` | — | 1 | 1 | no | 1 |
| `concat` | — | 1 or more | 1 | no | 2 |
| `upper` | — | 1 | 1 | no | 2 |
| `lower` | — | 1 | 1 | no | 2 |
| `grep` | `needle: str` | 1 | 1 | no | 3 |
| `replace` | `from: str`, `to: str` | 1 | 1 | no | 3 |
| `sort_lines` | — | 1 | 1 | no | 4 |
| `reverse_lines` | — | 1 | 1 | no | 2 |
| `dedup` | — | 1 | 1 | no | 3 |
| `number` | — | 1 | 1 | no | 2 |
| `indent` | `n: int` | 1 | 1 | no | 2 |
| `wrap` | `prefix: str`, `suffix: str` | 1 | 1 | no | 1 |
| `count_lines` | — | 1 or more | 1 | no | 2 |
| `hash` | — | 1 or more | 1 | no | 3 |
| `preprocess` | — | 1 | 1 | **required** | 6 |

An input count that does not fit is `E_CMD_SHAPE <name>: expected inputs <lo>-<hi>, got <m>`
(with `<lo>-<hi>` written as `0-0`, `1-1` or `1-N` for "1 or more"). An output
count that does not fit is `E_CMD_SHAPE <name>: expected outputs 1, got <m>`.
A `depfile` field on a command that does not take one is
`E_CMD_SHAPE <name>: depfile not allowed`; its absence on `preprocess` is
`E_CMD_SHAPE preprocess: depfile required`.

Command-specific argument checks, raised as `E_ARG cmd <name>: <reason>`:

- `replace` with an empty `from`: `empty pattern`.
- `indent` with `n < 0`: `negative`.

### Execution model

A command reads **all** the file content it needs at its **start time** and
writes **all** of its outputs at its **end time** (see
[The scheduler](#the-scheduler)). Because every file input of a reachable step
is either a source file (validated to exist at configuration time) or the output
of a step that has already completed, no command can ever find a declared input
missing.

In the descriptions below, *the input* means the single file input, *the inputs*
means the file inputs in declared order, and *the output* means the single
declared output.

### `write(text)`

The output content is exactly the bytes of `text`.

### `copy()`

The output content is exactly the input's content.

### `concat()`

The output content is the inputs' contents concatenated in declared order. A
path listed twice contributes twice.

### `upper()` / `lower()`

The output content is the input's content with the 26 ASCII letters of the
relevant case mapped; every other byte, including bytes ≥ 0x80, is copied
unchanged.

### `grep(needle)`

The output is the lines of the input that contain `needle` as a byte substring,
in their original order, each followed by a newline. `needle` is not checked:
an empty `needle` matches every line, so the output is then the input's lines
re-emitted each with a newline.

### `replace(from, to)`

The output content is the input's content with every occurrence of `from`
replaced by `to`, using the same left-to-right non-overlapping scan as the
`replace` built-in function. This command operates on the whole content, not
line by line.

### `sort_lines()`

The output is the lines of the input sorted ascending by the `str` total order
(byte order), each followed by a newline.

### `reverse_lines()`

The output is the lines of the input in reverse order, each followed by a
newline.

### `dedup()`

The output is the lines of the input with every line that is byte-identical to
an earlier line removed, order otherwise preserved, each followed by a newline.

### `number()`

The output is the lines of the input, each prefixed by its 1-based index in
decimal, then `: ` (colon, space), each followed by a newline. So three lines
`a`, `b`, `c` become `1: a\n2: b\n3: c\n`. There is no padding and no alignment.

### `indent(n)`

The output is the lines of the input, each prefixed by `n` space bytes, each
followed by a newline. Empty lines are indented too.

### `wrap(prefix, suffix)`

The output content is `prefix` + the input's content + `suffix`, byte for byte.
No line processing happens, so the result need not end with a newline.

### `count_lines()`

For each input, in declared order, a line consisting of the input's line count
in decimal, a space, and the input's path. Then a final line consisting of the
sum of those counts in decimal, a space, and the word `total`. Each line is
followed by a newline. With inputs `src/a.txt` (2 lines) and `src/b.txt`
(0 lines):

```
2 src/a.txt
0 src/b.txt
2 total
```

### `hash()`

For each input, in declared order, a line consisting of the 16-hex-digit
FNV-1a-64 hash of the input's content, a space, and the input's path. Each line
is followed by a newline. There is no total line. A path listed twice produces
two identical lines.

### `preprocess()`

Expands `@need` directives in the input, writes the expansion to the output, and
writes the set of files it read into the depfile.

A line of a file is a **need directive** iff it begins with the six bytes
`@need ` (`@`, `n`, `e`, `e`, `d`, space) — note the single trailing space — and
the remainder of the line is non-empty. The remainder, exactly as written with
no trimming, is the needed path. If that remainder is not a workspace path, the
command fails with [`E_NEED_PATH`](#e_need_path).

Expansion of a file `p` is defined recursively:

```
expand(p):
    push p onto the need stack
    for each line L of the content of p:
        if L is a need directive with path q:
            if q is not a workspace path: fail E_NEED_PATH <q>
            if no file exists at q: fail E_NEED_MISSING <q> needed by <p>
            if q is already on the need stack: fail E_NEED_CYCLE <q>
            record q in the discovered set
            emit expand(q)
        else:
            emit the line L
    pop p from the need stack
```

The output content is the concatenation of the emitted lines, each followed by a
newline. (A need directive contributes nothing itself; it is replaced by the
expansion of the needed file.)

The **discovered set** is every path recorded above, deduplicated and sorted
ascending by byte order. The primary input's own path is never recorded by the
rules above unless it is reached through a `@need`, which is a cycle and
therefore an error, so the discovered set never contains the primary input.

The depfile's content is:

```
kiln-deps 1
need <path>
need <path>
...
```

— the fixed header line `kiln-deps 1`, then one `need <path>` line per element
of the discovered set in sorted order, every line followed by a newline. With an
empty discovered set the depfile is just `kiln-deps 1\n`.

The depfile is written at the step's end time together with the declared output,
and it counts as one of the step's outputs for change detection, duplicate
detection and the state file.

Errors raised by `preprocess` are **execution errors**: they happen at the
command's end time and abort the build (see
[The build algorithm](#the-build-algorithm)). The three failing cases are
checked in the order shown in the pseudocode above, during a single left-to-right
pass over the lines of each file, depth first.

---

## Depfiles and discovered dependencies

A **depfile** is a file a command writes alongside its real output, naming
further files it turned out to read. It lets a step depend on files that the
build description did not mention. Only `preprocess` produces one, and it is
required to: a `preprocess` step must declare a `depfile`, and no other command
may.

The pieces, gathered in one place:

- The `depfile` field names the depfile's path. It must be a workspace path
  under `out/`, and it participates in duplicate-output detection exactly like a
  declared output.
- A step's **full output list** is its declared outputs followed by its depfile.
  The depfile is written at the step's end time, hashed, and recorded on an
  `out` line of the state entry, so deleting or editing it makes the step stale.
- The depfile's own format is the four-line-ish text described under
  [`preprocess()`](#preprocess): the header `kiln-deps 1`, then one
  `need <path>` line per discovered dependency, sorted ascending by path.
- The step's **discovered dependencies** are recorded on the state entry's `dep`
  lines, with the hash of the content the command read. On a later build they
  are compared by content (rule 6 of
  [Change detection](#change-detection)), which is what makes editing a
  `@need`-ed file rebuild the step.
- Kiln never re-reads a depfile to decide freshness; the `dep` lines in the
  state file are the authority. A depfile that is present but whose content
  disagrees with the state entry does not change any decision beyond the
  content hash check on the depfile itself as an output.
- Discovered dependencies are never scheduling edges — they are discovered
  after the fact, so they cannot be. Every test guarantees that a discovered
  dependency is a source file and not a step's output, so this never matters for
  correctness of ordering.
- A step that has never run has no `dep` lines, so its first build sees only its
  declared inputs. The second build is the first that can benefit.

Example 7 shows the whole cycle: first build, hit, edit a discovered dependency,
rebuild.

---

## The state file

Kiln persists what it knows about previously executed steps in the single
workspace file `.kiln-state`. The format is line oriented UTF-8 with `0x0A`
endings, and every line is terminated (so the file always ends with a newline).

```
kiln-state 1
step <primary output path>
cmd <canonical command string>
in <path> <hash>
in <path> <hash>
dep <path> <hash>
out <path> <hash>
out <path> <hash>
end
step <primary output path>
...
```

- The first line is exactly `kiln-state 1`.
- Then zero or more **entries**. An entry begins with a `step` line and ends
  with a line that is exactly `end`.
- Between them, in this exact order: exactly one `cmd` line; zero or more `in`
  lines; zero or more `dep` lines; one or more `out` lines.
- `<hash>` is 16 lowercase hex digits.
- Entries are written **sorted ascending by their primary output path** (byte
  order). Within an entry, `in` lines are in the step's declared file-input
  order (duplicates kept), `dep` lines are in ascending path order, and `out`
  lines are in the step's full-output-list order (declared outputs then the
  depfile).
- The primary output path on the `step` line always equals the path on the
  entry's first `out` line.

### The canonical command string

The `cmd` line, the log's command column and change detection all use the same
canonical rendering of a step's command:

```
<name>(<arg>, <arg>, ...)
```

— the command name, `(`, the arguments rendered as below and separated by `, `
(comma then one space), then `)`. A command with no arguments renders as e.g.
`concat()`.

| Argument type | Rendering |
|---------------|-----------|
| `int` | decimal, with a leading `-` when negative |
| `str` | `"` then the escaped bytes then `"` |

String escaping maps, in this priority: `\` → `\\`, `"` → `\"`, `0x0A` → `\n`,
`0x09` → `\t`, `0x0D` → `\r`, any other byte below `0x20` and the byte `0x7f` →
`\x` followed by exactly two lowercase hex digits, and every other byte
(including bytes ≥ `0x80`) literally.

Examples: `write("hello\n")`, `replace("a\\b", "c")`, `indent(4)`,
`wrap("<<", ">>")`, `grep("ü")`, `preprocess()`.

### Reading the state file

At the start of a build's execution phase, `.kiln-state` is read. The state is
taken to be **empty** if any of the following holds:

- there is no file at `.kiln-state`;
- its first line is not exactly `kiln-state 1`;
- the rest of the file does not match the grammar above exactly — including an
  unterminated entry, a stray line, a misordered section, a `cmd` line count
  other than one, an entry with no `out` line, a hash that is not 16 lowercase
  hex digits, a path that is not a workspace path, a `step` key that differs
  from the first `out` path, or two entries with the same `step` key;
- the file's last line is not terminated by `0x0A`.

A build whose state is taken to be empty simply rebuilds everything and
overwrites the file. Tests do contain hand-written and deliberately corrupt
state files.

The file is split into lines at every `0x0A` (the final `0x0A` does not start a
further line), and each line after the first must have exactly one of these
shapes — a key, a single space, and a remainder, or the bare word `end`:

| Line | Remainder |
|------|-----------|
| `step ` | a workspace path |
| `cmd ` | any non-empty byte sequence, taken verbatim |
| `in ` | a workspace path, one space, a 16-lowercase-hex-digit hash |
| `dep ` | likewise |
| `out ` | likewise |
| `end` | nothing at all |

Anything else — a different key, a missing or extra space, an `in` remainder
that does not split into exactly two space-separated fields, a `cmd ` with an
empty remainder — rejects the whole file. Reading imposes no ordering or
uniqueness requirement *within* a section: `dep` lines need not be sorted and a
path may repeat inside a section. Entries themselves need not be sorted by
`step` key, but their keys must be distinct, and the write path always emits
them sorted.

### Writing the state file

After a build reaches its execution phase, `.kiln-state` is written — always,
even when no command ran, even when the build failed with an execution error,
and even when the resulting content is byte-identical to what was there.

The state written is the state that was read, with these modifications:

- every step that executed successfully in this build has its entry **replaced**
  (or added);
- every step whose command **failed**, and every step whose command was
  **cancelled**, has its entry **removed** if it had one;
- every other entry — including entries for steps that were cache hits, steps
  outside the reachable set, and steps that no longer exist in the build files
  at all — is carried over unchanged.

A new or replaced entry for step `s` records:

- `cmd` — `s`'s canonical command string;
- `in` — `s`'s file inputs in declared order, each with the hash of the content
  the command read;
- `dep` — `s`'s discovered dependencies (only `preprocess` has any), sorted, each
  with the hash of the content the command read;
- `out` — `s`'s full output list in order, each with the hash of the content the
  command wrote.

A `clean` session step deletes `.kiln-state` outright; `create`, `edit`,
`delete` and `touch` never change it (though `create`/`edit`/`delete` may name
`.kiln-state` itself, and the tests use that to install corrupt states).

---

## Change detection

When a step becomes ready, Kiln decides once and for all whether it is **fresh**
(a cache hit, nothing runs) or **stale** (its command runs). Let `E` be the
state entry whose key equals the step's primary output path, if any. The step is
**stale** if any of the following is true, and **fresh** otherwise:

1. There is no such `E`.
2. `E`'s `cmd` string differs from the step's canonical command string.
3. `E`'s `out` path list, as an ordered list, differs from the step's full output
   list.
4. `E`'s `in` path list, as an ordered list, differs from the step's file-input
   list.
5. Some path on an `in` line does not exist in the workspace, or exists with a
   content hash different from the recorded one.
6. Some path on a `dep` line does not exist, or exists with a different hash.
7. Some path on an `out` line does not exist, or exists with a different hash.

Consequences worth stating explicitly, all of which the tests check:

- **Content, not time.** `touch` can never cause a rebuild, because no
  modification stamp is ever recorded or compared.
- **The command line counts.** Changing a command's name or any argument makes
  the step stale even when every input is byte-identical, because rule 2 fails.
- **The dependency set counts.** Reordering, adding or removing a declared input
  makes the step stale even when the file contents are unchanged, because rule 4
  compares ordered lists.
- **`cost` does not count.** Changing only a step's `cost` leaves it fresh.
- **Order-only dependencies do not count.** `after` entries and phony references
  in `in` never appear in the state entry and never affect freshness.
- **Outputs are verified.** Deleting or hand-editing a generated file makes its
  producer stale (rule 7), and so does deleting the depfile.
- **Early cutoff.** A step's inputs are hashed, not timestamped, so when an
  upstream step re-runs and produces byte-identical output, the downstream step
  is fresh and does not run. The chain stops there.
- **Discovered dependencies count.** Editing a file that a previous
  `preprocess` recorded in its depfile makes that step stale (rule 6), even
  though the file is not a declared input.

---

## The scheduler

A build is simulated on `N` workers numbered `0 … N-1` with an integer clock
starting at 0. Every executed command occupies exactly one worker for exactly
its cost, from its start time to its end time. Cache hits occupy no worker and
take no time.

Three kinds of node take part. **Source** and **phony** nodes do no work: a
source node completes at time 0, and a phony node completes at the moment its
last dependency completes (time 0 if it has none). Neither ever appears in the
log. Only **step** nodes are scheduled.

For each node in the reachable set, let `pending[n]` be the number of distinct
successors (dependencies) of `n` that have not yet completed. Completing a node
decrements `pending` for every node that depends on it; a source or phony node
whose `pending` reaches 0 completes immediately at that same instant, which may
cascade.

Initialisation, before the clock starts: every source node in the reachable set
completes at time 0, cascading through phony nodes whose `pending` count thereby
reaches 0 (and a phony node that started with `pending == 0` also completes at
time 0). `ready` is then the set of step nodes whose `pending` count is 0.

```
time    = 0
ready   = { step nodes in the reachable set with pending == 0 }
running = {}                      # worker -> (step, start, end)
ran = 0 ; hits = 0 ; events = []

loop:
    # (A) settle cache hits at the current time
    while some step in `ready` has no freshness decision yet:
        n = the one among those with the smallest serial number
        decide n's freshness against the workspace and the state, as it stands now
        if n is fresh:
            remove n from ready ; hits += 1
            events += hit(serial = n.serial, at = time)
            complete n at `time`                 # may enlarge `ready`
        # a stale step keeps its decision and stays in `ready`

    # (B) dispatch
    while `ready` is non-empty and some worker is free:
        n = the step in `ready` with the smallest serial number
        remove n from ready
        w = the free worker with the smallest id
        running[w] = (n, time, time + cost(n))
        events += exec(serial = n.serial, worker = w, start = time, end = time + cost(n))
        n reads, now, every file content it needs

    # (C) advance the clock
    if running is empty: break
    time = min(end) over running
    failed = []
    for each worker w with running[w].end == time, in ascending w:
        n = running[w].step ; free w
        run n's command
        if it raised an execution error:
            mark n's exec event as failed ; failed += n
        else:
            write n's outputs into the workspace ; replace n's state entry ; ran += 1
    if failed is non-empty:
        the build's error is the one raised by the smallest-serial step in `failed`
        for each worker w still in running, in ascending w:
            mark running[w].step's exec event as cancelled
            remove its state entry if any
        for each n in failed: remove its state entry if any
        break
    for each worker completed above, in ascending w: complete its step at `time`
```

At the end, the build's **completion time** `T` is the maximum of 0, every hit's
time, and every exec event's end time (cancelled events contribute their end
time too, since the clock reflects what was dispatched). The build succeeded if
no error was raised.

Properties this pins down, all exercised by the tests:

- Ties in the ready set are always broken by **ascending step serial number** —
  that is, by the order in which the `step` blocks were executed during
  evaluation, counting steps created inside rules and loops.
- Workers are always allocated lowest-id-first, so with `-j 4` and two ready
  steps, workers 0 and 1 are used.
- A step with `cost 0` is still dispatched to a worker and still logged; it
  starts and ends at the same instant.
- Hits are resolved before any dispatch at the same instant, and a cascade of
  hits all happens at one instant.
- Because freshness is decided when a step becomes ready, a step whose upstream
  dependency re-ran can see the new content and still be a hit.

---

## The build algorithm

A `build` session step runs the following. Phases 1–5 are **configuration**; if
any of them raises an error the build stops there, the workspace is completely
unchanged, `.kiln-state` is not written, and the log shows the header line and
one `error` line. Phase 7 may raise an **execution** error, after which
`.kiln-state` is still written.

1. **Build file.** If no file exists at `main.kiln`, raise
   [`E_NO_BUILD_FILE`](#e_no_build_file) with detail `main.kiln`.
2. **Evaluate.** Create an empty root scope, an empty step list, an empty phony
   table, an empty rule table and an empty default list. Lex, parse and execute
   `main.kiln`, following `include` statements. Errors are raised in execution
   order — the first one encountered wins.

   Each build file is lexed and parsed **in full** before any of its statements
   runs, so a syntax error anywhere in a file — including inside a `when` branch
   that is never taken or a `rule` body that is never used — precedes every
   error its statements could raise. A file reached by `include` is lexed and
   parsed at the point of the `include`, so statements before that `include`
   have already run.
3. **Whole-graph validation**, in the order given in
   [Whole-graph validation](#whole-graph-validation): duplicate outputs, then
   reference resolution, then the default list.
4. **Requested targets**: `E_NO_DEFAULT` then `E_UNKNOWN_TARGET`, as described
   in [Requested targets and reachability](#requested-targets-and-reachability).
5. **Cycle detection** over the reachable set; `E_CYCLE` on failure. This also
   yields the reachable set.
6. **Load the state** from `.kiln-state`.
7. **Schedule and execute**, per [The scheduler](#the-scheduler).
8. **Write the state** to `.kiln-state`.

Evaluation happens afresh for **every** `build` step in the session: build files
may have been edited, created or deleted since the previous build, and `glob`
results may have changed. Nothing is carried from one build to the next except
the workspace itself (including `.kiln-state`).

---

## Errors

A build either succeeds or fails with exactly **one** error, reported on a
single log line:

```
  error <KIND> <detail>
```

— two spaces, `error`, one space, the kind, and then, when the kind has a
detail, one space and the detail. Kinds with no detail produce `  error <KIND>`
with nothing after the kind.

The thirty kinds below are exhaustive. Each is listed with its detail
format and the situations that raise it. `<…>` stands for a substituted value,
inserted literally with no quoting unless the format says otherwise.

### Which error wins

Configuration errors are raised in the order of the eight phases in
[The build algorithm](#the-build-algorithm). Within phase 2 (evaluation) errors
are raised in the order statements and sub-expressions are evaluated: statements
top to bottom, `include` bodies at the point of the `include`, rule bodies at
the point of the `use`, argument lists and operands left to right, and a `step`
block's validation at its closing brace. Within phase 3 the sub-order is
duplicate outputs, then reference resolution, then the default list, each
scanned in the order given in
[Whole-graph validation](#whole-graph-validation). The first error raised is the
one reported; nothing after it is evaluated.

Execution errors (`E_NEED_PATH`, `E_NEED_MISSING`, `E_NEED_CYCLE`) can only come
from `preprocess`. When several commands fail at the same instant, the error of
the lowest-serial failing step is reported.

### E_PARSE

```
E_PARSE <file>:<line>
```

`<file>` is the workspace path of the build file and `<line>` is the 1-based
number of the **first physical line of the offending logical line** (for an
unterminated block, of the block-header line; for brackets still open at end of
file, of the first physical line of that logical line). Raised by every lexical
and syntactic violation described in
[KBL: lexical structure](#kbl-lexical-structure),
[KBL: grammar](#kbl-grammar) and
[KBL: string literals and interpolation](#kbl-string-literals-and-interpolation).

### E_UNKNOWN_VAR

```
E_UNKNOWN_VAR <name>
```

An identifier used as a value is bound in no enclosing scope.

### E_REDEFINE

```
E_REDEFINE <name>
```

A `let` whose name is already bound in the current scope, or a `rule` whose name
is already in the rule table.

### E_SET_UNDEFINED

```
E_SET_UNDEFINED <name>
```

A `set` whose name is bound in no enclosing scope.

### E_TYPE

```
E_TYPE <site>: expected <expected>, got <actual>
```

`<actual>` is one of `str`, `int`, `bool`, `list`. `<expected>` is one of:

| Token | Used by |
|-------|---------|
| `str` | most string sites |
| `int` | arithmetic, `cost`, `substr`/`slice` offsets, `range`, `indent`, `sum` elements, `x[i]`'s index |
| `bool` | `!`, `&&`, `\|\|`, `when` conditions |
| `list` | `++`, `each` subjects, the list argument of every list function |
| `str\|list` | `len`, and `x[i]`'s target |
| `str\|int` | `join` elements, and `int`'s argument |
| `str\|int\|bool` | `str`'s argument |
| `strlist` | `out`, `in`, `after`, `default`, `phony` — a `str` or a list whose elements are all `str` |

For a `strlist` site, a `list` containing a non-`str` element also raises this
error, with `<actual>` being the type of the first such element.

`<site>` is exactly one of:

| Site | Where |
|------|-------|
| `operator <op>` | a binary or unary operator operand; `<op>` is the operator's spelling |
| `index` | the index expression of `x[i]` |
| `index target` | the target expression of `x[i]` |
| `fn <name> argument <i>` | the `i`-th (1-based) argument of a built-in function |
| `fn join element <i>` | the `i`-th (0-based) element of `join`'s list |
| `fn map element <i>` | the `i`-th (0-based) element of `map`'s list |
| `fn sum element <i>` | the `i`-th (0-based) element of `sum`'s list |
| `fn filter element <i>` | the `i`-th (0-based) element of `filter`'s list (must be `str`) |
| `fn reject element <i>` | likewise for `reject` |
| `cmd <name> argument <i>` | the `i`-th (1-based) argument of a command |
| `field <name>` | a `step` field: `out`, `in`, `after`, `cost`, `depfile` |
| `when condition` | a `when` or `elsewhen` condition |
| `each subject` | the list expression of an `each` |
| `include path` | the path expression of an `include` |
| `abort message` | the message expression of an `abort` |
| `default` | the expression of a `default` statement |
| `phony <name>` | the dependency expression of a `phony` statement |

Examples: `E_TYPE operator +: expected int, got str`,
`E_TYPE fn upper argument 1: expected str, got int`,
`E_TYPE field out: expected strlist, got int`,
`E_TYPE when condition: expected bool, got str`.

### E_ARITY

```
E_ARITY <kind> <name>: expected <n>, got <m>
E_ARITY <kind> <name>: expected <lo>-<hi>, got <m>
```

`<kind>` is `fn`, `cmd` or `rule`. The second form is used when the accepted
count is a range: only `pathjoin` (`1-8`) uses it. `<m>` is the number of
arguments supplied; for `rule` it is the number of **positional** arguments and
`<n>` the number of parameters.

Examples: `E_ARITY fn upper: expected 1, got 2`,
`E_ARITY fn pathjoin: expected 1-8, got 0`,
`E_ARITY cmd grep: expected 1, got 0`,
`E_ARITY rule bundle: expected 2, got 3`.

### E_UNKNOWN_FUNC

```
E_UNKNOWN_FUNC <name>
```

A call to an identifier that is not one of the 39 built-in functions.

### E_UNKNOWN_RULE

```
E_UNKNOWN_RULE <name>
```

A `use` naming a rule that is not in the rule table.

### E_UNKNOWN_CMD

```
E_UNKNOWN_CMD <name>
```

A `cmd` field naming something other than one of the sixteen commands.

### E_ARG

```
E_ARG <kind> <name>: <reason>
```

`<kind>` is `fn`, `cmd`, `rule` or `field`. The complete set of reasons:

| Kind | Name | Reason | Condition |
|------|------|--------|-----------|
| `fn` | `index` | `out of range` | `x[i]` with `i` outside `-len(x) … len(x)-1` |
| `fn` | `replace` | `empty pattern` | `replace(s, "", to)` |
| `fn` | `split` | `empty separator` | `split(s, "")` |
| `fn` | `int` | `bad integer` | `int(s)` with `s` not matching `-?[0-9]+`, or out of 64-bit range |
| `fn` | `first` | `empty list` | `first([])` |
| `fn` | `last` | `empty list` | `last([])` |
| `fn` | `range` | `negative` | `range(n)` with `n < 0` |
| `fn` | `glob` | `bad pattern` | malformed glob pattern |
| `fn` | `filter` | `bad pattern` | malformed glob pattern |
| `fn` | `reject` | `bad pattern` | malformed glob pattern |
| `cmd` | `replace` | `empty pattern` | `cmd replace("", to)` |
| `cmd` | `indent` | `negative` | `cmd indent(n)` with `n < 0` |
| `field` | `cost` | `negative` | `cost` evaluating to a negative `int` |
| `rule` | *rule name* | `unknown argument <kw>` | keyword argument naming no parameter |
| `rule` | *rule name* | `duplicate argument <kw>` | parameter bound twice |
| `rule` | *rule name* | `missing argument <param>` | parameter with no argument and no default |

Examples: `E_ARG fn index: out of range`,
`E_ARG rule bundle: unknown argument deps`,
`E_ARG field cost: negative`.

### E_INCLUDE_MISSING

```
E_INCLUDE_MISSING <path>
```

An `include` whose path names no existing workspace file.

### E_INCLUDE_CYCLE

```
E_INCLUDE_CYCLE <path>
```

An `include` whose path is already on the include stack. `<path>` is the path
being re-entered.

### E_BAD_PATH

```
E_BAD_PATH <string>
```

A string required to be a workspace path is not one. `<string>` is the offending
string, inserted literally (not quoted, not escaped). Raised by `include`, by
`out`, `depfile`, `in` and `after` entries that do not begin with `@`, and by
`@`-prefixed entries whose remainder is not identifier-shaped (`[A-Za-z_][A-Za-z0-9_]*`)
— in that last case the whole entry including the `@` is the detail.

### E_OUTPUT_PATH

```
E_OUTPUT_PATH <path>
```

A declared output or depfile path whose first component is not `out`.

### E_STEP_FIELD

```
E_STEP_FIELD <reason>
```

`<reason>` is one of `missing cmd`, `missing out`, `duplicate cmd`,
`duplicate cost`, `duplicate depfile`. The duplicate reasons are raised at the
offending field, during the top-to-bottom processing of the block; the missing
reasons at the closing brace, `missing cmd` before `missing out`.

### E_CMD_SHAPE

```
E_CMD_SHAPE <name>: expected inputs <lo>-<hi>, got <m>
E_CMD_SHAPE <name>: expected outputs 1, got <m>
E_CMD_SHAPE <name>: depfile required
E_CMD_SHAPE <name>: depfile not allowed
```

Checked in that order. `<lo>-<hi>` is `0-0` for `write`, `1-1` for the
single-input commands, and `1-N` for `concat`, `count_lines` and `hash`. `<m>`
is the number of file inputs (phony references in `in` are not counted) or of
declared outputs (the depfile is not counted).

### E_DUP_OUTPUT

```
E_DUP_OUTPUT <path>
```

Two steps, or one step twice, declare the same output path (counting depfiles).

### E_DUP_PHONY

```
E_DUP_PHONY <name>
```

Two `phony` statements declare the same name. `<name>` has no `@`.

### E_MISSING_INPUT

```
E_MISSING_INPUT <target> required by <node>
```

A reference in `in`, `after` or a phony dependency list resolves to nothing.
`<target>` is the reference exactly as written (with its `@` if it had one).
`<node>` is the depending node's name: a step's primary output path, or `@` plus
a phony name.

### E_UNKNOWN_TARGET

```
E_UNKNOWN_TARGET <target>
```

A `default` entry or a `build` line target resolves to nothing.

### E_CYCLE

```
E_CYCLE <node> -> <node> -> ... -> <node>
```

Node names as produced by the depth-first search in
[Cycle detection](#cycle-detection); the first and last names are equal.

### E_NO_DEFAULT

```
E_NO_DEFAULT
```

A `build` line with no targets when the default target list is empty. No detail.

### E_RULE_RECURSION

```
E_RULE_RECURSION <name>
```

A `use` that would make the rule instantiation depth 65.

### E_DIV_ZERO

```
E_DIV_ZERO
```

`/` or `%` with a zero right operand. No detail.

### E_INTERP

```
E_INTERP list
```

An interpolation whose expression evaluates to a `list`. The detail is always
the word `list`.

### E_ABORT

```
E_ABORT <message>
```

An `abort` statement. `<message>` is the evaluated string, inserted literally.

### E_NO_BUILD_FILE

```
E_NO_BUILD_FILE main.kiln
```

A `build` step with no file at `main.kiln`. The detail is always `main.kiln`.

### E_NEED_PATH

```
E_NEED_PATH <raw>
```

A `@need ` directive whose remainder is not a workspace path. `<raw>` is that
remainder, inserted literally. **Execution error.**

### E_NEED_MISSING

```
E_NEED_MISSING <path> needed by <path>
```

A `@need ` directive naming a path with no file. The second path is the file
containing the directive. **Execution error.**

### E_NEED_CYCLE

```
E_NEED_CYCLE <path>
```

A `@need ` directive naming a file already being expanded. `<path>` is the file
being re-entered. **Execution error.**

---

## log.txt

`log.txt` is UTF-8 text with `0x0A` endings. It is the concatenation, in session
order, of one block per session step, with no blank lines anywhere. A session
with no steps produces an empty `log.txt`.

Each block is a header line, then zero or more **event** lines, then exactly one
**result** line. Event and result lines begin with exactly two spaces; header
lines begin at column 0.

### Header lines

```
step <n>: build <target> <target> ... -j <N>
step <n>: build (default) -j <N>
step <n>: create <path>
step <n>: edit <path>
step <n>: delete <path>
step <n>: touch <path>
step <n>: clean
```

`<n>` counts session steps from 1 (skipped blank and comment lines do not
count). For `build`, the targets are reproduced exactly as written on the
session line, separated by single spaces; with no targets the literal text
`(default)` is used instead. `-j <N>` is always printed, with the effective
worker count (1 when the session line omitted `-j`).

### Event lines for a build

```
  hit <time> <target>
  run <start> <end> w<worker> <target> <command>
  fail <start> <end> w<worker> <target> <command>
  cancel <start> <end> w<worker> <target> <command>
```

- `<target>` is the step's primary output path.
- `<command>` is the step's canonical command string.
- `<time>`, `<start>`, `<end>` are decimal integers with no padding.
- `<worker>` is the worker id in decimal, prefixed by `w`.
- `run` is a command that executed successfully; `fail` is the command whose
  execution error was reported *and* any other command that failed at the same
  instant; `cancel` is a command that was dispatched but was still running when
  the build aborted — its outputs were not written, but its start and end times
  are printed as scheduled.
- Cache hits and only cache hits produce `hit`. Phony and source nodes produce
  no lines at all.

Event lines are sorted ascending by **start time**, and ties are broken by
ascending **step serial number**; a `hit`'s start time is its `<time>`. Serial
numbers are unique, so the order is total. The serial numbers themselves are
never printed.

### Result lines

```
  ok ran=<R> hit=<H> time=<T>          after a successful build
  error <KIND> <detail>                after a failed build
  ok size=<B>                          after create or edit
  ok                                   after delete or touch
  ok removed=<K>                       after clean
```

- `<R>` is the number of commands that executed successfully, `<H>` the number
  of cache hits, `<T>` the build's completion time.
- `<B>` is the byte length of the content written by `create` or `edit`.
- `clean` additionally emits, before its result line, one event line
  `  remove <path>` per removed path, sorted ascending by path (byte order);
  `.kiln-state` sorts before `out/...` because `.` is byte 0x2e and `o` is 0x6f.
  `<K>` is the number of paths removed.

### A complete example

```
step 1: build @all -j 2
  run 0 1 w0 out/a.txt write("A\n")
  run 0 1 w1 out/b.txt write("B\n")
  run 1 3 w0 out/all.txt concat()
  ok ran=3 hit=0 time=3
step 2: touch src/x.txt
  ok
step 3: build @all -j 2
  hit 0 out/a.txt
  hit 0 out/b.txt
  hit 0 out/all.txt
  ok ran=0 hit=3 time=0
step 4: clean
  remove .kiln-state
  remove out/a.txt
  remove out/all.txt
  remove out/b.txt
  ok removed=4
```

---

## Worked examples

Each example gives the input directory's files, then the exact `log.txt`, then
the files of `<output>/workspace/` that matter (build files and sources that the
session did not change are omitted from the workspace listing, but they *are*
present in the real output). File contents are shown with `⏎` standing for a
trailing newline only where it would otherwise be ambiguous; every file shown in
a fenced block ends with exactly one newline unless stated otherwise.

### Example 1 — one step

`main.kiln`:

```
step {
    out "out/hello.txt"
    cmd write("hello\n")
}
default "out/hello.txt"
```

`session.txt`:

```
build
```

`log.txt`:

```
step 1: build (default) -j 1
  run 0 1 w0 out/hello.txt write("hello\n")
  ok ran=1 hit=0 time=1
```

`workspace/out/hello.txt`:

```
hello
```

`workspace/.kiln-state`:

```
kiln-state 1
step out/hello.txt
cmd write("hello\n")
out out/hello.txt a9bc80cca21f28b3
end
```

Note that the step has no inputs, so the entry has no `in` lines, and the
`write` command's default cost of 1 was used.

### Example 2 — a cache hit, and `touch` is not a change

Same `main.kiln` as Example 1.

`session.txt`:

```
build
build
touch main.kiln
build
```

`log.txt`:

```
step 1: build (default) -j 1
  run 0 1 w0 out/hello.txt write("hello\n")
  ok ran=1 hit=0 time=1
step 2: build (default) -j 1
  hit 0 out/hello.txt
  ok ran=0 hit=1 time=0
step 3: touch main.kiln
  ok
step 4: build (default) -j 1
  hit 0 out/hello.txt
  ok ran=0 hit=1 time=0
```

The workspace is identical to Example 1's.

### Example 3 — parallel scheduling, worker allocation and tie-breaking

`main.kiln`:

```
step {
    out "out/a.txt"
    cmd write("A\n")
    cost 3
}
step {
    out "out/b.txt"
    cmd write("B\n")
    cost 1
}
step {
    out "out/c.txt"
    cmd write("C\n")
    cost 4
}
step {
    out "out/d.txt"
    cmd write("D\n")
    cost 2
}
step {
    out "out/all.txt"
    in ["out/a.txt", "out/b.txt", "out/c.txt", "out/d.txt"]
    cmd concat()
    cost 2
}
default "out/all.txt"
```

`session.txt`:

```
build -j 2
```

`log.txt`:

```
step 1: build (default) -j 2
  run 0 3 w0 out/a.txt write("A\n")
  run 0 1 w1 out/b.txt write("B\n")
  run 1 5 w1 out/c.txt write("C\n")
  run 3 5 w0 out/d.txt write("D\n")
  run 5 7 w0 out/all.txt concat()
  ok ran=5 hit=0 time=7
```

Step by step: at time 0 steps 0–3 are ready and workers 0 and 1 are free, so
serial 0 goes to worker 0 (ending at 3) and serial 1 to worker 1 (ending at 1).
At time 1 worker 1 is free and serials 2 and 3 are ready, so serial 2 — the
smaller — is dispatched, ending at 5. At time 3 worker 0 frees up and takes
serial 3, also ending at 5. At time 5 both finish (worker 0 first, then worker
1), the join step becomes ready, is found stale, and runs on worker 0 from 5 to
7. The log is sorted by start time, then by serial, which is why `out/c.txt`
(start 1) precedes `out/d.txt` (start 3).

`workspace/out/all.txt`:

```
A
B
C
D
```

### Example 4 — variables, interpolation, `each`, `map`, phony

`main.kiln`:

```
let names = ["alpha", "beta", "gamma"]
let outs = map(names, "out/%.txt")
each i, n in names {
    step {
        out "out/{n}.txt"
        cmd write("{i}:{n}\n")
        cost 1
    }
}
step {
    out "out/index.txt"
    in outs
    cmd concat()
}
phony all = ["out/index.txt"]
default "@all"
```

`session.txt`:

```
build @all -j 3
```

`log.txt`:

```
step 1: build @all -j 3
  run 0 1 w0 out/alpha.txt write("0:alpha\n")
  run 0 1 w1 out/beta.txt write("1:beta\n")
  run 0 1 w2 out/gamma.txt write("2:gamma\n")
  run 1 3 w0 out/index.txt concat()
  ok ran=4 hit=0 time=3
```

`workspace/out/index.txt`:

```
0:alpha
1:beta
2:gamma
```

### Example 5 — rule templates and a chain

Sources: `src/a.txt` contains `AAA⏎`, `src/b.txt` contains `BBB⏎`.

`main.kiln`:

```
rule bundle(name, parts, weight = 2) {
    step {
        out "out/{name}.txt"
        in parts
        cmd concat()
        cost weight
    }
}

let base = ["src/a.txt", "src/b.txt"]
use bundle("one", base)
use bundle(name = "two", parts = base ++ ["out/one.txt"], weight = 5)
phony all = ["out/one.txt", "out/two.txt"]
default "@all"
```

`session.txt`:

```
build -j 2
```

`log.txt`:

```
step 1: build (default) -j 2
  run 0 2 w0 out/one.txt concat()
  run 2 7 w0 out/two.txt concat()
  ok ran=2 hit=0 time=7
```

Two workers do not help: the second bundle depends on the first. Note that
`weight` cannot be called `cost`, because `cost` is a reserved word.

`workspace/out/one.txt`:

```
AAA
BBB
```

`workspace/out/two.txt`:

```
AAA
BBB
AAA
BBB
```

`workspace/.kiln-state`:

```
kiln-state 1
step out/one.txt
cmd concat()
in src/a.txt 8943a78b9f342c58
in src/b.txt c857dca71c36fafd
out out/one.txt 5e52e06e8b405ae8
end
step out/two.txt
cmd concat()
in src/a.txt 8943a78b9f342c58
in src/b.txt c857dca71c36fafd
in out/one.txt 5e52e06e8b405ae8
out out/two.txt f98ee131e7582add
end
```

Entries are sorted by primary output (`out/one.txt` before `out/two.txt`), but
`in` lines keep declaration order, so `out/one.txt` comes last in the second
entry.

### Example 6 — glob, `include`, `set`, `when`/`otherwise`

Workspace files: `src/a.txt` = `a1⏎`, `src/b.txt` = `b1⏎`,
`src/sub/c.txt` = `c1⏎`, `src/notes.md` = `note⏎`.

`main.kiln`:

```
let mode = "fast"
let flags = []
include "tune.kiln"
when mode == "fast" {
    set flags = flags ++ ["F"]
} otherwise {
    set flags = flags ++ ["S"]
}
let srcs = glob("src/**/*.txt")
step {
    out "out/list.txt"
    in srcs
    cmd count_lines()
}
step {
    out "out/flags.txt"
    cmd write("{join(flags, ",")}\n")
}
default ["out/list.txt", "out/flags.txt"]
```

`tune.kiln`:

```
set mode = "slow"
let extra = 1
```

`session.txt`:

```
build -j 2
```

The include runs in `main.kiln`'s scope, so its `set` changes `mode` to `slow`
and its `let extra` is visible afterwards. `mode == "fast"` is therefore false
and the `otherwise` branch runs. The glob matches `src/a.txt`, `src/b.txt` and
`src/sub/c.txt` — `src/notes.md` fails `*.txt`, and `main.kiln` and `tune.kiln`
fail the leading `src` component.

`log.txt`:

```
step 1: build (default) -j 2
  run 0 2 w0 out/list.txt count_lines()
  run 0 1 w1 out/flags.txt write("S\n")
  ok ran=2 hit=0 time=2
```

`workspace/out/list.txt`:

```
1 src/a.txt
1 src/b.txt
1 src/sub/c.txt
3 total
```

`workspace/out/flags.txt`:

```
S
```

### Example 7 — `preprocess`, depfiles and discovered dependencies

Workspace files:

- `src/main.txt`:

```
title
@need src/part.txt
end
```

- `src/part.txt`:

```
PART-A
@need src/deep.txt
```

- `src/deep.txt`:

```
DEEP
```

`main.kiln`:

```
step {
    out "out/doc.txt"
    depfile "out/doc.d"
    in "src/main.txt"
    cmd preprocess()
}
default "out/doc.txt"
```

`session.txt`:

```
build
build
edit src/deep.txt
DEEP2
---
build
```

`log.txt`:

```
step 1: build (default) -j 1
  run 0 6 w0 out/doc.txt preprocess()
  ok ran=1 hit=0 time=6
step 2: build (default) -j 1
  hit 0 out/doc.txt
  ok ran=0 hit=1 time=0
step 3: edit src/deep.txt
  ok size=6
step 4: build (default) -j 1
  run 0 6 w0 out/doc.txt preprocess()
  ok ran=1 hit=0 time=6
```

`src/deep.txt` is not a declared input, so the rebuild in step 4 is caused
purely by the `dep` line that step 1 recorded from the depfile.

`workspace/out/doc.txt`:

```
title
PART-A
DEEP2
end
```

`workspace/out/doc.d`:

```
kiln-deps 1
need src/deep.txt
need src/part.txt
```

`workspace/.kiln-state`:

```
kiln-state 1
step out/doc.txt
cmd preprocess()
in src/main.txt 993a20756b253540
dep src/deep.txt 06ae7bdd484568d7
dep src/part.txt a8442a790131f243
out out/doc.txt f755eb555e1be12f
out out/doc.d ea603661a409bc02
end
```

After step 1 the only difference would have been
`dep src/deep.txt bf4c0cd0d6f88fdf` and
`out out/doc.txt a05ea9c125e3b739`.

### Example 8 — early cutoff

Workspace: `src/a.txt` = `abc⏎`.

`main.kiln`:

```
step {
    out "out/mid.txt"
    in "src/a.txt"
    cmd upper()
}
step {
    out "out/final.txt"
    in "out/mid.txt"
    cmd number()
}
default "out/final.txt"
```

`session.txt`:

```
build
edit src/a.txt
ABC
---
build
```

`log.txt`:

```
step 1: build (default) -j 1
  run 0 2 w0 out/mid.txt upper()
  run 2 4 w0 out/final.txt number()
  ok ran=2 hit=0 time=4
step 2: edit src/a.txt
  ok size=4
step 3: build (default) -j 1
  run 0 2 w0 out/mid.txt upper()
  hit 2 out/final.txt
  ok ran=1 hit=1 time=2
```

`src/a.txt` changed, so `out/mid.txt`'s producer is stale and re-runs — but it
writes the same bytes it wrote before, so `out/final.txt`'s producer, whose only
input is `out/mid.txt`, is found fresh when it becomes ready at time 2. The hit
is recorded at time 2, which is also the build's completion time.

`workspace/out/mid.txt`:

```
ABC
```

`workspace/out/final.txt`:

```
1: ABC
```

### Example 9 — a dependency cycle

`main.kiln`:

```
step {
    out "out/x.txt"
    in "out/y.txt"
    cmd copy()
}
step {
    out "out/y.txt"
    in "out/x.txt"
    cmd copy()
}
default "out/x.txt"
```

`session.txt`:

```
build
```

`log.txt`:

```
step 1: build (default) -j 1
  error E_CYCLE out/x.txt -> out/y.txt -> out/x.txt
```

This is a configuration error, so nothing at all is written: the output
workspace contains only `main.kiln`, with no `out/` directory and no
`.kiln-state`.

### Example 10 — five configuration errors

Five independent inputs, each with the single session step `build` and, where
noted, a source file `src/a.txt` containing `a⏎`.

**10a — duplicate output.** `main.kiln`:

```
step {
    out "out/z.txt"
    cmd write("1\n")
}
step {
    out "out/z.txt"
    cmd write("2\n")
}
default "out/z.txt"
```

```
step 1: build (default) -j 1
  error E_DUP_OUTPUT out/z.txt
```

**10b — missing input** (with `src/a.txt` present). `main.kiln`:

```
step {
    out "out/z.txt"
    in ["src/a.txt", "src/missing.txt"]
    cmd concat()
}
default "out/z.txt"
```

```
step 1: build (default) -j 1
  error E_MISSING_INPUT src/missing.txt required by out/z.txt
```

**10c — unknown variable.** `main.kiln`:

```
step {
    out "out/z.txt"
    cmd write(greeting)
}
default "out/z.txt"
```

```
step 1: build (default) -j 1
  error E_UNKNOWN_VAR greeting
```

**10d — `abort`.** `main.kiln`:

```
let n = 3
when n > 2 {
    abort "n too large: {n}"
}
```

```
step 1: build (default) -j 1
  error E_ABORT n too large: 3
```

The `abort` is reached during evaluation, before the empty default list could
have raised `E_NO_DEFAULT`.

**10e — no default.** `main.kiln`:

```
step {
    out "out/z.txt"
    cmd write("ok\n")
}
```

```
step 1: build (default) -j 1
  error E_NO_DEFAULT
```

### Example 11 — `clean`

`main.kiln` as in Example 1.

`session.txt`:

```
build
clean
build
```

`log.txt`:

```
step 1: build (default) -j 1
  run 0 1 w0 out/hello.txt write("hello\n")
  ok ran=1 hit=0 time=1
step 2: clean
  remove .kiln-state
  remove out/hello.txt
  ok removed=2
step 3: build (default) -j 1
  run 0 1 w0 out/hello.txt write("hello\n")
  ok ran=1 hit=0 time=1
```

`.kiln-state` sorts before `out/hello.txt` because `.` is byte `0x2e` and `o`
is byte `0x6f`.

### Example 12 — an execution error cancels work in flight

Workspace: `src/main.txt` containing the single line `@need src/gone.txt`.

`main.kiln`:

```
step {
    out "out/doc.txt"
    depfile "out/doc.d"
    in "src/main.txt"
    cmd preprocess()
}
step {
    out "out/slow.txt"
    cmd write("slow\n")
    cost 10
}
step {
    out "out/after.txt"
    in "out/doc.txt"
    cmd copy()
}
phony all = ["out/doc.txt", "out/slow.txt", "out/after.txt"]
default "@all"
```

`session.txt`:

```
build -j 2
```

`log.txt`:

```
step 1: build (default) -j 2
  fail 0 6 w0 out/doc.txt preprocess()
  cancel 0 10 w1 out/slow.txt write("slow\n")
  error E_NEED_MISSING src/gone.txt needed by src/main.txt
```

Serial 0 and serial 1 start at time 0 on workers 0 and 1. Serial 0 fails at
time 6, which aborts the build; serial 1 is still running, so it is cancelled
and its output is never written. Serial 2 never became ready and produces no
line at all. Because the build reached its execution phase, the state file is
still written — empty, since the failing and cancelled steps have no entries:

`workspace/.kiln-state`:

```
kiln-state 1
```

There is no `out/` directory in the output workspace.

### Example 13 — `after` is order-only

Workspace: `src/a.txt` = `a⏎`.

`main.kiln`:

```
step {
    out "out/gen.txt"
    in "src/a.txt"
    cmd copy()
}
step {
    out "out/rep.txt"
    after "out/gen.txt"
    cmd write("report\n")
}
phony all = ["out/rep.txt"]
default "@all"
```

`session.txt`:

```
build
edit src/a.txt
b
---
build
```

`log.txt`:

```
step 1: build (default) -j 1
  run 0 1 w0 out/gen.txt copy()
  run 1 2 w0 out/rep.txt write("report\n")
  ok ran=2 hit=0 time=2
step 2: edit src/a.txt
  ok size=2
step 3: build (default) -j 1
  run 0 1 w0 out/gen.txt copy()
  hit 1 out/rep.txt
  ok ran=1 hit=1 time=1
```

`out/rep.txt`'s producer waits for `out/gen.txt` — note it starts at time 1, not
0 — but `out/gen.txt` is not among its hashed dependencies, so changing
`src/a.txt` cannot make it stale.

`workspace/.kiln-state`:

```
kiln-state 1
step out/gen.txt
cmd copy()
in src/a.txt 08a61e07b54dac5d
out out/gen.txt 08a61e07b54dac5d
end
step out/rep.txt
cmd write("report\n")
out out/rep.txt 11aab68ba3164db3
end
```

The `after` entry appears nowhere in the state file.

### Example 14 — `cost` is not a change, the dependency set is

Workspace: `src/a.txt` and `src/b.txt` both containing `a⏎` — byte-identical.

`main.kiln`, 100 bytes:

```
step {
    out "out/j.txt"
    in ["src/a.txt", "src/b.txt"]
    cmd concat()
}
default "out/j.txt"
```

`session.txt`:

```
build
edit main.kiln
step {
    out "out/j.txt"
    in ["src/a.txt", "src/b.txt"]
    cmd concat()
    cost 5
}
default "out/j.txt"
---
build
edit main.kiln
step {
    out "out/j.txt"
    in ["src/b.txt", "src/a.txt"]
    cmd concat()
    cost 5
}
default "out/j.txt"
---
build
```

`log.txt`:

```
step 1: build (default) -j 1
  run 0 2 w0 out/j.txt concat()
  ok ran=1 hit=0 time=2
step 2: edit main.kiln
  ok size=111
step 3: build (default) -j 1
  hit 0 out/j.txt
  ok ran=0 hit=1 time=0
step 4: edit main.kiln
  ok size=111
step 5: build (default) -j 1
  run 0 5 w0 out/j.txt concat()
  ok ran=1 hit=0 time=5
```

Adding `cost 5` changes nothing the state file records, so step 3 is a hit.
Swapping the two inputs changes the recorded `in` path list, so step 5 is
stale — even though the two files have identical content and the output is
byte-for-byte unchanged.

`workspace/out/j.txt`:

```
a
a
```

`workspace/.kiln-state`:

```
kiln-state 1
step out/j.txt
cmd concat()
in src/b.txt 089bdc07b544e7b2
in src/a.txt 089bdc07b544e7b2
out out/j.txt 78f78981f13f2f99
end
```

### Example 15 — tampering with and deleting an output

`main.kiln` as in Example 1.

`session.txt`:

```
build
edit out/hello.txt
tampered
---
build
delete out/hello.txt
build
```

`log.txt`:

```
step 1: build (default) -j 1
  run 0 1 w0 out/hello.txt write("hello\n")
  ok ran=1 hit=0 time=1
step 2: edit out/hello.txt
  ok size=9
step 3: build (default) -j 1
  run 0 1 w0 out/hello.txt write("hello\n")
  ok ran=1 hit=0 time=1
step 4: delete out/hello.txt
  ok
step 5: build (default) -j 1
  run 0 1 w0 out/hello.txt write("hello\n")
  ok ran=1 hit=0 time=1
```

Both rule 7 failures — a changed output and a missing output — make the step
stale.

---

## Guarantees

Every test input satisfies all of the following. An implementation may do
anything on an input that violates them, but it must not fail on an input that
satisfies them.

1. The input directory exists and contains a regular file `session.txt` at its
   top level. Every other regular file's path relative to the input directory is
   a valid workspace path. There are no symbolic links, no empty directories,
   and no files that are not regular files.
2. `session.txt` matches the grammar in [session.txt](#sessiontxt) exactly:
   every non-blank, non-comment line begins a well-formed step, every `create`
   and `edit` block is terminated by a `---` line before the end of the file, no
   content line is exactly `---`, and every `-j` value is a decimal integer
   between 1 and 64 inclusive.
3. `create` names a path that does not exist at that point in the session;
   `edit`, `delete` and `touch` name paths that do exist. Every `PATH` on a
   session line is a valid workspace path.
4. Build files (`main.kiln` and anything `include`d) are valid UTF-8 and contain
   no `0x0D` bytes. They may contain non-ASCII text, inside string literals and
   inside comments.
5. Source file contents are arbitrary byte sequences. Contents created by
   `create`/`edit` are valid UTF-8 without `0x0D`; contents produced by commands
   can be anything, including `0x00` bytes via `write("\0")`.
6. No `@need` directive ever names a path that is some step's declared output or
   depfile — discovered dependencies are always source files. (They may,
   however, be build files, and the tests use that.)
7. No integer computation in any test overflows a signed 64-bit integer.
8. No test relies on behaviour this document leaves unspecified. In particular,
   every glob pattern, every path string and every state file is either valid as
   specified or is there precisely to trigger one of the documented errors.
9. Rule instantiation nests at most 64 deep except in the one family of tests
   that exercises `E_RULE_RECURSION`.
10. Every path is at most 1024 bytes and every component at most 255 bytes.
    At no point in a session does the workspace hold both a file at `p` and a
    file whose path begins with `p/`, and no two workspace paths ever differ
    only in the case of ASCII letters, so every final workspace can be written
    to any real file system.
11. A `build` line target that is neither `@` followed by an
    identifier-shaped name nor a valid workspace path simply resolves to
    nothing and yields `E_UNKNOWN_TARGET`; it is never an `E_BAD_PATH`.
12. `glob`, `filter` and `reject` are evaluated against the workspace as it
    stands when the expression is evaluated, which during a build is before any
    command of that build has run.

---

## Architecture and size

A complete implementation has eleven parts. The line counts are for a typical
systems language with braces, not counting tests.

1. **Lexer** (~400 lines) — comment stripping with string awareness, logical
   line assembly by bracket depth, tokenisation, and the string-literal reader
   with escapes and interpolation scanning.
2. **Parser** (~900 lines) — line-classified statement parsing, block stack
   with the `} elsewhen` / `} otherwise` forms, a precedence-climbing expression
   parser for eleven levels, and the `step` field parser.
3. **Values and evaluator** (~1200 lines) — the four value types, the total
   order, deep equality, scopes with parent links, short-circuit operators,
   interpolation, indexing, the statement interpreter, `include` handling with a
   stack, rules with captured scopes, and `use` argument binding with defaults.
4. **Built-in functions** (~1200 lines) — 39 functions with exact typing, plus
   the glob matcher used by three of them.
5. **Step construction and validation** (~500 lines) — field accumulation,
   path validation, `out`-tree enforcement, command shape and argument checks,
   serial assignment.
6. **Graph building** (~600 lines) — duplicate output detection, reference
   resolution over three node kinds, successor lists, the deterministic DFS for
   cycles, reachability.
7. **Virtual file system and hashing** (~300 lines) — the path→content map,
   loading from and writing to a real directory, FNV-1a 64.
8. **Commands** (~900 lines) — the sixteen command implementations, line
   splitting and joining, and `preprocess` with its recursive expansion, need
   stack and discovered set.
9. **State file** (~500 lines) — strict reader with total rejection on any
   deviation, canonical writer, canonical command-string rendering with
   escaping, and the freshness decision.
10. **Scheduler** (~500 lines) — pending counts, instant nodes, the hit-settling
    loop, worker allocation, clock advance, failure and cancellation, event
    recording and sorting.
11. **Session driver and log writer** (~600 lines) — session parsing, the six
    step kinds, `clean`, log formatting, error rendering for 30 kinds, and the
    final output tree.

Plus shared error plumbing and the main program: perhaps another 400 lines.
Total: roughly **8,000 to 11,000 lines**. A terse Python version of the same
design — the reference implementation — is about 3,200 lines, because the value
model, the dispatch tables and the byte-string handling all collapse into
built-in types.

Suggested order of work: the virtual file system and hashing first, then the
lexer and parser (they are the largest single risk), then the evaluator and
built-ins, then steps and the graph, then the commands, then the state file and
freshness, then the scheduler, and the session driver last. Examples 1, 3 and 8
exercise, in that order, the minimum viable engine, the scheduler and the
incremental machinery.

---

## Limits and performance

- The largest session has 400 steps; the median has 6. (Sessions in the long
  benchmark tier, `bench-long/`, have up to 5,000 steps.)
- The largest build file set evaluates to 2,400 steps, 120 phony targets and
  11,000 declared inputs, spread over 24 `include`d files. The largest single
  build file is 180 KB.
- The largest `glob` is evaluated against a workspace of 3,000 files.
- No single file in any workspace exceeds 256 KB; no workspace exceeds 6 MB in
  total.
- Worker counts range from 1 to 64; simulated completion times stay well below
  2^31.
- The largest output tree has about 3,600 files.

A straightforward implementation — re-evaluating the build files for every
`build` step, hashing every file it needs when it needs it, and simulating the
scheduler event by event — is fast enough. A 60-second per-test limit is ample
for a compiled implementation. The one thing worth care is not rehashing the
same file content repeatedly within a single build: cache hashes by path and
invalidate on write.
