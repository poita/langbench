# langvm — a compiler and stack VM for Vellum

Read a multi-module **Vellum** program from stdin, compile it, and run it.
Everything the program prints goes to stdout. If the program does not compile,
print exactly one diagnostic line and nothing else. If it compiles but fails at
run time, print everything it printed up to that point followed by one panic
line. The exit code is always 0 — a program that is rejected or that panics is
a normal result of this tool, not a failure of the process.

Vellum is a statically typed language with modules, structs, sum types with
exhaustive pattern matching, generic functions, traits with implementations,
closures, 64-bit integers with wrapping overflow, IEEE-754 doubles with an
exactly specified printing rule, lists, insertion-ordered maps, and a standard
library of 132 built-in functions. The language is defined entirely by this
document; nothing is inherited from any other language, and where a rule looks
familiar it is still the rule written here that applies.

This is a **stdin-mode** problem: all input arrives on stdin, all output goes
to stdout, no files are read or written, and no command-line arguments are
passed. The problem needs no data files.

## Contents

1. [I/O contract](#1-io-contract)
2. [Input: the module stream](#2-input-the-module-stream)
3. [Lexical structure](#3-lexical-structure)
4. [Grammar](#4-grammar)
5. [Modules, items and visibility](#5-modules-items-and-visibility)
6. [Types](#6-types)
7. [Built-in traits: Eq, Ord and Key](#7-built-in-traits-eq-ord-and-key)
8. [Traits and impls](#8-traits-and-impls)
9. [Type checking and inference](#9-type-checking-and-inference)
10. [Expressions](#10-expressions)
11. [Statements and control flow](#11-statements-and-control-flow)
12. [Patterns, matching and exhaustiveness](#12-patterns-matching-and-exhaustiveness)
13. [Diagnostics](#13-diagnostics)
14. [Runtime semantics](#14-runtime-semantics)
15. [Standard library](#15-standard-library)
16. [Bytecode and the virtual machine](#16-bytecode-and-the-virtual-machine)
17. [Worked examples](#17-worked-examples)
18. [Limits, guarantees and performance](#18-limits-guarantees-and-performance)
19. [Architecture and size](#19-architecture-and-size)

## 1. I/O contract

- The whole of stdin is one *module stream* (section 2). It is UTF-8.
- stdout is UTF-8 with LF (`\n`) line endings and no byte-order mark.
- Nothing is written to stdout except what this document says: the program's
  own output, a panic line, or a single diagnostic line.
- Anything written to stderr is ignored.
- The exit code is 0 in every case described here.

Exactly one of three things happens:

**Compile error.** The program is rejected. stdout is exactly one line:

```
error: <kind> at <line>:<col>
```

`<kind>` is one of the kinds in [section 13](#13-diagnostics), `<line>` and
`<col>` are decimal integers with no padding and no sign. Nothing else is
printed — not even output the program "would have" produced, since nothing
runs. When a program contains several errors, the one reported is determined
by the pass and traversal order in section 13; this is fully defined, and a
conforming implementation prints the same line as every other.

**Successful run.** The program compiles; `main` in module `main` is called;
the program's output is whatever its `print` and `emit` calls wrote, in order.
When `main` returns the process ends.

**Panic.** The program compiles and starts, then hits a runtime error. stdout
holds everything printed before the panic, then one more line:

```
panic: <message>
```

The exact messages are listed in [section 14.6](#146-panics). Execution stops
immediately; nothing is printed after the panic line.
The panic text is appended directly to what was already written: if the last
output was an `emit` that did not end in an LF, `panic: ` continues that same
line (no LF is inserted before it).

## 2. Input: the module stream

The input is split into *modules* before any lexing happens.

Line splitting: a line ends at an LF (U+000A); a single CR (U+000D)
immediately before that LF is removed and is not part of the line. The final
line need not be terminated. An empty input has no lines.

A **module header** is a line consisting of exactly:

```
@module <name>
```

that is, the seven characters `@module`, one space (U+0020), and a module
`<name>` which is an identifier (section 3.3) — nothing else, not even
trailing spaces or tabs. A line that begins with `@` but does not match this
exactly — a keyword or `_` in place of the name, a name longer than 200
characters, two spaces, a trailing space, anything after the name — is not a
module header.

Splitting rules, checked in this order:

1. If the input has no lines, or its first line is not a module header, the
   program is rejected with `error: bad-module at 1:1`.
2. Every line whose first character is `@` must be a module header; if one is
   not, the program is rejected with `error: bad-module at L:1`, where `L` is
   that line's 1-based position **in the whole input**, for the smallest such
   `L`. (Rules 1 and 2 are applied together: scan lines from the first to the
   last and report the first violation of either.)
3. A module's **body** is the lines strictly after its header up to, but not
   including, the next module header (or the end of input). A body may be
   empty.
4. If two headers name the same module, the program is rejected with
   `error: dup-module at L:1` where `L` is the whole-input line number of the
   **second** such header (and, if several names repeat, the smallest such
   `L`).

`bad-module` and `dup-module` are the only diagnostics that use whole-input
line numbers. **Every other diagnostic uses line numbers local to the module
it occurs in: line 1 of a module is the first line after its header.** Columns
are 1-based counts of Unicode scalar values from the start of the line (a tab
is one column).

Modules keep the order in which they appear; that order matters for
diagnostics (section 13) and for nothing else.

A program must contain a module named `main` that declares a function named
`main` with no type parameters, no parameters, and return type `Unit`
(explicitly `-> Unit` or omitted). Otherwise the program is rejected with
`error: no-main at 1:1`. `main` need not be `pub`.

Example of a two-module stream:

```
@module main
use util;

fn main() {
    print(util::greet("world"));
}
@module util
pub fn greet(who: Str) -> Str {
    "hello, " ++ who
}
```

## 3. Lexical structure

Each module body is lexed independently into a token list. Positions are
module-local (section 2).

### 3.1 Whitespace and comments

- Whitespace is space (U+0020), tab (U+0009), LF and CR. It separates tokens
  and is otherwise ignored.
- A **line comment** starts at `//` and runs to (not including) the next LF or
  the end of the module.
- A **block comment** starts at `/*` and ends at the matching `*/`. Block
  comments **nest**: `/* a /* b */ c */` is one comment. An unterminated block
  comment is `unterminated` at the position of its outermost `/*`.
- `/` that begins neither a comment nor the `/` operator is impossible: a `/`
  not followed by `/` or `*` is the division operator.

### 3.2 Keywords

```
as  break  continue  else  enum  false  fn  for  if  impl  in  let  match
pub  return  self  struct  trait  true  use  var  when  while
```

Keywords are reserved: they are never identifiers. `Self` is **not** in this
list; it is a reserved type name (section 6).

### 3.3 Identifiers

An identifier is an ASCII letter or `_` followed by zero or more ASCII
letters, digits or `_`, and is not a keyword. Identifiers are case-sensitive.
A lone `_` is **not** an identifier: it is the wildcard token, usable only as
a pattern. Identifiers are at most 200 characters; longer is `bad-token` at
the identifier's first character.

### 3.4 Integer literals

```
dec = digit { digit | "_" }
hex = "0x" hexdigit { hexdigit | "_" }
bin = "0b" ( "0" | "1" ) { "0" | "1" | "_" }
```

`_` separators are ignored; they may not lead the digits and may not follow
the `0x`/`0b` prefix (`0x_1` is `bad-token` at the literal's first character).
The prefixes are lowercase only, so `0X1` is the integer `0` followed by the
identifier `X1`. A `0x` or `0b` not followed by at least one digit of its base
is `bad-token` at the literal's first character.
`digit` is `0`–`9`; `hexdigit` is `0`–`9`, `a`–`f`, `A`–`F`. A literal's value
is non-negative; if it exceeds 9223372036854775807 the module is rejected with
`int-range` at the literal's first character. There is no negative literal:
`-5` is unary minus applied to `5`. A decimal literal may have leading zeros
(`007` is 7).

A numeric literal ends where its grammar ends and nothing checks what follows,
so `123abc` is the integer `123` followed by the identifier `abc` (which the
parser then rejects).

### 3.5 Float literals

```
float = dec "." dec [ exp ] | dec exp
exp   = ( "e" | "E" ) [ "+" | "-" ] digit { digit | "_" }
```

Every digit run — the integer part, the fraction and the exponent — allows
`_` separators under the rules above: a `_` may follow a digit, but no run
starts with one. So `1_.5` is 1.5, `1e1_0` is 1e10, and `1e_5` is the integer
`1` followed by the identifier `e_5`. A `.` must be
followed by at least one digit to be part of a float, so `1.` lexes as the
integer `1` followed by `.`, and `0..3` lexes as `0`, `..`, `3`. Likewise an
`e` or `E` is part of the number only when an optional sign and at least one
digit follow it, so `1e` lexes as the integer `1` followed by the identifier
`e`.

The value is the IEEE-754 binary64 number nearest the literal's exact decimal
value, ties to even. A literal too large for binary64 becomes the
corresponding infinity; one too small becomes a subnormal or ±0.0 under the
same rounding. A float literal is never `int-range`.

### 3.6 Character literals

`'` c `'` where c is either one character other than `'`, `\`, LF or CR, or an
escape (section 3.8). The value is that Unicode scalar value. An empty `''`,
an unterminated literal, a raw LF or CR inside one, or more than one character
is `unterminated` at the opening `'`.

Precisely: after the opening `'` the lexer reads one character or one escape
(an escape error is `bad-escape` at once), and the next character must then
be `'`; if it is not, the literal is `unterminated` at the opening `'`. So
`'ab'` and `'a\q'` are `unterminated`, while `'\q'` is `bad-escape`.

### 3.7 String literals

`"` followed by zero or more characters or escapes, followed by `"`. A raw LF
or CR inside a string literal, or reaching the end of the module first, is
`unterminated` at the opening `"`. The value is the sequence of Unicode scalar
values produced. A string literal may be empty. A string is scanned from left
to right and the first problem met decides the error: in `"ab\q` (never
closed) the bad escape is met first, so it is `bad-escape`.

### 3.8 Escapes

Inside character and string literals:

| Escape | Meaning |
|---|---|
| `\n` | U+000A |
| `\t` | U+0009 |
| `\r` | U+000D |
| `\0` | U+0000 |
| `\\` | U+005C |
| `\'` | U+0027 |
| `\"` | U+0022 |
| `\u{H…}` | the scalar with that hex value, 1 to 6 hex digits |

Any other character after `\` is `bad-escape` at the position of the
backslash; so is a `\` that is the last character of the module. A `\u{…}`
whose value exceeds 0x10FFFF, or lies in 0xD800–0xDFFF, or has no digits or
more than 6, or is missing the `}`, is also `bad-escape` at the backslash.
Hex digits in `\u{…}` may be upper or lower case.

### 3.9 Operators and punctuation

Tokens are matched greedily longest-first:

```
#[  ::  ..  ->  ==  !=  <=  >=  &&  ||  <<  >>  ++
(  )  [  ]  {  }  ,  ;  :  .  |  +  -  *  /  %  !  ~  &  ^  <  >  =  _
```

Notes:

- `#[` is a single token, used for map literals and map types; a `#` not
  followed by `[` is `bad-token`.
- `||` is a single token. It is the only spelling of a lambda with no
  parameters (section 4.5): two separate `|` tokens with nothing between them,
  as in `| | 8`, are not a lambda, and the second `|` is a `parse` error.
- `>>` is a single token. Because the only `<` `>` pairs in the grammar are
  generic parameter and argument lists in *declarations and types* (never in
  expressions), `>>` never needs splitting: a type like `[[Int]]` uses
  brackets, and `A<B<C>>` is written in a type position where the parser
  accepts the `>>` token as two closing angle brackets (section 4.2).
- Any character that starts no token above is `bad-token` at that character.

## 4. Grammar

The grammar below is EBNF over the token stream: `{ x }` is zero or more,
`[ x ]` is optional, `|` alternates, quoted items are tokens, and `ident`,
`int`, `float`, `str`, `char` are the literal token classes. The parser is a
plain recursive-descent parser; every parse failure is the single diagnostic
`parse` at the position of the token that could not be accepted (the position
one past the last token, column = the last line's length + 1, when the input
ends early).

### 4.1 Items

```
ModuleBody = { Item } ;
Item       = Use | FnDecl | StructDecl | EnumDecl | TraitDecl | ImplDecl ;

Use        = "use" ident [ "as" ident ] ";" ;

FnDecl     = [ "pub" ] "fn" ident [ Generics ] "(" [ Params ] ")"
             [ "->" Type ] Block ;
Params     = Param { "," Param } [ "," ] ;
Param      = ident ":" Type ;

Generics   = "<" GenParam { "," GenParam } [ "," ] ">" ;
GenParam   = ident [ ":" Bounds ] ;
Bounds     = TraitRef { "+" TraitRef } ;
TraitRef   = ident | ident "::" ident ;

StructDecl = [ "pub" ] "struct" ident [ Generics ] "{" [ Fields ] "}" ;
Fields     = Field { "," Field } [ "," ] ;
Field      = ident ":" Type ;

EnumDecl   = [ "pub" ] "enum" ident [ Generics ] "{" [ Variants ] "}" ;
Variants   = Variant { "," Variant } [ "," ] ;
Variant    = ident [ "(" Type { "," Type } [ "," ] ")" ] ;

TraitDecl  = [ "pub" ] "trait" ident "{" { MethodSig } "}" ;
MethodSig  = "fn" ident "(" "self" [ "," Params ] ")" [ "->" Type ]
             ( ";" | Block ) ;

ImplDecl   = "impl" [ Generics ] TraitRef "for" Type "{" { ImplMethod } "}" ;
ImplMethod = "fn" ident "(" "self" [ "," Params ] ")" [ "->" Type ] Block ;
```

A trait method with a `Block` has a **default body**; one with `;` does not.
`pub` is not permitted on an `impl` or on a method.

### 4.2 Types

```
Type     = "[" Type "]"
         | "#[" Type ":" Type "]"
         | "(" Type "," Type { "," Type } [ "," ] ")"
         | "fn" "(" [ Type { "," Type } [ "," ] ] ")" [ "->" Type ]
         | TypePath [ TypeArgs ] ;
TypePath = ident | ident "::" ident ;
TypeArgs = "<" Type { "," Type } [ "," ] ">" ;
```

A parenthesised single type is not a type (`(Int)` is a `parse` error); a
tuple needs at least two components. `fn(Int)` means `fn(Int) -> Unit`. When
closing `TypeArgs`, a `>>` token closes two argument lists at once and a `>`
closes one; no other splitting occurs.

The primitive type names `Int`, `Float`, `Bool`, `Char`, `Str`, `Unit` and the
name `Self` are ordinary `ident` tokens that the *resolver* treats specially
(section 6).

### 4.3 Blocks and statements

```
Block    = "{" BlockBody "}" ;
```

`BlockBody` is parsed as follows. Repeat until the next token is `}`:

- `let`, `var`, `return`, `while`, `for`, `break`, `continue` begin the
  corresponding statement and are parsed as such.
- Otherwise parse an `Expr` E, then:
  - if the next token is `=`, this is an assignment: E must be a legal target
    form (an `ident` expression or an index expression — anything else is
    `bad-target` at the position of E, reported in the body pass of
    section 13), then parse `Expr` and expect `;`;
  - else if the next token is `;`, consume it: E is an expression statement;
  - else if the next token is `}`, E is the block's **trailing expression** and
    the body ends;
  - else if E's outermost form is `if` or `match`, E is an expression statement
    with no semicolon;
  - else `parse` at the next token.

Because E is always parsed as a whole `Expr`, an `if` or `match` statement
written without a `;` is continued by whatever binary operator or suffix
follows it, even on the next line: in

```
    if c { f() } else { g() }
    (1, 2);
```

the tuple is parsed as the argument list of a call whose callee is the `if`
expression (so the checker reports `not-callable` at the `if`), and a following
line starting with `-`, `[` or `.` is likewise a binary minus, an index or a
field access applied to the `if`. Write a `;` after such a statement to end it.

```
Let      = "let" Pattern [ ":" Type ] "=" Expr ";" ;
Var      = "var" ident [ ":" Type ] "=" Expr ";" ;
Return   = "return" [ Expr ] ";" ;
While    = "while" Expr Block ;
For      = "for" Pattern "in" Expr [ ".." Expr ] Block ;
Break    = "break" ";" ;
Continue = "continue" ";" ;
```

In `While`, `For` and the conditions of `if`, the expression is parsed in
**no-struct-literal context**: see section 4.4 — in practice this costs
nothing, because a struct literal needs an explicit `.` before its `{`.

### 4.4 Expressions

Precedence, lowest first; all binary levels are left-associative except
comparison, which is non-associative:

| Level | Operators | Associativity |
|---|---|---|
| 1 | `or` (spelled `\|\|`) | left |
| 2 | `&&` | left |
| 3 | `==` `!=` `<` `<=` `>` `>=` | none |
| 4 | bitwise or (spelled `\|`) | left |
| 5 | `^` | left |
| 6 | `&` | left |
| 7 | `<<` `>>` | left |
| 8 | `+` `-` `++` | left |
| 9 | `*` `/` `%` | left |
| 10 | prefix `-` `!` `~` | right |
| 11 | postfix call, index, field, method | left |

Note that the bitwise operators bind **tighter** than comparison, so
`a & b == c` is `(a & b) == c`. A chain such as `a < b < c` is a `parse` error
at the second comparison operator.

```
Expr     = Or ;
Or       = And { "||" And } ;
And      = Cmp { "&&" Cmp } ;
Cmp      = BitOr [ ( "==" | "!=" | "<" | "<=" | ">" | ">=" ) BitOr ] ;
BitOr    = BitXor { "|" BitXor } ;
BitXor   = BitAnd { "^" BitAnd } ;
BitAnd   = Shift { "&" Shift } ;
Shift    = Add { ( "<<" | ">>" ) Add } ;
Add      = Mul { ( "+" | "-" | "++" ) Mul } ;
Mul      = Unary { ( "*" | "/" | "%" ) Unary } ;
Unary    = ( "-" | "!" | "~" ) Unary | Postfix ;
Postfix  = Primary { Suffix } ;
Suffix   = "(" [ Args ] ")"
         | "[" Expr "]"
         | "." ident [ "(" [ Args ] ")" ] ;
Args     = Expr { "," Expr } [ "," ] ;

Primary  = int | float | str | char | "true" | "false" | "self"
         | "(" Expr ")"
         | "(" Expr "," Expr { "," Expr } [ "," ] ")"
         | "[" [ Args ] "]"
         | "#[" [ MapEntry { "," MapEntry } [ "," ] ] "]"
         | Lambda
         | IfExpr
         | MatchExpr
         | ValuePath [ "." "{" [ FieldInits ] "}" ] ;
MapEntry = Expr ":" Expr ;
ValuePath  = ident | ident "::" ident ;
FieldInits = FieldInit { "," FieldInit } [ "," ] ;
FieldInit  = ident ":" Expr ;
```

A `ValuePath` immediately followed by the two tokens `.` `{` is a **struct
literal**; this is the only place `.` `{` occurs, so no ambiguity with blocks
arises and the "no-struct-literal context" of section 4.3 is vacuous.

Parentheses around a single expression are transparent: `"(" Expr ")"` is the
inner expression itself, not a separate node. Its position is the inner
expression's first token (not the `(`), its outermost form is the inner
expression's (so a parenthesised `if` or `match` also ends a statement
without a `;`), and it is typed, checked and evaluated exactly as the inner
expression. `.`
followed by an `ident` is a field access, and `.` `ident` `(` is a method
call.

```
IfExpr    = "if" Expr Block [ "else" ( Block | IfExpr ) ] ;
MatchExpr = "match" Expr "{" [ Arms ] "}" ;
Arms      = Arm { "," Arm } [ "," ] ;
Arm       = Pattern [ "when" Expr ] "->" ( Block | Expr ) ;
```

`return`, `break` and `continue` are **statements**, not expressions, so an
arm (or an `if` branch) that wants to leave the function writes a block:
`None -> { return 0; }`.

When an arm's body is a `Block`, the `,` separating it from the next arm may
be omitted. (Formally: after an arm, accept an optional `,`; if it is absent,
the next token must be `}`, or the arm just parsed must have had a block
body.)

### 4.5 Lambdas

```
Lambda   = ( "||" | "|" LParams "|" ) [ "->" Type ] ( Block | Expr ) ;
LParams  = LParam { "," LParam } [ "," ] ;
LParam   = ident [ ":" Type ] ;
```

The token `||` in a position where a `Primary` is expected starts a lambda
with no parameters. If the token after the parameter list (and optional
`-> Type`) is `{`, the body is a `Block`; otherwise it is an `Expr`.

### 4.6 Patterns

```
Pattern   = "_"
          | int | "-" int | float | "-" float
          | str | char | "true" | "false"
          | "(" Pattern "," Pattern { "," Pattern } [ "," ] ")"
          | "[" [ Pattern { "," Pattern } [ "," ] ]
                [ ".." [ ident ] ] "]"
          | ValuePath "." "{" [ FieldPats ] [ ".." ] "}"
          | ValuePath [ "(" Pattern { "," Pattern } [ "," ] ")" ]
          | ident ;
FieldPats = FieldPat { "," FieldPat } [ "," ] ;
FieldPat  = ident [ ":" Pattern ] ;
```

In a list pattern, a `..` rest may appear **only after all element
patterns**, at most once, and the element patterns before it must be followed
by a `,` as usual (`[a, b, ..rest]`, `[a, ..]`, `[..]`, `[..rest]`). A `..`
elsewhere is `parse`. In a struct pattern, the trailing `..` (meaning
"ignore the remaining fields") must come last. `FieldPat` with no `:` binds
the field's value to a variable of the field's name.

A bare `ident` pattern is a **variable binding** unless the name resolves to a
zero-argument enum variant, in which case it is that variant's pattern; see
section 12.1.

A float literal parses as a pattern so that it can be rejected with a precise
kind, and is always `bad-pattern` in the body pass (section 12.1).

### 4.7 A complete small module

```
@module main
struct Vec2 { x: Int, y: Int }

enum Step { Go(Vec2), Stop }

fn apply(p: Vec2, s: Step) -> Vec2 {
    match s {
        Go(d) -> Vec2.{ x: p.x + d.x, y: p.y + d.y },
        Stop -> p,
    }
}

fn main() {
    var p = Vec2.{ x: 0, y: 0 };
    let steps = [Go(Vec2.{ x: 1, y: 2 }), Stop, Go(Vec2.{ x: -3, y: 4 })];
    for s in steps {
        p = apply(p, s);
    }
    print(fmt("({}, {})", [showInt(p.x), showInt(p.y)]));
}
```

prints `(-2, 6)`.

## 5. Modules, items and visibility

### 5.1 Namespaces

Each module has four independent namespaces:

- **types** — struct and enum names declared in the module;
- **traits** — trait names declared in the module;
- **values** — function names and *enum variant* names declared in the module;
- **imports** — the names introduced by `use` (the module's own name, or its
  `as` alias).

A name may appear once per namespace per module. Two items in the same module
and namespace with the same name are `dup-name` at the position of the
**second** one's name token (for a variant, at the variant's name token). The
same name in different namespaces is allowed: a module may have a struct
`Pair` and a function `Pair`.

A module's items are visible throughout the module regardless of declaration
order: a function may call one declared later, a struct may name an enum
declared below it, and recursion and mutual recursion need no forward
declarations.

### 5.2 The prelude

Every module additionally sees the **prelude**, which contains:

- the primitive type names `Int`, `Float`, `Bool`, `Char`, `Str`, `Unit`;
- the reserved type name `Self`;
- the type names `Option` and `Result`, declared exactly as if by

```
pub enum Option<T> { Some(T), None }
pub enum Result<T, E> { Ok(T), Err(E) }
```

  together with the variant names `Some`, `None`, `Ok`, `Err` in the values
  namespace;

- the trait names `Eq`, `Ord`, `Key` (section 7);
- the 132 built-in function names of section 15 in the values namespace.

A module item shadows a prelude name of the same namespace, and that is not an
error: a module may declare `fn print(x: Int)`, or `enum Option<T> { … }`, and
within that module the module's own meaning wins (including inside its own
`Option`'s variant names if it declares them). The six primitive type names
and `Self` are **reserved**: declaring a struct or enum with one of those
seven names is `reserved-name` at the name token. Trait names `Eq`, `Ord` and
`Key` may be shadowed by a module's own trait of that name, in which case the
built-in trait is not nameable in that module; the built-in requirements of
`==`, `<` and map keys still use the built-in traits.

Prelude `Option` and `Result` used from another module are never re-exported:
`other::Some` resolves only if module `other` itself declares a variant
`Some`.

### 5.3 use declarations

`use m;` adds `m` to the module's imports namespace, bound to the module named
`m`. `use m as k;` binds `k` instead. If no module in the stream is named `m`,
this is `unknown-module` at the position of `m`. A duplicate import name is
`dup-name` at the second one. A module may import itself. Importing the same
module twice under different aliases is allowed. `use` declarations may appear
anywhere among the items; their position in the file does not matter.

Import cycles are allowed: modules form one compilation unit, and there is no
initialisation order to get wrong because modules contain no mutable state.

### 5.4 Qualified paths

A path `a::b` (in a type, an expression, a trait bound or a pattern) resolves
in this order:

1. If `a` is in the current module's imports namespace, `b` must be an item of
   that module in the namespace required by the context (types, traits or
   values). If no such item exists: `unknown-type`, `unknown-trait` or
   `unknown-name` at the position of `b`. If the item exists but is not `pub`
   and the imported module is not the current module: `not-public` at the
   position of `b`.
2. Otherwise, if the context is a value and `a` is a trait name visible in the
   current module (section 8.1) — including `Eq`, `Ord` and `Key`, which are
   visible everywhere — `a::b` is the trait method `b` of that trait — see
   section 8.5. If the trait has no method `b`: `unknown-name` at `b` (so any
   `Eq::b` is `unknown-name`, since the built-in traits have no methods).
3. Otherwise: `unknown-module` at the position of `a`.

An unqualified name resolves in the namespace required by the context, looking
first at local bindings (for values, section 11.1), then at the current
module's items, then at the prelude. Failure is `unknown-name`,
`unknown-type` or `unknown-trait` at the name's position.

An unqualified **type** name is looked up in this order: the type parameters
in scope (those of the enclosing function, or of the enclosing `impl` for an
impl method), then `Self`, then the six primitive names, then the current
module's types, then the prelude's `Option` and `Result`. A type parameter
therefore hides everything else of the same name — in `fn f<T>(x: T)` the `T`
is the parameter even if the module declares a struct `T`, and a parameter may
even be named `Int` or `Self` (it is not `reserved-name`; within that
declaration the name means the parameter).

When rule 2 above looks for "a trait name visible in the current module", the
candidates are tried in this order and the first trait with that name is
used: the current module's own traits; then the `pub` traits of the imported
modules, taking the imports in increasing order of their bound name (the alias
if there is one, else the module name), compared character by character by
ASCII code (the current module importing itself is skipped); and only then
the built-in `Eq`, `Ord` and `Key`. So with `use za; use ab;` and a `pub
trait Shape` in each, `Shape::m` means `ab`'s trait, and a module's own (or an
imported) trait named `Eq` hides the built-in one in this position.

Throughout this document **the current module** means the module whose source
text contains the construct being resolved — for a trait default body, the
trait's module; for an impl method, the impl's module; never the module where
a value's type happens to be declared.

### 5.5 Visibility

`pub` on a function, struct, enum or trait makes it importable by other
modules. Without `pub` an item is usable only inside its own module. For a
`pub` struct, all fields are public; for a `pub` enum, all variants are
public; for a `pub` trait, all methods are public. There is no finer
granularity.

An `impl` has no visibility of its own and is never named; it is registered
program-wide (section 8.3). The trait it implements must be visible in the
module containing the `impl` (declared there, or `pub` in a module that module
imports), otherwise the usual `unknown-trait` / `not-public` applies, and so
must the type it implements it for.

## 6. Types

### 6.1 The type language

A *semantic type* is one of:

| Form | Written | Notes |
|---|---|---|
| primitive | `Int` `Float` `Bool` `Char` `Str` `Unit` | |
| list | `[T]` | homogeneous, mutable, reference semantics |
| map | `#[K: V]` | `K` must satisfy `Key`; insertion-ordered |
| tuple | `(T1, …, Tn)` | `2 <= n <= 8` |
| function | `fn(T1, …, Tn) -> R` | `0 <= n <= 16` |
| named | `N` or `N<T1, …, Tk>` | a struct or enum declaration plus arguments |
| parameter | `T` | a generic parameter of the enclosing declaration |

A tuple type with fewer than 2 or more than 8 components, or a function type
with more than 16 parameters, is `parse` (the grammar forbids 0- and 1-tuples)
or `bad-arity` at the type's first token for the over-long cases.

Writing a named type with the wrong number of type arguments — including
writing a generic type with none, or a non-generic type with some — is
`arity-type` at the type's first token. Writing type arguments on something
that takes none at all — a primitive name, `Self`, or a generic parameter —
is `arity-type` too. `Self` is the implementing type inside
a trait declaration or an `impl` (section 8), and `self-outside` at its
position anywhere else.

A map type `#[K: V]` requires `K` to satisfy `Key` (section 7.3). If `K` is a
concrete type that does not, or a generic parameter without a `Key` bound,
that is `bad-key-type` at the `#[` token.

Order of these checks when a written type is resolved: for `#[K: V]`, `K` is
resolved, then `V`, and only then is `K` checked for `Key` (so in
`#[Float: Nope]` the `unknown-type` at `Nope` wins). For a tuple or function
type the too-many-parts `bad-arity` check comes before any part is resolved,
and for a named type the `arity-type` check comes before any type argument is
resolved. Otherwise the parts are resolved left to right.

Two types are **equal** iff they have the same form and equal parts; named
types are equal iff they refer to the same declaration (same module, same
name) and have equal arguments. There are no subtypes, no coercions, no
numeric promotions: `Int` and `Float` never mix, `Char` and `Str` never mix,
and a 1-element list is not a value of any other type.

### 6.2 Declarations and generics

A struct declares an ordered list of fields; a field's type may mention the
struct's own type parameters and may refer to the struct itself (directly or
through other types), which is allowed and simply means the type has no
finite values unless the recursion passes through `Option`, a list, or a map.

An enum declares an ordered list of variants, each with 0 to 8 payload types.

Type parameters of a struct or enum may **not** carry bounds (`struct S<T:
Eq> { … }` is `parse` at the `:`) — bounds exist only on functions and impls.
Duplicate type parameter names, duplicate field names, duplicate variant
names within one enum, duplicate parameter names in one signature and
duplicate method names in one trait or impl are each `dup-name` at the second
occurrence.

Generic parameters are **rigid** inside the body they belong to: within

```
fn pick<T>(a: T, b: T, first: Bool) -> T { if first { a } else { b } }
```

`T` is an opaque type that equals only itself. At a call site, `T` is replaced
by an inferred type (section 9).

### 6.3 Values of each type

| Type | Values |
|---|---|
| `Int` | the 2^64 two's-complement integers in [-2^63, 2^63) |
| `Float` | IEEE-754 binary64, including ±0.0, ±inf, NaN |
| `Bool` | `true`, `false` |
| `Char` | one Unicode scalar value: 0–0x10FFFF excluding 0xD800–0xDFFF |
| `Str` | a finite sequence of Unicode scalar values |
| `Unit` | one value, written nowhere and produced by functions that return nothing |
| `[T]` | a mutable, growable sequence of `T` values, with identity |
| `#[K: V]` | a mutable insertion-ordered map, with identity |
| `(T1,…,Tn)` | immutable tuples |
| `fn(…) -> R` | closures |
| named | struct instances (immutable) and enum values (immutable) |

`Str` is a sequence of **scalar values**, not bytes: `strLen("héllo")` is 5 and
`charAt("héllo", 1)` is `'é'`.

## 7. Built-in traits: Eq, Ord and Key

Three traits are built in. They have no methods, cannot be implemented by
user code (`impl Eq for …` is `builtin-trait-impl` at the `impl` keyword) and
may be used as bounds on functions and impls. Satisfaction is decided
structurally by the rules below.

### 7.1 Eq

`Eq` holds for: `Int`, `Float`, `Bool`, `Char`, `Str`, `Unit`; `[T]` if `Eq`
holds for `T`; `#[K: V]` if `Eq` holds for `V`; a tuple if `Eq` holds for every
component; a struct type if `Eq` holds for every field type after substituting
the type arguments; an enum type if `Eq` holds for every payload type after
substitution. `Eq` never holds for a function type.

Named types may be recursive, so satisfaction is computed with an assumption
set: when asking whether `Eq` holds for a named type whose **declaration** is
already being asked about further up the current query, answer *yes* (the
assumption set holds declarations, not declarations plus arguments, which
keeps the query finite for a type that instantiates itself at a new
argument). (So
`struct Node { next: Option<Node>, v: Int }` satisfies `Eq`, and
`struct Bad { f: fn(Int) -> Int }` does not.)

For a rigid generic parameter `T`, `Eq` holds iff `T`'s declared bounds
include `Eq` or `Key`.

### 7.2 Ord

`Ord` holds for exactly `Int`, `Float`, `Bool`, `Char` and `Str`, and for a
rigid parameter whose bounds include `Ord`. Nothing else is `Ord` — ordering
comparisons on tuples, lists, maps, structs and enums are `not-ord` errors;
use the `cmp…` helpers and `sortBy` instead.

### 7.3 Key

`Key` holds for exactly `Int`, `Bool`, `Char` and `Str`, and for a rigid
parameter whose bounds include `Key`. `Float` is deliberately excluded.
`Key` implies `Eq`.

### 7.4 Bounds

A bound list is `T: A + B + C`. A bound may name a built-in trait or any
visible user trait. The same trait twice in one list is allowed and
meaningless. A bound naming an unknown or invisible trait is `unknown-trait`
or `not-public`.

"`T: Tr` holds" for a concrete type `T` and user trait `Tr` means: there is an
impl of `Tr` whose head constructor is `T`'s head constructor, and that impl's
own bounds hold under the substitution matching its head to `T` (section 8.4).

## 8. Traits and impls

### 8.1 Trait declarations

```
pub trait Shape {
    fn area(self) -> Int;
    fn name(self) -> Str { "shape" }
}
```

A trait is not generic and its methods are not generic. Each method has
`self` as its first parameter — written exactly `self`, with no type — whose
type is `Self`. Other parameters are explicitly typed; the return type
defaults to `Unit`. A method with a block is a **default method**, usable by
any impl that does not override it; its body is checked once, in the trait's
module, with `Self` as a rigid type parameter whose bounds are exactly
`{the trait itself}`. So inside a default body, `self.otherMethod()` is
allowed for methods of the same trait, and nothing else is assumed about
`Self`.

A trait is visible in a module if the module declares it, or imports a module
in which it is `pub`.

### 8.2 Impl declarations

```
impl Shape for Int { fn area(self) -> Int { self } }
impl<T: Shape> Shape for [T] {
    fn area(self) -> Int {
        var total = 0;
        for s in self { total = total + s.area(); }
        total
    }
    fn name(self) -> Str { "list" }
}
```

The **head** of an impl is the type after `for`. It must be one of:

- a primitive: `Int`, `Float`, `Bool`, `Char`, `Str`, `Unit`;
- `[P]` where `P` is one of the impl's own type parameters;
- `#[P: Q]` where `P` and `Q` are two distinct type parameters of the impl
  (and `P` must have a `Key` bound);
- a visible struct or enum name applied to exactly its arity of *distinct*
  type parameters of the impl: `Pair<A, B>`, `Option<T>`, `Colour`.

Anything else — `[Int]`, `Option<Int>`, `Pair<A, A>`, a tuple type, a function
type, `Self`, a bare type parameter — is `bad-impl-head` at the head type's
first token. (A `#[P: Q]` head whose `P` has no `Key` bound is already
rejected when the head type is resolved, as `bad-key-type` in pass 3.4, so
`bad-impl-head` never has to report it.)

The impl's **head constructor** is `Int`, `Float`, `Bool`, `Char`, `Str`,
`Unit`, `List`, `Map`, or the struct/enum declaration. The impl's type
parameters are exactly the ones in `Generics`; every one of them must appear
in the head, and a parameter that does not is `unused-param` at that
parameter's name token (it could never be determined at a call site).

Inside an impl, `Self` means the head type.

### 8.3 Coherence

Impls are registered program-wide, keyed by (trait, head constructor). Two
impls of the same trait with the same head constructor — in the same module or
in different ones — are `dup-impl` at the `impl` keyword of the second (in
pass order, section 13).

An impl must define exactly the trait's method names: a trait method with no
default body and no impl method is `missing-method` at the `impl` keyword; an
impl method whose name is not a trait method is `extra-method` at the method's
name token.

An impl method's signature must match the trait's after substituting `Self`
with the head type and the impl's parameters: same parameter count, equal
parameter types in order, equal return type. Otherwise `sig-mismatch` at the
impl method's name token.

### 8.4 Satisfying a bound

To decide whether a type `U` satisfies a user trait `Tr`:

0. If `U` is a rigid generic parameter (which happens when a call inside a
   generic body instantiates a parameter with another body's parameter), the
   bound holds iff `Tr` is one of `U`'s declared bounds — inside a trait
   default body, `Self`'s only bound is that trait.
1. Otherwise compute `U`'s head constructor. A tuple type and a function type
   have no head constructor and satisfy no user trait.
2. Look up the impl for (`Tr`, that constructor). If none, the bound fails.
3. Match the impl's head against `U`, binding the impl's parameters (this
   always succeeds when the constructors agree, because heads are distinct
   parameters).
4. Every bound of every impl parameter must hold under that binding,
   recursively. Since each recursive question is about a strictly smaller
   type, this terminates.

A failing bound is reported as `unsatisfied-bound` at the position given by
the rule that asked (section 9.6, 10.9).

### 8.5 Calling methods

Two syntaxes call trait methods, and only trait methods:

**`recv.m(a1, …, an)`.** Resolution, in order:

1. Type-check `recv` (synthesis mode) to get type `R`.
2. Collect every trait visible in the current module that declares a method
   named `m`. If there are none: `no-method` at the position of `m`. If there
   are two or more: `ambig-method` at the position of `m` — use the path form
   to disambiguate.
3. Let `Tr` be that one trait and `sig` its declaration of `m`. If `n` differs
   from `sig`'s parameter count (not counting `self`): `arity` at the
   position of `m`.
4. If `R` is a rigid parameter: `Tr` must be in `R`'s bounds, else
   `unsatisfied-bound` at `m`. The method's signature is `sig` with `Self`
   replaced by `R`.
5. Otherwise `R` must satisfy `Tr` by section 8.4, else `unsatisfied-bound` at
   `m` (this covers "no impl at all"). The signature is `sig` with `Self`
   replaced by `R`, and the impl's own parameters do not appear in it.
6. Check the arguments against the signature's parameter types, left to right
   (section 9.4), and the call's type is the signature's return type.

**`Tr::m(recv, a1, …, an)`.** `Tr` is resolved in the traits namespace
(section 5.4); `m` must be one of its methods (`unknown-name` otherwise); then
steps 3–6 above apply with `R` = the synthesised type of `recv`, except that
the arity error counts `recv`: a call with zero arguments is `arity` at the
position of `m`.

A method is never a value: `x.m` without a `(` parses as a field access, and
so fails with `not-struct` or `unknown-field` rather than naming the method.

### 8.6 Dispatch at run time

The compiler emits a method call as "call method *i* of trait *t*"; the VM
resolves it from the receiver value's own tag to the impl registered for
(trait, head constructor) — a struct or enum value carries its declaration, a
list value is `List`, and so on. There are no vtables stored in values and no
dictionaries passed at run time. Because the type checker has already proved
the bound, resolution always succeeds. A default body is reached when the
impl does not override that method.

## 9. Type checking and inference

Vellum has no whole-program type inference. Every declaration's signature is
written out; inference is **local and bidirectional**, and exists to serve two
purposes only: giving `let` and `var` bindings a type from their initialiser,
and determining the type arguments of a generic call from its arguments and
its expected type.

### 9.1 Two modes

The checker is two mutually recursive functions over expressions:

- `infer(e) -> T` — *synthesis*: work out `e`'s type from `e` alone.
- `check(e, T)` — *checking*: verify `e` against an expected type `T`, which
  may itself contain unresolved inference variables.

Every expression form has a synthesis rule (section 10); a few forms also have
a checking rule, listed in section 9.3. For all other forms,
`check(e, T)` is defined as: `S := infer(e)`, then `unify(T, S)`; if
unification fails, the error is `type-mismatch` at the position of `e`.

Method calls (both syntaxes) and calls of a function *value* have no checking
rule: they use the default rule above, so a mismatch is reported at the whole
call expression's first token — the receiver's for `recv.m(…)`, the trait
name's for `Tr::m(…)`, the callee's for an indirect call.

The mode in which a subexpression is visited is fixed by its parent, and the
order in which a parent visits its children is fixed by section 10. Together
these make "the first error" (section 13) well defined.

### 9.2 Inference variables and unification

An **inference variable** is created only by a generic call (section 9.4): one
per type parameter of the callee. Variables are solved by `unify`:

- `unify(V, T)` where `V` is an unsolved variable: if `T` is that same
  variable, succeed; if `V` occurs anywhere inside `T` after substitution,
  fail (the occurs check); otherwise solve `V := T` and succeed.
- `unify(T, V)` symmetrically.
- `unify(A, B)` for two non-variable types: succeed iff they have the same
  form, the same head (for named types: the same declaration; for tuples and
  function types: the same arity) and all corresponding parts unify, in
  left-to-right order.

Solved variables are substituted transitively wherever a type is used. A type
is **ground** when it contains no unsolved variable.

A variable belongs to the call that created it and cannot outlive it: by the
end of the call's rule (section 9.4) every one of its variables must be
solved, and the resulting types are ground. A fresh variable that a *checking
rule* of section 9.3 creates (when it expands an unsolved variable into a
list, map, tuple or function type) belongs to the innermost generic call or
struct literal whose rule is running, and is held to the same requirement; a
variable solved only to another, still-unsolved variable does not count as
solved.

### 9.3 Checking rules

`check(e, T)` has a dedicated rule for these forms, and the default rule of
section 9.1 for every other form:

| Form | Rule |
|---|---|
| `[e1, …, en]` | `T` must be `[A]` (after substitution; an unsolved variable `V` is first solved as `V := [A']` with `A'` fresh); then `check(ei, A)` for i = 1…n in order. Otherwise `type-mismatch` at the `[`. |
| `#[k1: v1, …]` | `T` must be `#[K: V]` (a variable is solved to `#[K': V']` with fresh parts, and `K'` must satisfy `Key` once ground, else `bad-key-type` at `#[`); then for each entry in order `check(ki, K)` then `check(vi, V)`. Otherwise `type-mismatch` at `#[`. |
| `(e1, …, en)` | `T` must be a tuple type of arity n (a variable is solved to one with fresh parts); then `check(ei, Ti)` in order. Otherwise `type-mismatch` at the `(`. |
| lambda | `T` must be a function type `fn(A1,…,An) -> R` (a variable is solved to one with fresh parts) with n parameters; then, in this order: each parameter's type is `Ai` (if it has an annotation, `unify(Ai, annotation)`, failure = `type-mismatch` at the annotation; if `Ai` is unsolved and there is no annotation, `cannot-infer` at the parameter name), then the declared `-> Type`, if present, is unified into `R` (failure = `type-mismatch` at that type's first token), then the body is checked against `R` as a function body (section 11.6, so a block body that cannot produce a value is `missing-return` at the opening bar, not `type-mismatch`). A wrong parameter count is `type-mismatch` at the lambda's opening bar, and a parameter name repeated in one lambda is `dup-name` at the second one; the repeated-name check comes after all the parameter and `->` checks above and before the body. |
| `if` | `check` both branches against `T`. A one-armed `if` requires `T` to be `Unit` (else `type-mismatch` at the `if`). |
| `match` | `check` every arm's body against `T`. |
| block | the statements are checked as statements; then the trailing expression is `check`ed against `T`. A block with no trailing expression requires `T` to be `Unit` unless the block **diverges** (section 11.6), in which case any `T` is accepted; a block that needs `T` to be `Unit` and cannot have it is `type-mismatch` at the block's `{`. The body of a function, method or lambda is not checked by this rule but by section 11.6. |
| a call | the generic-call rule of section 9.4 uses `T` as the expected return type. This row covers a call whose callee is a path naming a function, a built-in or an enum variant, and a bare 0-payload enum variant (a 0-argument call); method calls and calls of a function value use the default rule. |
| struct literal | the type arguments are unified with `T` first (section 10.6). |

A diverging expression (one whose outermost form is `if`/`match`/block that
diverges) checks against any `T`.

### 9.4 Generic calls

Let the callee be a function (user function, built-in, or enum variant
constructor) with type parameters `P1…Pk` (k may be 0), parameter types
`F1…Fn` and return type `G`, and let the call be `f(a1, …, an)`.

1. If the argument count differs from n: `arity` at the position of the
   callee's first token.
2. Create fresh inference variables `V1…Vk` and let `σ` map `Pi -> Vi`.
3. For i = 1…n in order: `check(ai, σ(Fi))`, where `σ` includes every
   solution found so far.
4. If we are in checking mode with expected type `T`: `unify(σ(G), T)`;
   failure is `type-mismatch` at the position of the call (the callee's first
   token).
5. If any `Vi` is still unsolved: `cannot-infer` at the position of the
   callee's first token.
6. For each `Pi` with bounds: every bound must hold for `Vi`'s solution
   (sections 7, 8.4); failure is `unsatisfied-bound` at the position of the
   callee's first token.
7. The call's type is `σ(G)`, which is now ground.

Steps 3 and 4 in that order are what makes `let x: Option<Int> = None;` work
(the expected type solves `T`) while `let x = None;` fails with
`cannot-infer`.

Calling a non-generic function is the k = 0 case: arguments are simply checked
against their declared types.

### 9.5 Bindings

- `let p = e;` — `T := infer(e)`, then the pattern `p` is checked against `T`
  (section 12) and its bindings are introduced as immutable.
- `let p: A = e;` — the annotation `A` is resolved, `check(e, A)`, then `p` is
  checked against `A`.
- `var x = e;` — `T := infer(e)`; `x` is introduced as mutable with type `T`.
- `var x: A = e;` — `check(e, A)`; `x` is mutable with type `A`.

`let` patterns must be irrefutable (section 12.6); the pattern is typed first
and the irrefutability check follows, so a pattern that is both ill-typed and
refutable reports the type error. There is no inference from
later use: `var x = 0;` makes `x` an `Int` forever, and `var xs = [];` is
`cannot-infer` at the `[`.

### 9.6 Where bounds are checked

Bounds are checked at exactly three places: a generic call (9.4 step 6), a
method call (8.5 steps 4–5, plus the impl's own bounds from 8.4), and a map
type whose key type must satisfy `Key` (6.1). Nothing else triggers a bound
check; in particular, forming a struct or enum type never does, because those
have no bounds.

## 10. Expressions

Each subsection gives, for one form: how it is typed (in the order the checks
happen), and how it is evaluated (in the order the subexpressions run).
Evaluation order is observable through `print`, `emit`, mutation and panics,
and is part of the specification.

### 10.1 Literals

| Literal | Type | Value |
|---|---|---|
| `int` | `Int` | section 3.4 |
| `float` | `Float` | section 3.5 |
| `str` | `Str` | section 3.7 |
| `char` | `Char` | section 3.6 |
| `true`, `false` | `Bool` | |

### 10.2 Value paths

An unqualified `ident` resolves (section 5.4) to, in order: a local binding
(innermost first), a name in the current module's values namespace, a prelude
value (a built-in, or a variant of the prelude `Option`/`Result`), and finally
— only to produce a better diagnostic — a type name of the current module or
the prelude, which is `bad-value-ref`. A name that is none of these is
`unknown-name`.

- A local binding: its type; evaluating it reads the current value.
- A function (user or built-in) or an enum variant with at least one payload:
  this is only legal as the callee of a call; anywhere else it is
  `bad-value-ref` at the name's position.
- An enum variant with no payload: the type is the enum type, with its type
  arguments inferred as a 0-argument generic call (section 9.4), and the value
  is that variant.
- A struct or enum **type** name used as a value with no `.{`: `bad-value-ref`.

A qualified `m::x` resolves in module `m`, consulting **only** that module's
values namespace (visibility applies), so a type name there is `unknown-name`
like any other missing value. `Tr::m` is a method path and is only legal as a
callee (section 8.5); elsewhere it is `bad-value-ref` at the position of `m`.
Every `bad-value-ref` is reported at the name token — the `x` of `m::x`, the
`m` of `Tr::m`.

### 10.3 Prefix operators

| Operator | Operand | Result |
|---|---|---|
| `-` | `Int` | two's-complement negation, wrapping: `-(-2^63)` is `-2^63` |
| `-` | `Float` | IEEE negation (`-0.0` from `0.0`) |
| `!` | `Bool` | logical not |
| `~` | `Int` | bitwise complement |

Typing of `-e`: `T := infer(e)`; if `T` is neither `Int` nor `Float`,
`type-mismatch` at the position of `e`; the result type is `T`. Typing of
`!e`: `check(e, Bool)`; result `Bool`. Typing of `~e`: `check(e, Int)`;
result `Int`.

### 10.4 Binary operators

**Arithmetic `+ - * / %`.** Typing: `L := infer(left)`; if `L` is neither
`Int` nor `Float`, `type-mismatch` at the position of `left`; then
`check(right, L)`; the result type is `L`. Also, `%` requires `L` to be `Int`
(`type-mismatch` at the position of `left` if it is `Float`).

Evaluation: left, then right, then the operation.

`Int` arithmetic is two's-complement and **wraps** on overflow for `+`, `-`,
`*`. For `/`, the quotient is truncated toward zero; `-7 / 2` is `-3`. For
`%`, the result has the sign of the left operand and satisfies
`a == (a / b) * b + (a % b)` under wrapping; `-7 % 2` is `-1` and `7 % -2` is
`1`. `(-2^63) / -1` wraps to `-2^63` and `(-2^63) % -1` is `0`. A zero right
operand panics: `divide by zero` for `/`, `modulo by zero` for `%`.

`Float` arithmetic is IEEE-754 binary64 with round-to-nearest-even and the
default exception handling: division by zero yields an infinity or NaN, and
nothing panics.

**Concatenation `++`.** `L := infer(left)`; `L` must be `Str` or a list type,
else `type-mismatch` at the position of `left`; `check(right, L)`; result `L`.
For `Str` the result is a new string; for lists it is a **new** list holding
the elements of the left operand followed by those of the right (neither
operand is modified).

**Bitwise `& | ^ << >>`.** `check(left, Int)`, `check(right, Int)`, result
`Int`. `&`, `|`, `^` are bitwise on the two's-complement representation. `<<`
shifts left, discarding high bits; `>>` is an **arithmetic** shift right,
copying the sign bit. For both shifts the right operand must be in 0…63, else
the panic `shift amount out of range`.

**Comparison `< <= > >=`.** `L := infer(left)`; `Ord` must hold for `L`
(section 7.2), else `not-ord` at the position of `left`; `check(right, L)`;
result `Bool`. Semantics: `Int` signed; `Bool` with `false < true`; `Char` by
scalar value; `Str` lexicographically by scalar value (a prefix is less than
its extensions); `Float` by IEEE, so every comparison involving NaN is
`false`, and `-0.0 < 0.0` is `false`.

**Equality `== !=`.** `L := infer(left)`; `Eq` must hold for `L`
(section 7.1), else `not-eq` at the position of `left`; `check(right, L)`;
result `Bool`. `!=` is the negation of `==`. Equality is **structural**:

- `Int`, `Bool`, `Char`: same value. `Str`: same length and same scalars.
- `Float`: IEEE equality — `NaN == NaN` is `false`, `-0.0 == 0.0` is `true`.
- `Unit`: always equal.
- tuples and struct instances: componentwise/fieldwise in declaration order.
- enum values: same variant, then payloads in order.
- lists: same length, then elementwise from index 0.
- maps: same size, and for every key of the left map (in its insertion order)
  the right map has that key with an equal value. Insertion **order is not
  compared**: `#[1: 2, 3: 4] == #[3: 4, 1: 2]` is `true`.
- Comparison never panics and never follows identity: two distinct list
  objects with equal contents are equal.

Componentwise comparisons stop at the first unequal part, which is observable
only through timing, not through output.

**Logical `&&` `||`.** `check(left, Bool)`, `check(right, Bool)`, result
`Bool`. They **short-circuit**: `&&` evaluates the right operand only if the
left is `true`, `||` only if the left is `false`.

### 10.5 Indexing

`a[i]`. Typing: `A := infer(a)`; then

- `A` is `[T]`: `check(i, Int)`, result `T`. At run time, `i` must be in
  0…len-1, else the panic `index out of bounds`.
- `A` is `Str`: `check(i, Int)`, result `Char`, same bounds rule.
- `A` is `#[K: V]`: `check(i, K)`, result `V`. A key that is not present
  panics with `missing key`.
- anything else: `not-indexable` at the position of `a`.

Evaluation order: `a`, then `i`, then the lookup.

### 10.6 Structs

**Struct literal** `P.{ f1: e1, …, fm: em }` where `P` is a value-position
path naming a *type* (an unqualified name or `mod::Name`). Typing:

1. Resolve `P` in the types namespace: `unknown-type` / `not-public` on
   failure, `not-struct` at `P`'s position if it names an enum.
2. Create fresh inference variables for the struct's type parameters. In
   checking mode against `T`, `unify` the struct type with `T` immediately
   (failure: `type-mismatch` at `P`'s position).
3. A field name appearing twice is `dup-field` at its second occurrence; a
   field name that the struct does not have is `unknown-field` at its
   position. These two checks run over the literal's fields in **written
   order**, before step 4, and for each field the duplicate check comes first
   (the same holds for a struct pattern, section 12.2).
4. For each field of the struct in **declaration order**: if the literal
   provides it, `check` its expression against the field's type (substituted);
   if not, `missing-field` at `P`'s position.
5. Every inference variable must be solved, else `cannot-infer` at `P`'s
   position.

Evaluation: the field expressions run in **written order** (not declaration
order), then the instance is created. Struct instances are immutable.

**Field access** `e.f`. `T := infer(e)`; `T` must be a struct type, else
`not-struct` at the position of `e`; `f` must be one of its fields, else
`unknown-field` at `f`'s position; the result is the field's substituted type.

### 10.7 List, map and tuple literals

**`[e1, …, en]`** in synthesis mode: n must be at least 1, else `cannot-infer`
at the `[`. `T := infer(e1)`, then `check(ei, T)` for i = 2…n; result `[T]`.
Evaluation: elements left to right, then a new list.

**`#[k1: v1, …, kn: vn]`** in synthesis mode: n must be at least 1, else
`cannot-infer` at the `#[`. `K := infer(k1)`; `Key` must hold for `K`, else
`bad-key-type` at the position of `k1`; `V := infer(v1)`; then for i = 2…n,
`check(ki, K)` then `check(vi, V)`. Result `#[K: V]`. Evaluation: `k1`, `v1`,
`k2`, `v2`, … in order, then a new map with those entries inserted in that
order; a key inserted twice keeps its first position and takes the later
value.

**`(e1, …, en)`** in synthesis mode: `infer` each component left to right;
result the tuple type. 2 ≤ n ≤ 8 is enforced by the grammar for the lower
bound and is `bad-arity` at the `(` for the upper.

The empty list `[]` and the empty map `#[]` are legal only in checking mode
(or via `listNew()` / `mapNew()`).

### 10.8 Calls

`callee(a1, …, an)`.

- If `callee` is a value path naming a function, a built-in or an enum
  variant: section 9.4 applies (with the variant's enum type parameters as the
  type parameters, and its payload types as the parameter types).
- If `callee` is `Tr::m` or a method-call suffix: section 8.5.
- Otherwise: `F := infer(callee)`; `F` must be a function type, else
  `not-callable` at the position of `callee`; the argument count must match,
  else `arity` at the position of `callee`; then `check(ai, Fi)` left to
  right; result is `F`'s return type.

Evaluation: for a direct call of a named function, built-in or constructor,
the arguments are evaluated left to right and then the function is entered.
For an indirect call, the callee expression is evaluated **first**, then the
arguments left to right.

At most 16 arguments; more is `bad-arity` at the position of the callee, and
that check runs before every other check of the call, including `arity`. For a
method call the position is the method's name token instead, and the receiver
does not count toward the 16.

### 10.9 Method calls

`recv.m(a1, …, an)` and `Tr::m(recv, a1, …, an)` are typed by section 8.5.
Evaluation: `recv` first, then the arguments left to right, then the resolved
method body is entered with `self` bound to the receiver.

### 10.10 Lambdas and closures

In synthesis mode, every parameter of a lambda must be annotated, else
`cannot-infer` at the first unannotated parameter's name; the body is then
synthesised (or checked against the declared `-> Type` if present), and the
result type is `fn(…) -> …`. A parameter name repeated in one lambda is
`dup-name` at the second one, in either mode, checked after the parameter
annotations and the `-> Type` and before the body.

A lambda evaluates to a **closure**: a code pointer plus a copy of every
variable it captures.

- A lambda captures a variable iff the variable is used (read) in its body —
  including in nested lambdas — and is bound outside the lambda but inside the
  enclosing function (parameters included). Module items are not captured;
  they are always reachable.
- Capture is **by value at the moment the lambda is evaluated**. A later change
  to the outer variable is invisible to the closure, and the closure cannot
  change the outer variable: assigning inside a lambda to a variable bound
  outside it is `assign-captured` at the position of the target name.
- `self` may be captured like any other binding.
- Because lists and maps are references, a captured list or map still refers
  to the same object, and mutations through it are visible both ways.

Closures may be returned, stored in lists, maps and structs, and called later.
Recursion requires a named function; a lambda cannot refer to itself.

### 10.11 if

`if c b1 else b2`. Typing: `check(c, Bool)`; then

- in checking mode, both branches are checked against the expected type;
- in synthesis mode, if `b1` does not **diverge** (section 11.6), the result
  is `T := infer(b1)` and `b2` is checked against `T`; if `b1` diverges, it is
  checked as a statement (synthesised and discarded) and the result is
  `infer(b2)` — or `Unit` when `b2` diverges too, in which case `b2` is also
  just synthesised and discarded.

With no `else`, `b1` is checked against `Unit` and the result is `Unit`. An
`else if` chain is nested `if`s.

Evaluation: the condition, then exactly one branch.

### 10.12 match

`match s { arms }`. Typing, in this order:

1. `S := infer(s)`.
2. There must be at least one arm, else `non-exhaustive` at the `match`
   keyword.
3. For each arm in written order: check the pattern against `S` (section 12),
   introducing its bindings; then `check(guard, Bool)` if there is a `when`;
   then the body. In checking mode every body is checked against the expected
   type. In synthesis mode the match's type `R` is found while walking the
   arms: start with `R` unknown, and for each arm — if `R` is unknown and the
   body does not **diverge** (section 11.6), set `R := infer(body)`; if `R` is
   unknown and the body diverges, synthesise the body and discard its type;
   otherwise `check(body, R)`. If `R` is still unknown after the last arm, the
   match's type is `Unit`. (So an early arm that only returns or breaks does
   not force the whole match to be `Unit`.)
4. For each arm in order, the reachability check of section 12.5:
   `unreachable` at the arm's pattern.
5. The exhaustiveness check of section 12.4: `non-exhaustive` at the `match`
   keyword.

Evaluation: the scrutinee once, then the arms in order — for each arm, match
the pattern (binding as it goes); if it matches and there is a guard,
evaluate the guard (with the bindings in scope) and if it is `false` continue
with the next arm; the first arm that matches with a true guard has its body
evaluated, and that is the value of the `match`. A compiled `match` ends in
the panic `no match` for the case where every arm failed; because
exhaustiveness is decided from the unguarded arms alone and pattern matching
has no side effects, an accepted program never reaches it, and no test can
produce that panic.

### 10.13 self

`self` is an expression only inside a trait default body or an impl method,
where its type is `Self` (rigid inside a default body, the head type inside an
impl). Anywhere else it is `self-outside` at its position.

### 10.14 Blocks as expressions

A block `{ s1 … sk e? }` is an expression only in the positions the grammar
allows (a function or method body, an `if`/`else`/`while`/`for` body, a match
arm body, a lambda body). Its statements are checked in order; its value is
the trailing expression's value, or the unit value if there is none. In
synthesis mode a block with no trailing expression has type `Unit`. A new
scope is pushed for the block and popped at its end.

## 11. Statements and control flow

### 11.1 Scopes and bindings

A function body, each block, each loop body, each match arm and each lambda
body opens a scope. A `let` or `var` binding is visible from the statement
after it to the end of its scope. Pattern bindings from a `let`, a `for`
pattern or a match arm are visible in the same way (for an arm: in its guard
and its body).

Shadowing is always allowed: an inner binding, or a later binding in the same
scope, hides an earlier one of the same name, and hides module items and
prelude names too. The two bindings are different variables; the hidden one is
unaffected.

Within a single pattern, the same binding name twice is `dup-name` at the
second occurrence.

Function parameters are bindings in the body's outermost scope and are
**immutable**.

### 11.2 let, var and assignment

```
let p = e;        let p: T = e;
var x = e;        var x: T = e;
x = e;            a[i] = e;
```

`let` bindings are immutable; `var` bindings are mutable and must be a plain
identifier (no patterns). Typing is section 9.5.

An assignment's target is checked as follows:

- an identifier: it must resolve to a local binding, else `unknown-name` at
  its position; that binding must be a `var`, else `assign-immutable` at its
  position (this covers `let` bindings, parameters, pattern bindings and
  loop variables); and it must be bound in the **current** function, not
  captured from an enclosing one, else `assign-captured` at its position.
  Then `check(e, <the binding's type>)`.
- an index expression `a[i]`: `A := infer(a)`; `A` must be a list or a map
  type, else `bad-target` at the position of `a` (a `Str` is not assignable);
  then `check(i, Int)` or `check(i, K)` respectively, then `check(e, T)` or
  `check(e, V)`. Evaluation order is `a`, then `i`, then `e`, then the store.
  For a list the index must be in range, else the panic `index out of
  bounds`; for a map an absent key is **inserted** at the end of the
  insertion order, and a present key keeps its position and takes the new
  value.
- anything else (a field access, a call, a literal, …): `bad-target` at the
  position of the whole target expression.

Struct fields and tuple components are immutable; there is no `p.x = …`.

### 11.3 while

`while c { … }`: `check(c, Bool)`; the body is a **statement block**
(section 11.7). The condition is evaluated before every iteration; the body
runs while it is `true`.

### 11.4 for

Two forms.

**Over a sequence**: `for p in e { … }`. `S := infer(e)`; then

- `S` is `[T]`: the pattern is checked against `T`;
- `S` is `Str`: the pattern is checked against `Char`;
- otherwise `not-iterable` at the position of `e`.

The pattern must be irrefutable (`refutable-pattern` at the pattern, section
12.6). The body is a statement block (section 11.7).

Evaluation for a list: `e` is evaluated once to a list object; then for
i = 0, 1, 2, …, before each iteration the list's **current** length is read
and iteration stops when i is not less than it; otherwise element i is bound
to the pattern and the body runs. So a body that appends to the list it is
iterating runs longer, and one that shortens it stops early; this is defined
behaviour, not an error. For a `Str`, the string is immutable and the
iteration visits every scalar value in order.

**Over a range**: `for p in e1 .. e2 { … }`. `check(e1, Int)`,
`check(e2, Int)`; the pattern is checked against `Int` and must be
irrefutable; the body is a statement block. Evaluation: `e1` then `e2`, each exactly once, giving `a` and
`b`; the loop runs with the variable taking `a`, `a+1`, …, `b-1`, and does not
run at all if `a >= b`. (The bound is `b`, not `b` recomputed; the iteration
count is `b - a` when positive. Programs where `b - a` overflows are not
tested.)

Each iteration binds a **fresh** immutable variable, so a closure created in
the body captures that iteration's value.

### 11.5 break, continue, return

`break;` and `continue;` apply to the innermost enclosing `while` or `for` of
the **current** function; a lambda body is a new function, so a `break` inside
a lambda inside a loop is `break-outside` at the keyword. Outside any loop it
is also `break-outside`.

`return;` and `return e;` leave the innermost enclosing function or lambda.
The returned expression is `check`ed against that function's return type; a
bare `return;` requires the return type to be `Unit`, else `type-mismatch` at
the `return` keyword. A `return` with a value in a `Unit` function is also
`type-mismatch` at the `return` keyword unless the value's type is `Unit`.

A lambda's return type is the one declared with `-> T`, or the type its body
is checked against, or the synthesised type of its body; a `return` inside a
lambda whose return type is not yet known (synthesis mode without `-> T`) is
`cannot-infer` at the `return` keyword.

### 11.6 Divergence and missing-return

A statement or expression **diverges** when control cannot flow past it:

- `return`, `break` and `continue` diverge.
- a `let`, `var`, assignment or expression statement diverges iff the
  expression it evaluates (its right-hand side, for the first three) diverges.
- a block diverges iff any of its statements diverges, or its trailing
  expression diverges.
- an `if` with an `else` diverges iff both branches diverge; without an
  `else` it never diverges.
- a `match` diverges iff it has at least one arm and every arm body diverges.
- a `while` and a `for` never diverge (the condition may be false the first
  time; `while true { }` is not special-cased).
- a call never diverges, including a call to `panic` — `panic` has return type
  `Unit` and is an ordinary function as far as the checker is concerned.
- every other form does not diverge.

A function, method or lambda body is checked like this: its statements are
checked in order; if it has a trailing expression, that expression is
`check`ed against the return type (`Unit` when none is written, so
`fn f() { 5 }` is a `type-mismatch` at the `5`); if it has none, the return
type must be `Unit` or the body must **diverge** (a lambda's return type
that is still an unsolved inference variable is not `Unit` and is not
unified with it here), and otherwise the error is
`missing-return` at the `fn` keyword of the declaration (or at the lambda's
`|`/`||`). A `Unit` function needs no trailing expression.

Statements after a diverging statement are still fully type-checked; dead code
is not an error.

### 11.7 Expression statements and statement blocks

An **expression statement** is an expression evaluated for its effects: it is
type-checked in *synthesis* mode and its value is discarded, whatever its type
(discarding a value is never an error). Note the consequence for an `if` or
`match` used as a statement: being synthesised, its branches or arm bodies must
all have the same type, exactly as in any other synthesis position — most such
statements end up with every branch of type `Unit`, which is the usual case.

A **statement block** — the body of a `while` or a `for` — has its statements
checked in order and its trailing expression, if any, synthesised and
discarded. It therefore behaves like a block whose last statement is an
expression statement.

An **expression block** — a function or method body, an `if`/`else` branch, a
match arm body, a lambda body — has a type: that of its trailing expression,
or `Unit` when it has none (section 10.14).

## 12. Patterns, matching and exhaustiveness

### 12.1 Pattern forms

| Pattern | Matches | Bindings |
|---|---|---|
| `_` | anything | none |
| `x` | anything, unless `x` names a 0-payload variant | binds `x` |
| `C` / `m::C` | that 0-payload variant | none |
| `C(p1,…,pk)` | that variant, with payloads matched by `p1…pk` | from the sub-patterns |
| `P.{ f: p, …}` / `P.{ f, … }` / `P.{ …, .. }` | a struct, fieldwise | from the sub-patterns; `P.{ f }` binds `f` |
| `(p1,…,pn)` | a tuple, componentwise | from the sub-patterns |
| `[p1,…,pn]` | a list of exactly length n | from the sub-patterns |
| `[p1,…,pn, ..]` | a list of length ≥ n, prefix matched | from the sub-patterns |
| `[p1,…,pn, ..r]` | the same, and binds `r` to a **new** list of the remaining elements | plus `r` |
| `int`, `-int`, `str`, `char`, `true`, `false` | a value equal to that literal | none |

A bare `ident` is a 0-payload variant pattern iff the name resolves, in the
values namespace (locals are not consulted — only module items and the
prelude), to a variant with no payloads; otherwise it is a binding. `None` is
therefore a variant pattern in a module that does not shadow it, and a
binding in one that declares `fn None(…)` or `enum E { None(Int) }`.

A float literal is not a pattern: `bad-pattern` at the pattern's first token
(the `-` for a negated one), whatever the expected type. A list pattern
with `..` other than last, or with two of them, is `parse`.

Sub-patterns are matched **left to right**, and a struct pattern's fields in
the order written; matching stops at the first failure.

### 12.2 Typing a pattern

Patterns are checked against an expected type `T`:

- `_` and a binding: always fine; a binding gets type `T`.
- a literal pattern: its type must equal `T` (`Int` for `int`/`-int`, `Str`,
  `Char`, `Bool`), else `type-mismatch` at the pattern.
- `C` or `C(…)`: resolve `C` in the values namespace (`unknown-name` /
  `not-public` on failure); it must be an enum variant, else `type-mismatch`
  at the pattern; `T` must be that variant's enum type, else `type-mismatch`
  at the pattern (the expected type is always ground, because a scrutinee's
  type is synthesised before any pattern is looked at);
  the sub-pattern count must equal the variant's payload count, else `arity`
  at the pattern; then each sub-pattern is checked against the substituted
  payload type, left to right.
- `P.{…}`: resolve `P` in the types namespace; it must be a struct, else
  `not-struct` at `P`; `T` must be that struct type, else `type-mismatch` at
  the pattern. Unknown field names are `unknown-field`, repeated ones
  `dup-field`, in written order. Without a trailing `..`, every field must be
  mentioned, else `missing-field` at the pattern. Sub-patterns are checked
  against their substituted field types in **written** order.
- `(p1,…,pn)`: `T` must be a tuple type of arity n, else `type-mismatch` at
  the pattern; components left to right.
- a list pattern: `T` must be a list type `[E]`, else `type-mismatch` at the
  pattern; every element sub-pattern is checked against `E`; a named rest
  binds `[E]`.

### 12.3 Pattern constructors

For the exhaustiveness and reachability algorithms each type has a
**constructor set**, which is either finite or infinite:

| Type | Constructors |
|---|---|
| `Bool` | `true`, `false` (finite, 2) |
| `Unit` | one anonymous constructor of arity 0 (finite, 1) |
| tuple of arity n | one constructor of arity n (finite, 1) |
| struct with m fields | one constructor of arity m (finite, 1) |
| enum with v variants | one per variant, arity = its payload count (finite, v) |
| `Int`, `Char`, `Str`, `Float` | infinite |
| `fn(…) -> …` | infinite (no pattern can name one) |
| `[E]` | one per length 0, 1, 2, … (infinite) |
| `#[K: V]` | infinite |
| a rigid type parameter | infinite (only `_` and bindings can match one) |

Literal patterns, list patterns and variant/struct/tuple patterns *name*
constructors; `_` and bindings name none (they are wildcards).

### 12.4 Usefulness, exhaustiveness and reachability

Both checks come from one function. A **pattern matrix** `P` is a list of rows,
each row a list of patterns of the same length, with a column type for each
column. `U(P, q)` — "row `q` is useful against `P`" — is `true` iff there
exists a value vector matched by `q` and by no row of `P`. It is computed as:

1. If `q` is empty (zero columns): `U(P, q)` is `true` iff `P` has no rows.
2. Otherwise look at column 1, whose type is `T1`.
   - If `T1` is a list type, use the **list rule** below (it subsumes both of
     the following cases).
   - Else if `q`'s first pattern names a constructor `c`: return
     `U(S(c, P), S(c, q))` where specialisation `S(c, ·)` is defined below.
   - Else `q`'s first pattern is a wildcard: let `C` be the set of
     constructors of `T1` named by any row's first pattern (the **used set**).
     - If `T1` has a finite constructor set and `C` covers all of it: return
       `true` iff `U(S(c, P), S(c, q))` is `true` for **some** `c` in `C`.
     - Else (the used set does not cover `T1`, which is always so when `T1`'s
       constructor set is infinite, or when `C` is empty and `T1` has at least
       one constructor): return `U(D(P), D(q))`,
       the **default** matrix, which keeps only the rows whose first pattern
       is a wildcard and drops their first column.

**Specialisation** `S(c, row)` for a row whose first pattern `p` has arity `k`
for constructor `c`: if `p` names `c`, replace `p` with its `k`
sub-patterns (so the row grows by `k - 1` columns, with the corresponding
component types); if `p` is a wildcard, replace it with `k` wildcards; if `p`
names a different constructor, drop the row entirely. `S(c, P)` applies this
to every row in order.

For a literal pattern, the constructor is the literal value itself with arity
0. For a struct, the single constructor has arity = the field count and the
sub-patterns are taken in **declaration order**, a field not mentioned (or
elided by `..`) becoming a wildcard. For a tuple, arity = the component
count.

**The list rule.** Let `Lmax` be the largest number of element sub-patterns
in any first-column list pattern of `P` or of `q` (0 if there are none). The
constructors considered are exactly the lengths `0, 1, …, Lmax + 1`; every
length beyond `Lmax` specialises to the same matrix as `Lmax + 1` (the extra
columns are all wildcards), so testing that one length stands for all of
them.

Specialising a row at length `k` means: a fixed pattern `[p1,…,pn]`
contributes `p1…pn` if `n == k` and the row is dropped otherwise; an open
pattern `[p1,…,pn, ..]` or `[p1,…,pn, ..r]` contributes `p1…pn` followed by
`k - n` wildcards if `n <= k` and the row is dropped otherwise; a wildcard
contributes `k` wildcards. The `..r` binding plays no part in the algorithm.

Say that `q`'s first pattern **admits** length `k` when it is a wildcard (any
`k`), a fixed pattern of length `n` (only `k == n`), or an open pattern with
`n` element patterns (every `k >= n`). Then `U(P, q)` is `true` iff there is
some `k` in `0…Lmax + 1` admitted by `q`'s first pattern for which
`U(S(k, P), S(k, q))` is `true`.

**Exhaustiveness.** Let `P` be the matrix of the single-column rows formed by
the patterns of the arms **without** guards, in order (a guarded arm is
excluded because its guard may be false). The match is exhaustive iff
`U(P, [_])` is `false`. Otherwise: `non-exhaustive` at the `match` keyword.

**Reachability.** For arm *i* (guarded or not), let `Pi` be the matrix of the
unguarded arms among 1…i-1. Arm *i* is reachable iff
`U(Pi, [<arm i's pattern>])` is `true`. The first unreachable arm, scanning
i = 1, 2, …, is `unreachable` at the position of that arm's pattern.

### 12.5 Worked exhaustiveness cases

```
enum Tri { A, B, C(Int) }
```

- `match t { A -> 1, B -> 2, C(n) -> n }` — exhaustive.
- `match t { A -> 1, C(_) -> 2 }` — `non-exhaustive` (B is missing).
- `match t { A -> 1, B -> 2, C(0) -> 3, C(_) -> 4 }` — exhaustive.
- `match t { _ -> 0, A -> 1 }` — exhaustive, but arm 2 is `unreachable`.
- `match t { A when f() -> 1, A -> 2, B -> 3, C(_) -> 4 }` — exhaustive and
  all arms reachable: the guarded arm does not cover `A`, and arm 2 is useful
  against the empty matrix of unguarded earlier arms.
- `match xs { [] -> 0, [a] -> a, [a, b, ..] -> a + b }` — exhaustive
  (`Lmax` = 2, lengths 0, 1, 2, 3 all covered).
- `match xs { [] -> 0, [_, ..] -> 1, [..] -> 2 }` — exhaustive, arm 3
  `unreachable`.
- `match n { 0 -> "z", 1 -> "o" }` for `n: Int` — `non-exhaustive`.
- `match b { true -> 1, false -> 0 }` — exhaustive.
- `match p { Pair.{ a: 1, b: _ } -> 1 }` for a struct `Pair` — `non-exhaustive`
  (the single constructor is used, and specialising leaves the `Int` column
  uncovered).
- `match v { _ -> 0 }` where `v` has an enum type with **no** variants —
  `unreachable` at the arm: the type has no values, so no arm of any `match`
  on it is useful (and a `match` with no arms is `non-exhaustive` by rule 2 of
  section 10.12). A value of such a type cannot exist, so no running program
  is affected.

### 12.6 Irrefutable patterns

A pattern is **irrefutable** iff it matches every value of its type:

- `_` and bindings are irrefutable;
- a tuple pattern is irrefutable iff all components are;
- a struct pattern is irrefutable iff all written field sub-patterns are;
- a variant pattern is irrefutable iff its enum has exactly one variant and
  all sub-patterns are;
- `[..]` and `[..r]` are irrefutable; every other list pattern is not;
- literal patterns are not irrefutable (not even `true`).

A refutable pattern in a `let` or in a `for` is `refutable-pattern` at the
pattern's first token. In both places the pattern is typed first (section
12.2) and this check follows, so a type error inside the pattern wins.

## 13. Diagnostics

### 13.1 The one line

A rejected program produces exactly:

```
error: <kind> at <line>:<col>
```

followed by one LF, and nothing else. `<kind>` is one of the 51 kinds in
section 13.4, spelled exactly as written there. `<line>` and `<col>` are
module-local (section 2) except for `bad-module`, `dup-module` and `no-main`.
Both are 1-based decimal with no padding.

A **position** is defined as:

- for a token: its first character;
- for an expression, a pattern or a type: its first token, where the
  parentheses of a parenthesised expression do not count (section 4.4);
- for a declaration: its `fn`, `struct`, `enum`, `trait`, `impl` or `use`
  keyword (not the `pub` before it);
- for a statement: its first token;
- for a named thing (a field, a parameter, a method, a variant, a module in a
  `use`): the identifier token itself;
- for an input that ends too early: line = the number of lines in the module
  (at least 1), col = that last line's length in scalar values plus 1.

### 13.2 Pass order

The compiler runs the passes below in order. The reported error is the **first**
error found by the earliest pass that finds any; later passes never run. Within
a pass, the traversal order given below decides which error is first.

**Pass 0 — the module stream.** `bad-module`, `dup-module`; see section 2.

**Pass 1 — lexing.** For each module in stream order, lex its body from the
start; the first ill-formed token wins: `bad-token`, `int-range`,
`bad-escape`, `unterminated`.

**Pass 2 — parsing.** For each module in stream order, parse its token list;
the first failure is `parse`.

**Pass 3 — items.** Six sub-passes, each a complete sweep over all modules in
stream order and, inside a module, over its items in source order.

- **3.1 Declaration.** For each item, in this order: if it declares a type or
  trait whose name is one of the seven reserved names (`Int`, `Float`, `Bool`,
  `Char`, `Str`, `Unit`, `Self`), `reserved-name` at the name; then enter the
  name into its namespace, and `dup-name` at the name if that namespace
  already holds it. An enum enters its own name (types) and then its variants
  in order (values); a variant colliding with a function name, or two variants
  of two enums colliding, is `dup-name` at the later one. `use` items are
  skipped here.
- **3.2 Imports.** For each `use` in order: `unknown-module` at the module
  name if no module in the stream has that name; `dup-name` at the bound name
  (the alias, or the module name when there is no `as`) if the imports
  namespace already holds it.
- **3.3 Internal duplicates.** For each item in order, check its own name
  lists for repeats, reporting `dup-name` at the second occurrence, in this
  order: the item's type parameters; then its field names (a struct), its
  parameter names (a function), or its method names followed by each method's
  parameter names in method order (a trait or an impl). Variant payloads have
  no names and so cannot collide.
- **3.4 Signatures.** Resolve every type written in an item's header, in this
  order per item: the bounds of its type parameters (in parameter order, each
  bound left to right); for a `fn`, its parameter types in order then its
  return type; for a `struct`, its field types in order; for an `enum`, its
  variants in order and each variant's payload types in order; for a `trait`,
  each method in order (parameter types then return type); for an `impl`, its
  trait reference, then its head type, then each method in order. Errors:
  `unknown-type`, `unknown-trait`, `not-public`, `arity-type`, `bad-arity`,
  `bad-key-type`, `self-outside`.
- **3.5 Impls.** For each `impl` in order: `builtin-trait-impl` at the `impl`
  keyword if the trait is `Eq`, `Ord` or `Key`; then `bad-impl-head` at the
  head type; then `unused-param` at the first type parameter missing from the
  head; then `dup-impl` at the `impl` keyword if an earlier impl has the same
  (trait, head constructor); then `missing-method` at the `impl` keyword for
  the first trait method (in the trait's declaration order) that has no
  default body and is not defined here; then, for each impl method in source
  order, `extra-method` at its name if the trait has no such method and
  `sig-mismatch` at its name if the signature differs (section 8.3).
- **3.6 Entry point.** `no-main at 1:1` if there is no module `main`, or it
  declares no function `main`, or that function has type parameters,
  parameters, or a return type other than `Unit`.

**Pass 4 — bodies.** Sweep all modules in stream order; within a module, all
items in source order; for a `trait`, its default method bodies in order; for
an `impl`, its method bodies in order; for a `fn`, its body. Each body is
checked by the rules of sections 9 to 12, which fix the order of every check
inside it. After a body's statements and trailing expression are checked, that
body's `missing-return` check runs (section 11.6). Every error kind not listed
under passes 0 to 3 belongs to this pass.

### 13.3 Order rules worth stating twice

- A binary operator checks its left operand, then the operand's own
  requirement (numeric, `Eq`, `Ord`, …), then the right operand.
- A call checks arity before any argument, and arguments left to right.
- A statement is fully checked before the next statement is looked at.
- An assignment first validates the shape of its target (`bad-target`), then
  the target, then the right-hand side.
- A `match` checks the scrutinee, then each arm (pattern, guard, body) in
  order, then reachability for each arm in order, then exhaustiveness.
- A struct literal checks for `dup-field` and `unknown-field` over the written
  fields first, then the field values in declaration order.
- `missing-return` is reported only after the whole body has been checked, so
  any type error inside the body wins.

### 13.4 Error kinds

| Kind | Pass | Meaning |
|---|---|---|
| `bad-module` | 0 | the first line is not a module header, or a line starting with `@` is not a valid one |
| `dup-module` | 0 | two modules with the same name |
| `bad-token` | 1 | a character or character sequence that is no token |
| `int-range` | 1 | an integer literal above 9223372036854775807 |
| `bad-escape` | 1 | an unknown or malformed `\` escape |
| `unterminated` | 1 | an unterminated string, character literal or block comment |
| `parse` | 2 | the token stream does not fit the grammar |
| `reserved-name` | 3.1 | a type or trait named `Int`, `Float`, `Bool`, `Char`, `Str`, `Unit` or `Self` |
| `dup-name` | 3.1–3.3, 4 | a repeated name in one namespace, one signature, one pattern or one declaration list |
| `unknown-module` | 3.2, 4 | `use` of a module that does not exist, or a path qualifier that is neither an import nor a trait |
| `unknown-type` | 3.4, 4 | a type name that resolves to nothing |
| `unknown-trait` | 3.4, 4 | a trait name that resolves to nothing |
| `not-public` | 3.4, 4 | use of a non-`pub` item of another module |
| `arity-type` | 3.4, 4 | wrong number of type arguments for a named type |
| `bad-arity` | 3.4, 4 | a tuple type or literal with more than 8 parts, or a function type or call with more than 16 parameters |
| `bad-key-type` | 3.4, 4 | a map key type that does not satisfy `Key` |
| `self-outside` | 3.4, 4 | `Self` outside a trait or impl, or `self` outside a method |
| `builtin-trait-impl` | 3.5 | `impl Eq`/`Ord`/`Key` |
| `bad-impl-head` | 3.5 | an impl head that is not a primitive, `[P]`, `#[P: Q]` or `Name<distinct params>` |
| `unused-param` | 3.5 | an impl type parameter that does not appear in the head |
| `dup-impl` | 3.5 | two impls of one trait for one head constructor |
| `missing-method` | 3.5 | an impl lacking a trait method that has no default |
| `extra-method` | 3.5 | an impl method the trait does not declare |
| `sig-mismatch` | 3.5 | an impl method whose signature differs from the trait's |
| `no-main` | 3.6 | no suitable `main` in a module named `main` |
| `unknown-name` | 4 | a value name that resolves to nothing |
| `type-mismatch` | 4 | a type that is not the one required |
| `arity` | 4 | wrong number of arguments, payloads or method arguments |
| `not-callable` | 4 | calling something that is not a function |
| `not-struct` | 4 | a field access, struct literal or struct pattern on a non-struct |
| `unknown-field` | 4 | a field the struct does not have |
| `missing-field` | 4 | a struct literal or struct pattern not covering every field |
| `dup-field` | 4 | a field named twice in one literal or pattern |
| `not-indexable` | 4 | indexing something that is not a list, map or string |
| `not-iterable` | 4 | `for … in e` where `e` is neither a list nor a string |
| `no-method` | 4 | no visible trait declares the called method |
| `ambig-method` | 4 | two or more visible traits declare it |
| `unsatisfied-bound` | 4 | a trait bound that does not hold (including "no impl for this type") |
| `not-eq` | 4 | `==`/`!=` on a type that is not `Eq` |
| `not-ord` | 4 | `<`/`<=`/`>`/`>=` on a type that is not `Ord` |
| `cannot-infer` | 4 | a type that local inference cannot determine |
| `non-exhaustive` | 4 | a `match` that does not cover its scrutinee type |
| `unreachable` | 4 | a `match` arm covered by the earlier unguarded arms |
| `missing-return` | 4 | a non-`Unit` body that can finish without a value |
| `bad-value-ref` | 4 | a function, built-in, payload-carrying variant, type or method named where a value is required |
| `bad-pattern` | 4 | a float literal pattern |
| `refutable-pattern` | 4 | a refutable pattern in `let` or `for` |
| `break-outside` | 4 | `break`/`continue` with no enclosing loop in the same function |
| `assign-immutable` | 4 | assignment to a `let` binding, parameter, pattern binding or loop variable |
| `assign-captured` | 4 | assignment, inside a lambda, to a variable bound outside it |
| `bad-target` | 4 | an assignment target that is neither an identifier nor an index of a list or map |

## 14. Runtime semantics

### 14.1 Values, identity and assignment

A *value* is one of: an `Int`, a `Float`, a `Bool`, a `Char`, a `Str`, the
unit value, a tuple, a struct instance, an enum value, a closure, a list
object, or a map object.

Lists and maps are **mutable objects with identity**. Binding, assigning,
passing as an argument, returning, storing in a struct, tuple, list or map,
and capturing in a closure all copy the *reference*, never the contents. Two
variables may therefore name the same list, and a mutation through one is
visible through the other. `listCopy` and `mapCopy` make a new object with the
same elements (the elements themselves are not copied — a shallow copy).

Every other kind of value is immutable, so for them the distinction between
copying a value and sharing it is unobservable.

There is no `null`, no uninitialised variable and no identity comparison: `==`
always compares contents (section 10.4).

### 14.2 Output

`print(s)` writes `s` followed by one LF to stdout. `emit(s)` writes `s` with
no LF. Those two functions are the only way a program writes anything.
Output must appear in the order the calls happen, and must still be complete
if the program then panics.

### 14.3 Printing floats

`showFloatAt(x, d)` for an integer `d` in 0…17 is defined as:

1. If `x` is NaN the result is `nan` (no sign, whatever the payload or sign
   bit of the NaN). If `x` is +infinity the result is `inf`; if -infinity,
   `-inf`.
2. Otherwise let the sign prefix be `-` when `x` is negative **or is
   -0.0**, and empty otherwise.
3. Let `m` be the exact value of `|x|` — every binary64 number is exactly a
   dyadic rational, so this is an exact quantity, not an approximation. Let
   `N` be `m * 10^d` rounded to the nearest integer, with ties going to the
   **even** integer.
4. Write `N` in decimal with no leading zeros (writing `0` for zero), then
   left-pad with `0` until it has at least `d + 1` digits, then, if `d > 0`,
   insert a `.` before the last `d` digits.
5. The result is the sign prefix followed by that.

This is exactly what a correct `printf("%.*f", d, x)` produces. Examples:

| Call | Result |
|---|---|
| `showFloatAt(1.0, 6)` | `1.000000` |
| `showFloatAt(0.1, 6)` | `0.100000` |
| `showFloatAt(2.0 / 3.0, 6)` | `0.666667` |
| `showFloatAt(-0.0, 6)` | `-0.000000` |
| `showFloatAt(2.5, 0)` | `2` |
| `showFloatAt(3.5, 0)` | `4` |
| `showFloatAt(0.5, 0)` | `0` |
| `showFloatAt(1.0 / 3.0, 10)` | `0.3333333333` |
| `showFloatAt(0.1 + 0.2, 17)` | `0.30000000000000004` |
| `showFloatAt(1e21, 2)` | `1000000000000000000000.00` |
| `showFloatAt(nanF(), 3)` | `nan` |
| `showFloatAt(-1.0 / 0.0, 3)` | `-inf` |

`showFloat(x)` is `showFloatAt(x, 6)`. A `d` outside 0…17 panics with
`digits out of range`.

Ties to even in step 3 refers to the exact value: `showFloatAt(2.675, 2)` is
`2.67`, because the stored double is 2.67499999999999982236431605997495353221893310546875,
which is below the tie.

### 14.4 Integers and floats

Integer and float operator semantics are in section 10.4. `toFloat` rounds to
nearest with ties to even (exact for |n| < 2^53). `truncToInt` truncates
toward zero and panics unless the truncated value is in [-2^63, 2^63).
`floatBits` and `floatFromBits` reinterpret the 64 bits, so a program can
construct and inspect any double exactly.

Floating-point operations must be the IEEE-754 binary64 ones, with no extra
precision, no contraction into fused multiply-add, and no reassociation. The
only library functions that round are `sqrtF` (exactly rounded by IEEE-754),
`toFloat`, `parseFloat` and the `showFloat…` printers; `powF` is defined as a
fixed sequence of multiplications (section 15) so that its result is bit-exact
everywhere.

### 14.5 Call depth

A frame is pushed for each call to a user function, a trait method, a trait
default body or a closure. Built-in functions use no frame. The call of `main` itself pushes the
first frame, so `main` plus 19999 nested calls is the deepest a program can
go. If a call would make the frame count exceed **20000**, the program panics
with `call stack overflow` instead.

### 14.6 Panics

Every panic prints `panic: ` followed by the message and one LF, then stops
the program. No LF is inserted before `panic: `, so after `emit("a")` a
panic with message `boom` leaves the output `apanic: boom` followed by an LF.

The complete list of messages:

| Message | Raised by |
|---|---|
| `divide by zero` | `a / b` with `b == 0`, and `divFloor` with `b == 0` |
| `modulo by zero` | `a % b` with `b == 0`, and `modFloor` with `b == 0` |
| `shift amount out of range` | `<<` or `>>` with a right operand outside 0…63 |
| `index out of bounds` | list or string indexing, index assignment, `insert`, `removeAt`, `substr`, `slice`, `charAt` |
| `missing key` | `m[k]` for an absent key |
| `no match` | a `match` where every arm failed or had a false guard (unreachable in an accepted program: section 10.12) |
| `unwrap of None` | `unwrap` on `None` |
| `unwrap of Err` | `unwrapOk` on `Err` |
| `unwrap of Ok` | `unwrapErr` on `Ok` |
| `empty list` | `pop`, `listFirst`, `listLast` on an empty list |
| `invalid char code` | `chr` with an argument outside 0…0x10FFFF or inside 0xD800…0xDFFF |
| `float out of integer range` | `truncToInt` of NaN, an infinity, or a value whose truncation is outside [-2^63, 2^63) |
| `negative count` | `strRepeat`, `listRepeat`, `padLeft`, `padRight` with a negative count |
| `negative exponent` | `powI` with a negative exponent, and `powF` with `n == intMin()` (section 15.3) |
| `empty separator` | `strSplit` or `strReplace` with an empty pattern |
| `bad format` | `fmt` with a malformed template or the wrong number of arguments |
| `radix out of range` | `showIntRadix` or `parseIntRadix` with a radix outside 2…36 |
| `digits out of range` | `showFloatAt` with a digit count outside 0…17 |
| `call stack overflow` | section 14.5 |
| *the argument* | `panic(msg)` prints `panic: ` then `msg` verbatim |

Panics are not catchable; there is no exception mechanism in the language.

## 15. Standard library

Every function below is a **built-in**: it lives in the prelude's values
namespace, is called like any other function, is typed by the generic-call
rule of section 9.4, and may not be used as a value (`bad-value-ref`). A
built-in uses no VM frame.

Type variables in the signatures behave exactly like a user function's: `T`,
`U`, `A`, `B`, `K`, `V`, `E`, with the bounds written. `Option` and `Result`
mean the prelude types, even in a module that shadows those names.

Any built-in that walks a list reads the list's **current** length before each
step, exactly as `for` does (section 11.4), so a callback that appends to the
list it is walking is defined behaviour.

### 15.1 Output and panicking

| Signature | Behaviour |
|---|---|
| `print(s: Str)` | writes `s` and one LF |
| `emit(s: Str)` | writes `s` |
| `panic(msg: Str)` | prints `panic: ` + `msg` + LF and stops the program |

### 15.2 Integers

| Signature | Behaviour |
|---|---|
| `intMin() -> Int` | -9223372036854775808 |
| `intMax() -> Int` | 9223372036854775807 |
| `absI(x: Int) -> Int` | the absolute value, wrapping, so `absI(intMin())` is `intMin()` |
| `minI(a: Int, b: Int) -> Int` | the smaller |
| `maxI(a: Int, b: Int) -> Int` | the larger |
| `signI(x: Int) -> Int` | -1, 0 or 1 |
| `cmpI(a: Int, b: Int) -> Int` | -1 if `a < b`, 0 if equal, 1 otherwise |
| `divFloor(a: Int, b: Int) -> Int` | quotient rounded toward -infinity; panics `divide by zero` when `b == 0`; `divFloor(intMin(), -1)` wraps to `intMin()` |
| `modFloor(a: Int, b: Int) -> Int` | `a - divFloor(a, b) * b` under wrapping, so the sign follows `b`; panics `modulo by zero` when `b == 0` |
| `powI(base: Int, exp: Int) -> Int` | `base` to the `exp`, wrapping; `exp == 0` gives 1; a negative `exp` panics `negative exponent` |
| `gcdI(a: Int, b: Int) -> Int` | the greatest common divisor of the exact absolute values, wrapped to 64 bits; `gcdI(0, 0)` is 0 |
| `popCount(x: Int) -> Int` | number of 1 bits in the two's-complement representation |
| `clz(x: Int) -> Int` | leading zero bits; `clz(0)` is 64 |
| `ctz(x: Int) -> Int` | trailing zero bits; `ctz(0)` is 64 |
| `toFloat(x: Int) -> Float` | nearest double, ties to even |
| `showInt(x: Int) -> Str` | decimal, a leading `-` only when negative, no `+`, no leading zeros; `showInt(intMin())` is `-9223372036854775808` |
| `showIntRadix(x: Int, radix: Int) -> Str` | as above in the given radix, digits `0`–`9` then lowercase `a`–`z`; the magnitude is taken as an unsigned 64-bit value so `intMin()` works; a radix outside 2…36 panics `radix out of range` |
| `parseInt(s: Str) -> Option<Int>` | see below |
| `parseIntRadix(s: Str, radix: Int) -> Option<Int>` | see below |

`parseInt(s)` accepts exactly: an optional single `+` or `-`, then one or more
ASCII digits, then end of string. No spaces, no `_`, no radix prefix, no empty
digit run. Leading zeros are fine. If the value does not fit in `Int` the
result is `None`; otherwise `Some(value)`. `parseIntRadix` is the same with
digits valid for the radix (`0`–`9`, `a`–`z`, `A`–`Z`, case-insensitive, each
below the radix); a radix outside 2…36 panics `radix out of range`.

### 15.3 Floats

| Signature | Behaviour |
|---|---|
| `sqrtF(x: Float) -> Float` | the IEEE-754 exactly-rounded square root; `sqrtF` of a negative is NaN, of `-0.0` is `-0.0` |
| `absF(x: Float) -> Float` | clears the sign bit |
| `floorF(x: Float) -> Float` | round toward -infinity |
| `ceilF(x: Float) -> Float` | round toward +infinity |
| `truncF(x: Float) -> Float` | round toward zero |
| `roundF(x: Float) -> Float` | round to nearest, ties **away from zero**; `roundF(2.5)` is 3.0, `roundF(-2.5)` is -3.0 |
| `minF(a: Float, b: Float) -> Float` | see the note after this table |
| `maxF(a: Float, b: Float) -> Float` | see the note after this table |
| `fmodF(a: Float, b: Float) -> Float` | the exact C `fmod`: `a - trunc(a / b) * b` computed exactly, sign of `a`; NaN when either argument is NaN, when `b` is ±0.0 or when `a` is infinite; `a` itself when `a` is finite and `b` is infinite |
| `powF(x: Float, n: Int) -> Float` | see below |
| `isNanF(x: Float) -> Bool` | true iff `x` is NaN |
| `isInfF(x: Float) -> Bool` | true iff `x` is +infinity or -infinity |
| `cmpF(a: Float, b: Float) -> Int` | -1, 0 or 1 by IEEE comparison; if either is NaN: 0 when both are, 1 when only `a` is, -1 when only `b` is (NaN sorts last) |
| `truncToInt(x: Float) -> Int` | truncation toward zero; panics `float out of integer range` for NaN, an infinity, or a truncated value outside [-2^63, 2^63) |
| `showFloat(x: Float) -> Str` | `showFloatAt(x, 6)` |
| `showFloatAt(x: Float, digits: Int) -> Str` | section 14.3; `digits` outside 0…17 panics `digits out of range` |
| `floatBits(x: Float) -> Int` | the 64 IEEE bits reinterpreted as a signed integer |
| `floatFromBits(bits: Int) -> Float` | the inverse; every bit pattern is accepted |
| `parseFloat(s: Str) -> Option<Float>` | see below |
| `infF() -> Float` | +infinity |
| `nanF() -> Float` | a NaN whose bits are `0x7ff8000000000000` |
| `piF() -> Float` | `floatFromBits(4614256656552045848)`, i.e. 3.141592653589793 |

`floorF`, `ceilF`, `truncF` and `roundF` return NaN, ±infinity and ±0.0
unchanged, and otherwise a result with the sign of `x`: a zero result from a
negative argument is `-0.0` (`ceilF(-0.5)` and `roundF(-0.4)` are `-0.0`).

`minF(a, b)` returns `a` when `cmpF(a, b) <= 0` and `b` otherwise;
`maxF(a, b)` returns `a` when `cmpF(a, b) >= 0` and `b` otherwise. Because
`cmpF` ranks NaN last, `minF(nanF(), 1.0)` is 1.0 and `maxF(nanF(), 1.0)` is
NaN. `minF(-0.0, 0.0)` is `-0.0` (the first argument, since `cmpF` says they
are equal) and `minF(0.0, -0.0)` is `0.0`.

`powF(x, n)`: for `n >= 0` the result is exactly what this loop computes,
with every multiplication an ordinary IEEE binary64 multiplication:

```
r = 1.0; b = x; k = n;
while k > 0 {
    if (k & 1) == 1 { r = r * b; }
    k = k >> 1;
    if k > 0 { b = b * b; }
}
```

For `n < 0` the result is `1.0 / powF(x, -n)`; for `n == intMin()` the panic
is `negative exponent`.

`parseFloat(s)` accepts exactly: an optional `+` or `-`; then either one or
more digits with an optional `.` and more digits (`12`, `12.`, `12.5`) or a
`.` followed by one or more digits (`.5`); then optionally `e` or `E`, an
optional sign and one or more digits. Nothing else, no spaces, no `_`, no
`inf`/`nan` words. The value is the correctly rounded (ties to even) nearest
binary64 number, becoming an infinity on overflow and a subnormal or zero on
underflow. Anything the grammar rejects gives `None`.

### 15.4 Bools and chars

| Signature | Behaviour |
|---|---|
| `showBool(b: Bool) -> Str` | `true` or `false` |
| `ord(c: Char) -> Int` | the scalar value |
| `chr(n: Int) -> Char` | the character with that scalar value; panics `invalid char code` outside 0…1114111 or inside 55296…57343 |
| `isDigit(c: Char) -> Bool` | `0`–`9` |
| `isAlpha(c: Char) -> Bool` | `A`–`Z`, `a`–`z` |
| `isAlnum(c: Char) -> Bool` | `isDigit` or `isAlpha` |
| `isSpace(c: Char) -> Bool` | U+0009, U+000A, U+000B, U+000C, U+000D or U+0020 |
| `isUpper(c: Char) -> Bool` | `A`–`Z` |
| `isLower(c: Char) -> Bool` | `a`–`z` |
| `toUpperC(c: Char) -> Char` | `a`–`z` shifted by -32, everything else unchanged |
| `toLowerC(c: Char) -> Char` | `A`–`Z` shifted by +32, everything else unchanged |
| `cmpC(a: Char, b: Char) -> Int` | -1, 0, 1 by scalar value |
| `showChar(c: Char) -> Str` | the one-character string containing `c` |
| `quoteChar(c: Char) -> Str` | `'` + the escape of `c` + `'`; see section 15.5 |

All character classification and case conversion is **ASCII only**; no Unicode
tables are needed anywhere in this problem.

### 15.5 Strings

Indices and lengths count Unicode scalar values.

| Signature | Behaviour |
|---|---|
| `strLen(s: Str) -> Int` | number of scalar values |
| `charAt(s: Str, i: Int) -> Char` | scalar `i`; panics `index out of bounds` unless 0 ≤ `i` < `strLen(s)` |
| `substr(s: Str, from: Int, to: Int) -> Str` | scalars `from`…`to-1`; panics `index out of bounds` unless 0 ≤ `from` ≤ `to` ≤ `strLen(s)` |
| `strCat(a: Str, b: Str) -> Str` | `a ++ b` |
| `strRepeat(s: Str, n: Int) -> Str` | `n` copies; `n == 0` gives `""`; a negative `n` panics `negative count` |
| `strIndexOf(s: Str, sub: Str) -> Int` | the smallest `i` with `sub` occurring at `i`, or -1; an empty `sub` gives 0 |
| `strLastIndexOf(s: Str, sub: Str) -> Int` | the largest such `i`, or -1; an empty `sub` gives `strLen(s)` |
| `strContains(s: Str, sub: Str) -> Bool` | `strIndexOf(s, sub) >= 0` |
| `startsWith(s: Str, p: Str) -> Bool` | |
| `endsWith(s: Str, p: Str) -> Bool` | |
| `strSplit(s: Str, sep: Str) -> [Str]` | see below |
| `strJoin(parts: [Str], sep: Str) -> Str` | the parts with `sep` between consecutive ones; an empty list gives `""` |
| `strReplace(s: Str, from: Str, to: Str) -> Str` | see below |
| `trim(s: Str) -> Str` | removes leading and trailing characters for which `isSpace` holds |
| `trimLeft(s: Str) -> Str` | leading only |
| `trimRight(s: Str) -> Str` | trailing only |
| `upper(s: Str) -> Str` | `toUpperC` on every scalar |
| `lower(s: Str) -> Str` | `toLowerC` on every scalar |
| `strCmp(a: Str, b: Str) -> Int` | -1, 0 or 1; compares scalar by scalar, and a proper prefix is smaller |
| `chars(s: Str) -> [Char]` | a new list of its scalars |
| `strOfChars(cs: [Char]) -> Str` | the string of those scalars in order |
| `strReverse(s: Str) -> Str` | scalars in reverse order |
| `quoteStr(s: Str) -> Str` | `"` + the escapes of its scalars + `"`; see below |
| `padLeft(s: Str, width: Int, c: Char) -> Str` | `s` unchanged if `strLen(s) >= width`, else `width - strLen(s)` copies of `c` then `s`; a negative `width` panics `negative count` |
| `padRight(s: Str, width: Int, c: Char) -> Str` | the same, padding on the right |

`strSplit(s, sep)`: `sep` must be non-empty (else the panic `empty
separator`). Scan `s` from the left for non-overlapping occurrences of `sep`;
the result is the list of the pieces between them, in order, including empty
pieces. The result always has (number of occurrences + 1) elements:
`strSplit("a,,b", ",")` is `["a", "", "b"]`, `strSplit("", ",")` is `[""]`,
`strSplit(",a,", ",")` is `["", "a", ""]`, `strSplit("aaa", "aa")` is
`["", "a"]`.

`strReplace(s, from, to)`: `from` must be non-empty (else `empty separator`).
Scan from the left; at each position, if `from` occurs there, append `to` and
continue scanning after the occurrence (never inside the inserted text);
otherwise append the one scalar and move on. `strReplace("aaa", "aa", "b")` is
`"ba"`.

**Escaping** (used by `quoteStr` and `quoteChar`): `\` becomes `\\`; in
`quoteStr` only, `"` becomes `\"`; in `quoteChar` only, `'` becomes `\'`;
U+000A becomes `\n`, U+000D becomes `\r`, U+0009 becomes `\t`; any other
scalar below U+0020, and U+007F, becomes `\u{` + its value in lowercase
hexadecimal with no leading zeros + `}`; every other scalar is written as
itself. So `quoteStr("a\"b\n")` is `"a\"b\n"` (8 characters) and
`quoteChar('\u{1}')` is `'\u{1}'`.

### 15.6 Lists

| Signature | Behaviour |
|---|---|
| `listNew<T>() -> [T]` | a new empty list |
| `listLen<T>(xs: [T]) -> Int` | the current length |
| `push<T>(xs: [T], x: T)` | appends `x` |
| `pop<T>(xs: [T]) -> T` | removes and returns the last element; panics `empty list` when empty |
| `insert<T>(xs: [T], i: Int, x: T)` | inserts before index `i`, shifting the rest right; panics `index out of bounds` unless 0 ≤ `i` ≤ `listLen(xs)` |
| `removeAt<T>(xs: [T], i: Int) -> T` | removes and returns element `i`, shifting the rest left; panics `index out of bounds` unless 0 ≤ `i` < `listLen(xs)` |
| `clear<T>(xs: [T])` | removes every element |
| `listRepeat<T>(x: T, n: Int) -> [T]` | a new list of `n` copies of the same value; a negative `n` panics `negative count` |
| `listConcat<T>(a: [T], b: [T]) -> [T]` | `a ++ b`, a new list; neither argument changes |
| `slice<T>(xs: [T], from: Int, to: Int) -> [T]` | a new list of elements `from`…`to-1`; panics `index out of bounds` unless 0 ≤ `from` ≤ `to` ≤ `listLen(xs)` |
| `listCopy<T>(xs: [T]) -> [T]` | a new list with the same elements |
| `reverseList<T>(xs: [T]) -> [T]` | a new list in reverse order |
| `listFirst<T>(xs: [T]) -> T` | element 0; panics `empty list` when empty |
| `listLast<T>(xs: [T]) -> T` | the last element; panics `empty list` when empty |
| `listMap<T, U>(xs: [T], f: fn(T) -> U) -> [U]` | a new list of `f` applied to each element, from index 0 upward |
| `listFilter<T>(xs: [T], f: fn(T) -> Bool) -> [T]` | a new list of the elements for which `f` is true, in order |
| `listFold<T, A>(xs: [T], init: A, f: fn(A, T) -> A) -> A` | left fold: `f(… f(f(init, x0), x1) …)` |
| `listAny<T>(xs: [T], f: fn(T) -> Bool) -> Bool` | true if `f` holds for some element; stops at the first true |
| `listAll<T>(xs: [T], f: fn(T) -> Bool) -> Bool` | true if `f` holds for every element; stops at the first false |
| `listFind<T>(xs: [T], f: fn(T) -> Bool) -> Option<T>` | `Some` of the first element for which `f` holds, else `None`; stops there |
| `listFindIndex<T>(xs: [T], f: fn(T) -> Bool) -> Int` | the index of that element, or -1 |
| `listIndexOf<T: Eq>(xs: [T], x: T) -> Int` | the smallest index whose element `==` `x`, or -1 |
| `listContains<T: Eq>(xs: [T], x: T) -> Bool` | `listIndexOf(xs, x) >= 0` |
| `listZip<A, B>(a: [A], b: [B]) -> [(A, B)]` | pairs by index, length = the smaller of the two lengths read at the start |
| `listFlatten<T>(xss: [[T]]) -> [T]` | a new list, the inner lists concatenated in order |
| `sortBy<T>(xs: [T], cmp: fn(T, T) -> Int) -> [T]` | a new, stably sorted list; see below |

`sortBy` is a bottom-up merge sort, specified exactly because the comparator
may print or count calls. Let `n` be the list's length at the start and let
`src` be a copy of its elements. If `n <= 1` the result is `src`. Otherwise,
with a second buffer `dst` of the same length:

```
width = 1
while width < n {
    i = 0
    while i < n {
        lo = i
        mid = min(i + width, n)
        hi  = min(i + 2 * width, n)
        // merge src[lo..mid) and src[mid..hi) into dst[lo..hi)
        a = lo; b = mid; k = lo
        while a < mid && b < hi {
            if cmp(src[a], src[b]) <= 0 { dst[k] = src[a]; a = a + 1 }
            else                        { dst[k] = src[b]; b = b + 1 }
            k = k + 1
        }
        while a < mid { dst[k] = src[a]; a = a + 1; k = k + 1 }
        while b < hi  { dst[k] = src[b]; b = b + 1; k = k + 1 }
        i = i + 2 * width
    }
    swap src and dst
    width = width * 2
}
result = src
```

The comparator is called only in the inner merge loop, always as
`cmp(<element from the left run>, <element from the right run>)`, and the
left element wins ties — so the sort is stable. A comparator that is not a
valid ordering still produces this exact permutation, and one that mutates
`xs` cannot affect the sort, which works on the copy.

### 15.7 Maps

Iteration order is **insertion order**: the order in which keys were first
inserted. Re-assigning an existing key keeps its position; deleting a key and
inserting it again puts it at the end.

| Signature | Behaviour |
|---|---|
| `mapNew<K: Key, V>() -> #[K: V]` | a new empty map |
| `mapLen<K: Key, V>(m: #[K: V]) -> Int` | the number of entries |
| `mapHas<K: Key, V>(m: #[K: V], k: K) -> Bool` | whether `k` is present |
| `mapGet<K: Key, V>(m: #[K: V], k: K) -> Option<V>` | `Some(value)` or `None` |
| `mapGetOr<K: Key, V>(m: #[K: V], k: K, dflt: V) -> V` | the value, or `dflt`; `dflt` is always evaluated |
| `mapSet<K: Key, V>(m: #[K: V], k: K, v: V)` | same as `m[k] = v` |
| `mapDel<K: Key, V>(m: #[K: V], k: K) -> Bool` | removes `k`, returning whether it was there |
| `keysOf<K: Key, V>(m: #[K: V]) -> [K]` | a new list of the keys in insertion order |
| `valuesOf<K: Key, V>(m: #[K: V]) -> [V]` | a new list of the values in insertion order |
| `pairsOf<K: Key, V>(m: #[K: V]) -> [(K, V)]` | a new list of `(key, value)` in insertion order |
| `mapClear<K: Key, V>(m: #[K: V])` | removes every entry |
| `mapCopy<K: Key, V>(m: #[K: V]) -> #[K: V]` | a new map with the same entries in the same order |

Keys are compared with `==` (section 10.4), so `-0.0`-style surprises cannot
arise: `Float` is not a `Key`.

### 15.8 Option, Result and tuples

| Signature | Behaviour |
|---|---|
| `isSome<T>(o: Option<T>) -> Bool` | |
| `isNone<T>(o: Option<T>) -> Bool` | |
| `unwrap<T>(o: Option<T>) -> T` | the payload; panics `unwrap of None` for `None` |
| `unwrapOr<T>(o: Option<T>, dflt: T) -> T` | the payload or `dflt`; `dflt` is always evaluated |
| `isOk<T, E>(r: Result<T, E>) -> Bool` | |
| `isErr<T, E>(r: Result<T, E>) -> Bool` | |
| `unwrapOk<T, E>(r: Result<T, E>) -> T` | panics `unwrap of Err` for `Err` |
| `unwrapErr<T, E>(r: Result<T, E>) -> E` | panics `unwrap of Ok` for `Ok` |
| `fst<A, B>(t: (A, B)) -> A` | the first component of a pair |
| `snd<A, B>(t: (A, B)) -> B` | the second component of a pair |

`fst` and `snd` exist only for 2-tuples; larger tuples are taken apart with
patterns.

### 15.9 Formatting

`fmt(template: Str, args: [Str]) -> Str` builds a string by scanning
`template` from the left:

- `{}` is replaced by the next unused element of `args`;
- `{{` produces one `{` and `}}` produces one `}`;
- any other character is copied;
- a `{` followed by anything but `{` or `}`, or at the end of the template, is
  the panic `bad format`;
- a `}` not followed by `}` is the panic `bad format`;
- if `{}` appears more times than `args` has elements, or fewer, the panic is
  `bad format` (the count must match exactly). The count is checked after the
  whole template has been scanned, so a malformed brace is reported first.

Examples: `fmt("{} + {} = {}", ["1", "2", "3"])` is `1 + 2 = 3`;
`fmt("{{{}}}", ["x"])` is `{x}`; `fmt("100%", [])` is `100%`.

### 15.10 The complete list

All 132 built-in names, alphabetically — an implementation that is missing one
will fail a test that uses it:

`absF`  `absI`  `ceilF`  `charAt`  `chars`  `chr`
`clear`  `clz`  `cmpC`  `cmpF`  `cmpI`  `ctz`
`divFloor`  `emit`  `endsWith`  `floatBits`  `floatFromBits`  `floorF`
`fmodF`  `fmt`  `fst`  `gcdI`  `infF`  `insert`
`intMax`  `intMin`  `isAlnum`  `isAlpha`  `isDigit`  `isErr`
`isInfF`  `isLower`  `isNanF`  `isNone`  `isOk`  `isSome`
`isSpace`  `isUpper`  `keysOf`  `listAll`  `listAny`  `listConcat`
`listContains`  `listCopy`  `listFilter`  `listFind`  `listFindIndex`  `listFirst`
`listFlatten`  `listFold`  `listIndexOf`  `listLast`  `listLen`  `listMap`
`listNew`  `listRepeat`  `listZip`  `lower`  `mapClear`  `mapCopy`
`mapDel`  `mapGet`  `mapGetOr`  `mapHas`  `mapLen`  `mapNew`
`mapSet`  `maxF`  `maxI`  `minF`  `minI`  `modFloor`
`nanF`  `ord`  `padLeft`  `padRight`  `pairsOf`  `panic`
`parseFloat`  `parseInt`  `parseIntRadix`  `piF`  `pop`  `popCount`
`powF`  `powI`  `print`  `push`  `quoteChar`  `quoteStr`
`removeAt`  `reverseList`  `roundF`  `showBool`  `showChar`  `showFloat`
`showFloatAt`  `showInt`  `showIntRadix`  `signI`  `slice`  `snd`
`sortBy`  `sqrtF`  `startsWith`  `strCat`  `strCmp`  `strContains`
`strIndexOf`  `strJoin`  `strLastIndexOf`  `strLen`  `strOfChars`  `strRepeat`
`strReplace`  `strReverse`  `strSplit`  `substr`  `toFloat`  `toLowerC`
`toUpperC`  `trim`  `trimLeft`  `trimRight`  `truncF`  `truncToInt`
`unwrap`  `unwrapErr`  `unwrapOk`  `unwrapOr`  `upper`  `valuesOf`

## 16. Bytecode and the virtual machine

An implementation **must** be structured as a compiler to bytecode plus a
stack machine: source text → tokens → AST → items and name resolution → type
checking → bytecode → execution. It must not interpret the AST directly. Two
observable things depend on this: the 20000-frame limit of section 14.5 (which
counts VM frames, not host-language recursion, so deep Vellum recursion must
work in a flat loop), and the performance expectations of section 18.

Nothing in this section is directly observable — there is no bytecode dump
mode — but the instruction set below is the one the problem is specified
against, and an implementation that follows it will match the required
evaluation order and limits for free.

### 16.1 The compiled program

A compiled program is:

- a **constant pool**: the distinct `Int`, `Float`, `Char` and `Str` literals
  needed by the code;
- a **function table**: one entry per user function, per impl method, per
  trait default body and per lambda, each with a parameter count, a local slot
  count, an upvalue descriptor list and a code array;
- a **struct table**: field counts and names, for field offsets;
- an **enum table**: variants with payload counts;
- an **impl table**: a map from (trait index, head constructor) to the
  function indices of that impl's methods, with the trait's default bodies
  filling the gaps;
- the index of `main`.

A **frame** holds a function index, a return address, and a base offset into
the value stack. Local slot `i` of the current frame is the value stack entry
at `base + i`. A method's slot 0 is `self`; a function's slots 0…n-1 are its
parameters, in order; the remaining slots are its block-scoped locals,
assigned by the compiler (slots may be reused by disjoint scopes).

An **upvalue** is a captured value copied into the closure object when
`MAKE_CLOSURE` runs; a closure's upvalue list is fixed at creation and is
read-only (section 10.10).

### 16.2 Instructions

Operands are compile-time constants (pool indices, slot numbers, jump targets,
counts). "Pops a, b" means b is on top.

| Instruction | Operands | Effect |
|---|---|---|
| `PUSH_CONST` | k | pushes constant k |
| `PUSH_TRUE`, `PUSH_FALSE`, `PUSH_UNIT` | — | pushes that value |
| `LOAD_LOCAL` | i | pushes local slot i |
| `STORE_LOCAL` | i | pops a value into local slot i |
| `LOAD_UPVAL` | i | pushes upvalue i of the running closure |
| `POP` | — | discards the top value |
| `DUP` | — | duplicates the top value |
| `MAKE_CLOSURE` | f, n | pops n values as upvalues, pushes a closure over function f |
| `CALL` | f, argc | pops argc arguments, pushes a frame for function f |
| `CALL_VALUE` | argc | pops argc arguments and then a closure, and calls it |
| `CALL_BUILTIN` | b, argc | pops argc arguments, pushes the built-in's result (no frame) |
| `CALL_METHOD` | t, m, argc | the receiver sits under the argc arguments; resolves method m of trait t from the receiver's tag and calls it |
| `RET` | — | pops the result, drops the frame, pushes the result in the caller |
| `RET_UNIT` | — | as `RET` with the unit value |
| `ADD_I`, `SUB_I`, `MUL_I`, `DIV_I`, `MOD_I` | — | integer arithmetic (section 10.4) |
| `NEG_I`, `BNOT` | — | integer negation, complement |
| `BAND`, `BOR`, `BXOR`, `SHL`, `SHR` | — | bitwise |
| `ADD_F`, `SUB_F`, `MUL_F`, `DIV_F`, `NEG_F` | — | binary64 arithmetic |
| `NOT_B` | — | logical not |
| `EQ`, `NE` | — | structural equality (section 10.4) |
| `LT`, `LE`, `GT`, `GE` | — | ordering on `Int`, `Float`, `Bool`, `Char`, `Str` |
| `CONCAT_STR`, `CONCAT_LIST` | — | `++` |
| `JUMP` | t | unconditional |
| `JUMP_IF_FALSE`, `JUMP_IF_TRUE` | t | pops a `Bool` and branches on it |
| `MAKE_LIST` | n | pops n values into a new list |
| `MAKE_MAP` | n | pops 2n values (key, value, key, value, … bottom to top) into a new map |
| `MAKE_TUPLE` | n | pops n values into a tuple |
| `MAKE_STRUCT` | s, n | pops n field values (declaration order) into a struct instance |
| `MAKE_ENUM` | e, v, n | pops n payloads into a value of variant v of enum e |
| `GET_FIELD` | i | pops a struct, pushes field i |
| `GET_PAYLOAD` | i | pops an enum value, pushes payload i |
| `GET_TUPLE` | i | pops a tuple, pushes component i |
| `INDEX_GET` | — | pops a container and an index, pushes the element (panics per section 10.5) |
| `INDEX_SET` | — | pops a container, an index and a value, stores it |
| `IS_VARIANT` | v | peeks at an enum value, pushes whether its variant is v |
| `SEQ_LEN` | — | peeks at a list or string, pushes its length |
| `SEQ_GET` | — | pops an index and peeks the sequence under it, pushing the element |
| `LIST_REST` | i | peeks at a list, pushes a new list of its elements from index i |
| `NO_MATCH` | — | the panic `no match` |
| `PANIC` | — | pops a `Str` and panics with it |
| `HALT` | — | ends the program (end of `main`) |

A `match` compiles to a chain of tests per arm using `IS_VARIANT`, `EQ`,
`SEQ_LEN`, `GET_PAYLOAD`, `GET_FIELD`, `GET_TUPLE`, `LIST_REST`,
`STORE_LOCAL` and conditional jumps, with the guard (if any) evaluated after
the pattern's bindings are stored, falling through to the next arm's test on
failure and reaching `NO_MATCH` after the last arm. A `for` over a sequence
compiles to an index local, `SEQ_LEN`, `LT`, `SEQ_GET` and jumps; a range
`for` to two locals and `LT`.

### 16.3 Determinism

The VM is fully deterministic. There is no address-dependent behaviour, no
hashing order (map order is insertion order, which a compiled implementation
should get from an index vector plus a hash table, or from a simple
association structure), no uninitialised memory and no reliance on host
integer width beyond 64 bits. The same program always produces the same
output.

## 17. Worked examples

Each example gives the complete stdin (including the `@module` headers) and
the exact stdout. Lines in the expected output never have trailing spaces
removed by this document; where one ends in a space it is shown as it is
produced.

### Example 1 — modules, imports and visibility

Input:

```
@module main
use greet;

fn main() {
    print(greet::hello("Vellum"));
    print(greet::hello("world"));
}
@module greet
pub fn hello(who: Str) -> Str {
    "hello, " ++ who ++ "!"
}

fn secret() -> Int { 42 }
```

Output:

```
hello, Vellum!
hello, world!
```

`secret` is private; nothing outside `greet` could name it, and never naming
it is not an error.

### Example 2 — recursion, loops, early return

Input:

```
@module main
fn fact(n: Int) -> Int {
    if n <= 1 { return 1; }
    n * fact(n - 1)
}

fn firstDivisor(n: Int) -> Int {
    var d = 2;
    while d * d <= n {
        if n % d == 0 { return d; }
        d = d + 1;
    }
    n
}

fn main() {
    print(showInt(fact(10)));
    for i in 2 .. 12 {
        if i % 2 == 0 { continue; }
        emit(showInt(firstDivisor(i)));
        emit(" ");
    }
    print("");
    var total = 0;
    for x in [3, 1, 4, 1, 5, 9, 2, 6] {
        if x == 9 { break; }
        total = total + x;
    }
    print(showInt(total));
}
```

Output:

```
3628800
3 5 7 3 11 
14
```

### Example 3 — structs, generics, Option, let patterns

Input:

```
@module main
struct Pair<A, B> { left: A, right: B }

struct Point { x: Int, y: Int }

fn swap<A, B>(p: Pair<A, B>) -> Pair<B, A> {
    Pair.{ left: p.right, right: p.left }
}

fn lookup(xs: [Point], x: Int) -> Option<Point> {
    for p in xs {
        if p.x == x { return Some(p); }
    }
    None
}

fn main() {
    let p = Pair.{ left: 7, right: "seven" };
    let q = swap(p);
    print(fmt("{} {}", [q.left, showInt(q.right)]));
    let pts = [Point.{ x: 1, y: 10 }, Point.{ x: 2, y: 20 }];
    match lookup(pts, 2) {
        Some(pt) -> print(fmt("found y={}", [showInt(pt.y)])),
        None -> print("none"),
    }
    let r: Option<Point> = lookup(pts, 5);
    print(showBool(isNone(r)));
    let Pair.{ left: l, right: rr } = p;
    print(fmt("{}/{}", [showInt(l), rr]));
}
```

Output:

```
seven 7
found y=20
true
7/seven
```

`swap(p)` instantiates `A := Int`, `B := Str` from the argument, so `q` has
type `Pair<Str, Int>` and `q.left` is a `Str`. The last `let` destructures a
struct with an irrefutable pattern.

### Example 4 — sum types, guards, nested and list patterns

Input:

```
@module main
enum Shape {
    Circle(Int),
    Rect(Int, Int),
    Group([Shape]),
    Empty,
}

fn area(s: Shape) -> Int {
    match s {
        Circle(r) when r <= 0 -> 0,
        Circle(r) -> 3 * r * r,
        Rect(w, h) -> w * h,
        Group([]) -> 0,
        Group([only]) -> area(only),
        Group([first, ..rest]) -> area(first) + area(Group(rest)),
        Empty -> 0,
    }
}

fn describe(s: Shape) -> Str {
    match s {
        Rect(w, h) when w == h -> "square",
        Rect(_, _) -> "rect",
        Circle(_) -> "circle",
        Group([Circle(_), ..]) -> "group starting with a circle",
        Group(_) -> "group",
        Empty -> "nothing",
    }
}

fn main() {
    let shapes = [Circle(2), Circle(-1), Rect(3, 4), Rect(5, 5), Empty,
                  Group([Circle(1), Rect(2, 2)])];
    for s in shapes {
        print(fmt("{} {}", [padRight(describe(s), 29, '.'), showInt(area(s))]));
    }
}
```

Output:

```
circle....................... 12
circle....................... 0
rect......................... 12
square....................... 25
nothing...................... 0
group starting with a circle. 7
```

Both matches are exhaustive. In `area` the list column has patterns of
lengths 0, 1 and "1 or more", so `Lmax` is 1 and lengths 0, 1 and 2 are all
covered. In `describe` the `Group(_)` arm covers every list, and the arm
before it is still reachable because an empty-length specialisation leaves it
useful.

### Example 5 — traits, impls, default methods, generic bounds

Input:

```
@module main
use shapes;

trait Render {
    fn render(self) -> Str;
    fn tag(self) -> Str { "?" }
}

impl Render for Int {
    fn render(self) -> Str { showInt(self) }
    fn tag(self) -> Str { "int" }
}

impl Render for Str {
    fn render(self) -> Str { quoteStr(self) }
}

impl<T: Render> Render for [T] {
    fn render(self) -> Str {
        let parts = listMap(self, |x| x.render());
        "[" ++ strJoin(parts, ", ") ++ "]"
    }
    fn tag(self) -> Str { "list" }
}

impl Render for shapes::Box {
    fn render(self) -> Str { fmt("{}x{}", [showInt(self.w), showInt(self.h)]) }
}

fn show2<T: Render>(x: T) -> Str {
    fmt("{}:{}", [x.tag(), x.render()])
}

fn main() {
    print(show2(42));
    print(show2("hi"));
    print(show2([1, 2, 3]));
    print(show2(shapes::mk(3, 4)));
    print(Render::render([["a"], ["b", "c"]]));
}
@module shapes
pub struct Box { w: Int, h: Int }

pub fn mk(w: Int, h: Int) -> Box { Box.{ w: w, h: h } }
```

Output:

```
int:42
?:"hi"
list:[1, 2, 3]
?:3x4
[["a"], ["b", "c"]]
```

`Str` and `Box` do not override `tag`, so the default body runs. The impl for
`[T]` is used at two different element types, including `[[Str]]`, and its
`x.render()` resolves from the element's own tag at run time.

### Example 6 — closures

Input:

```
@module main
fn counter(start: Int) -> fn(Int) -> Int {
    var base = start;
    let f = |d: Int| base + d;
    base = base + 100;
    f
}

fn main() {
    let f = counter(1);
    print(showInt(f(5)));

    var fs: [fn() -> Int] = listNew();
    for i in 0 .. 4 {
        push(fs, || i * i);
    }
    var acc = 0;
    for g in fs {
        acc = acc + g();
    }
    print(showInt(acc));

    let xs = [5, 3, 8, 1];
    print(strJoin(listMap(sortBy(xs, |a, b| cmpI(a, b)), |v| showInt(v)), ","));
    print(showInt(listFold(xs, 0, |a, x| a + x)));

    let shared = [1, 2];
    let grow = || push(shared, 3);
    grow();
    print(showInt(listLen(shared)));
}
```

Output:

```
6
14
1,3,5,8
17
3
```

The lambda is bound by a `let` with no annotation, so it is *synthesised* and
its parameter must carry one (`|d| …` there would be `cannot-infer`).
`f` captured `base` when the lambda was evaluated, so the later
`base = base + 100` is invisible to it: `f(5)` is `1 + 5`. Each loop iteration
binds a fresh `i`, so the four closures return 0, 1, 4 and 9. `shared` is a
list, so the closure and `main` see the same object.

### Example 7 — maps and deterministic order

Input:

```
@module main
fn main() {
    var counts = #["pear": 1];
    counts["apple"] = 2;
    counts["pear"] = counts["pear"] + 10;
    counts["fig"] = 0;
    mapDel(counts, "apple");
    counts["apple"] = 7;
    for k in keysOf(counts) {
        emit(fmt("{}={} ", [k, showInt(counts[k])]));
    }
    print("");
    print(showInt(mapLen(counts)));
    print(showBool(mapHas(counts, "plum")));
    print(showInt(unwrapOr(mapGet(counts, "plum"), -1)));
    let a = #[1: "x", 2: "y"];
    let b = #[2: "y", 1: "x"];
    print(showBool(a == b));
    for (k, v) in pairsOf(a) {
        emit(fmt("{}{} ", [showInt(k), v]));
    }
    print("");
}
```

Output:

```
pear=11 fig=0 apple=7 
3
false
-1
true
1x 2y 
```

`apple` was deleted and re-inserted, so it moved to the end; `pear` kept its
position when its value changed. Map equality ignores order.

### Example 8 — integers

Input:

```
@module main
fn main() {
    print(showInt(intMax() + 1));
    print(showInt(intMin() - 1));
    print(showInt(-7 / 2) ++ " " ++ showInt(-7 % 2));
    print(showInt(divFloor(-7, 2)) ++ " " ++ showInt(modFloor(-7, 2)));
    print(showInt(7 / -2) ++ " " ++ showInt(7 % -2));
    print(showInt(intMin() / -1));
    print(showIntRadix(255, 16) ++ " " ++ showIntRadix(-255, 2));
    print(showInt(1 << 62) ++ " " ++ showInt(-16 >> 2));
    print(showInt(0x0f & 0x1c) ++ " " ++ showInt(5 | 2) ++ " " ++ showInt(~0));
    print(showInt(powI(3, 20)) ++ " " ++ showInt(gcdI(-84, 36)));
    print(showInt(popCount(255)) ++ " " ++ showInt(clz(1)) ++ " " ++ showInt(ctz(8)));
    print(showBool(parseInt("x") == None));
    print(showInt(unwrapOr(parseInt("-0042"), 0)));
}
```

Output:

```
-9223372036854775808
9223372036854775807
-3 -1
-4 1
-3 1
-9223372036854775808
ff -11111111
4611686018427387904 -4
12 7 -1
3486784401 12
8 63 3
true
-42
```

Unary minus binds tighter than `/`, so `-7 / 2` is `(-7) / 2`, which
truncates toward zero to `-3`, while `divFloor` gives `-4`.

### Example 9 — floats

Input:

```
@module main
fn main() {
    print(showFloat(1.0));
    print(showFloat(2.0 / 3.0));
    print(showFloat(-0.0));
    print(showFloatAt(2.5, 0) ++ " " ++ showFloatAt(3.5, 0) ++ " " ++ showFloatAt(0.5, 0));
    print(showFloatAt(0.1 + 0.2, 17));
    print(showFloatAt(1.0 / 3.0, 10));
    print(showFloat(sqrtF(2.0)));
    print(showFloat(piF()));
    print(showFloatAt(nanF(), 2) ++ " " ++ showFloatAt(1.0 / 0.0, 2)
          ++ " " ++ showFloatAt(-1.0 / 0.0, 2));
    print(showInt(floatBits(1.0)));
    print(showFloat(powF(2.0, 10)) ++ " " ++ showFloat(powF(2.0, -2)));
    print(showInt(truncToInt(-3.9)) ++ " " ++ showFloat(roundF(-2.5))
          ++ " " ++ showFloat(floorF(-2.5)));
    print(showBool(nanF() == nanF()) ++ " " ++ showInt(cmpF(nanF(), 1.0)));
    print(showFloat(toFloat(9007199254740993)));
}
```

Output:

```
1.000000
0.666667
-0.000000
2 4 0
0.30000000000000004
0.3333333333
1.414214
3.141593
nan inf -inf
4607182418800017408
1024.000000 0.250000
-3 -3.000000 -3.000000
false 1
9007199254740992.000000
```

`showFloatAt(2.5, 0)` is `2` and `showFloatAt(3.5, 0)` is `4`: the tie goes to
the even digit. `toFloat(2^53 + 1)` rounds down to 2^53 for the same reason.

### Example 10 — strings and characters

Input:

```
@module main
fn main() {
    let s = "héllo, wörld";
    print(showInt(strLen(s)));
    print(showChar(charAt(s, 1)) ++ showChar(charAt(s, 8)));
    print(substr(s, 7, 12));
    print(upper(s));
    print(strJoin(strSplit("a,,b,", ","), "|"));
    print(strReplace("aaa", "aa", "b"));
    print(fmt("[{}] [{}]", [padLeft("7", 3, '0'), padRight("x", 3, '-')]));
    print(quoteStr("tab\there\n"));
    print(showInt(strIndexOf(s, "l")) ++ " " ++ showInt(strLastIndexOf(s, "l"))
          ++ " " ++ showInt(strIndexOf(s, "z")));
    print(strReverse("abc") ++ " " ++ trim("  pad  ") ++ "!");
    print(strOfChars([chr(86), 'e', 'l']));
    print(showInt(strCmp("abc", "abd")) ++ showInt(strCmp("ab", "ab"))
          ++ showInt(strCmp("b", "ab")));
    print(showBool(isSpace('\t')) ++ " " ++ quoteChar('\''));
}
```

Output:

```
12
éö
wörld
HéLLO, WöRLD
a||b|
ba
[007] [x--]
"tab\there\n"
2 10 -1
cba pad!
Vel
-101
true '\''
```

Indices count scalar values, so `charAt(s, 1)` is `é` and `substr(s, 7, 12)`
is `wörld`. `upper` touches only ASCII letters.

### Example 11 — a runtime panic after output

Input:

```
@module main
fn get(xs: [Int], i: Int) -> Int { xs[i] }

fn main() {
    let xs = [10, 20, 30];
    print(showInt(get(xs, 2)));
    print(showInt(get(xs, 3)));
    print("never reached");
}
```

Output:

```
30
panic: index out of bounds
```

The exit code is still 0.

### Example 12 — a type error, with its exact position

Input:

```
@module main
fn main() {
    let n: Int = 1;
    print(n + "x");
}
```

Output:

```
error: type-mismatch at 3:15
```

`+` synthesises its left operand (`Int`), then *checks* the right one against
`Int`; the string literal fails, and the position reported is that of the
right operand — line 3 of the module (the module's first line is
`fn main() {`), column 15.

### Example 13 — a non-exhaustive match

Input:

```
@module main
enum Colour { Red, Green, Blue }

fn name(c: Colour) -> Str {
    match c {
        Red -> "red",
        Green -> "green",
    }
}

fn main() { print(name(Blue)); }
```

Output:

```
error: non-exhaustive at 4:5
```

The position is the `match` keyword.

### Example 14 — an unsatisfied bound

Input:

```
@module main
trait Area { fn area(self) -> Int; }

struct Sq { s: Int }

fn total<T: Area>(xs: [T]) -> Int {
    var sum = 0;
    for x in xs { sum = sum + x.area(); }
    sum
}

fn main() {
    print(showInt(total([Sq.{ s: 3 }])));
}
```

Output:

```
error: unsatisfied-bound at 12:19
```

There is no `impl Area for Sq`, so the call cannot instantiate `T := Sq`. The
position is the callee's first token, `total`, in the call on line 12.

### Example 15 — which error is reported

Input:

```
@module main
fn main() {
    let x: Int = "s";
}
@module other
fn f( {
}
```

Output:

```
error: parse at 1:7
```

Parsing (pass 2) happens before body checking (pass 4), and the parse error is
in module `other`, whose lines are numbered from its own first line. The type
error in `main` is never reached.

### Example 16 — a bigger program

Input:

```
@module main
enum Tok { Num(Int), Var(Str), Op(Char) }

fn tokenize(src: Str) -> [Tok] {
    var out: [Tok] = listNew();
    var i = 0;
    let n = strLen(src);
    while i < n {
        let c = charAt(src, i);
        if isSpace(c) {
            i = i + 1;
        } else if isDigit(c) {
            var v = 0;
            while i < n && isDigit(charAt(src, i)) {
                v = v * 10 + (ord(charAt(src, i)) - 48);
                i = i + 1;
            }
            push(out, Num(v));
        } else if isAlpha(c) {
            var j = i;
            while j < n && isAlnum(charAt(src, j)) { j = j + 1; }
            push(out, Var(substr(src, i, j)));
            i = j;
        } else {
            push(out, Op(c));
            i = i + 1;
        }
    }
    out
}

fn evalRpn(toks: [Tok], env: #[Str: Int]) -> Result<Int, Str> {
    var stack: [Int] = listNew();
    for t in toks {
        match t {
            Num(v) -> push(stack, v),
            Var(name) -> match mapGet(env, name) {
                Some(v) -> push(stack, v),
                None -> { return Err("unbound " ++ name); }
            },
            Op(c) -> {
                if listLen(stack) < 2 { return Err("stack underflow"); }
                let b = pop(stack);
                let a = pop(stack);
                match c {
                    '+' -> push(stack, a + b),
                    '-' -> push(stack, a - b),
                    '*' -> push(stack, a * b),
                    '/' -> if b == 0 { return Err("divide by zero"); }
                           else { push(stack, a / b) },
                    _ -> { return Err("bad op " ++ showChar(c)); }
                }
            },
        }
    }
    if listLen(stack) == 1 { Ok(listLast(stack)) } else { Err("leftover") }
}

fn main() {
    let env = #["x": 10, "y": 4];
    let progs = ["3 4 +", "x y -", "2 3 4 * +", "x 0 /", "z 1 +", "1 2",
                 "5 1 2 + 4 * + 3 -"];
    for p in progs {
        match evalRpn(tokenize(p), env) {
            Ok(v) -> print(fmt("{} => {}", [p, showInt(v)])),
            Err(e) -> print(fmt("{} => error: {}", [p, e])),
        }
    }
}
```

Output:

```
3 4 + => 7
x y - => 6
2 3 4 * + => 14
x 0 / => error: divide by zero
z 1 + => error: unbound z
1 2 => error: leftover
5 1 2 + 4 * + 3 - => 14
```

Points of interest: the `Var` arm's body is itself a `match`; the `Op` arm's
body is a block whose trailing expression is a `match` checked against `Unit`
(each of its arms is either a `push` call or a diverging `return`); the
`'/'` arm is an `if`/`else` whose first branch diverges; and the function's
trailing expression is an `if`/`else` checked against `Result<Int, Str>`.

### Example 17 — more diagnostics

Each of these is a whole input, with the one line it must print.

```
@module main
fn main() {
    let x = 1;
    x = 2;
}
```
→ `error: assign-immutable at 3:5`

```
@module main
fn main() {
    var xs = [];
}
```
→ `error: cannot-infer at 2:14`

```
@module main
fn main() {
    match 3 {
        _ -> print("a"),
        1 -> print("b"),
    }
}
```
→ `error: unreachable at 4:9`

```
@module main
trait A { fn go(self) -> Int; }
trait B { fn go(self) -> Int; }

impl A for Int { fn go(self) -> Int { 1 } }
impl B for Int { fn go(self) -> Int { 2 } }

fn main() {
    print(showInt(3.go()));
}
```
→ `error: ambig-method at 8:21`

```
@module main
fn main() {
    print(showInt(len([1, 2])));
}
```
→ `error: unknown-name at 2:19`

```
@module main
fn f() -> Int {
    let x = 1;
}

fn main() { print(showInt(f())); }
```
→ `error: missing-return at 1:1`

```
@module main
struct S { a: Int, b: Int }

fn main() {
    let s = S.{ a: 1 };
    print(showInt(s.a));
}
```
→ `error: missing-field at 4:13`

```
@module main
fn main() {
    let t = (1, "two");
    print(showBool(t == (1, "two")));
    let f = |x: Int| x;
    print(showBool(f == f));
}
```
→ `error: not-eq at 5:20`

```
@module main
fn main() {
    for c in 'a' { print(showChar(c)); }
}
```
→ `error: not-iterable at 2:14`

```
@module main
fn main() {
    let m = #[1.5: "x"];
}
```
→ `error: bad-key-type at 2:15`

## 18. Limits, guarantees and performance

### 18.1 Input limits

Every test input satisfies these; behaviour outside them is not tested, but a
conforming implementation must not fail inside them.

| Quantity | Limit |
|---|---|
| stdin size | 8 MB |
| modules | 64 |
| lines in one module | 20000 |
| characters in one line | 4000 |
| items in one module | 2000 |
| identifier length | 200 |
| nesting depth of expressions, types and patterns | 200 |
| nesting depth of blocks and statements | 100 |
| function parameters, call arguments, function-type parameters | 16 |
| struct fields | 64 |
| enum variants | 64 |
| payloads per variant | 8 |
| tuple components | 8 |
| type parameters per declaration | 8 |
| local bindings live in one function | 1024 |
| match arms in one match | 256 |
| traits, and methods per trait | 64 |

The largest hand-written test program is about 500 lines in one module;
generated tests reach a few thousand lines spread over several modules.

### 18.2 Guarantees

- stdin is valid UTF-8.
- Programs are not adversarial about resource use: no test builds a list
  longer than about 4 million elements, a map with more than about 1 million
  entries, a string longer than about 4 million scalars, or output larger
  than about 2 MB.
- No test relies on the behaviour of a `for` range whose bounds difference
  overflows, on `powI` overflow beyond the defined wrapping, or on the
  identity of a NaN payload beyond the rules in sections 14.3 and 15.3.
- Tests that panic do so at a single, well-defined point; nothing in the
  language is order-dependent in an unspecified way.

### 18.3 Performance

- The heaviest tests execute on the order of 3 × 10^7 VM instructions
  (recursive workloads such as naive Fibonacci, sorting a few hundred
  thousand elements through `sortBy`, a tokeniser/evaluator written in Vellum
  running over a generated input, and map-heavy counting loops).
- Deep-recursion tests reach about 15000 frames, below the 20000 limit, and
  one test deliberately exceeds the limit to check the
  `call stack overflow` panic. Host-language recursion must therefore not be
  used for Vellum calls.
- A compiled implementation should finish every test in well under a second;
  the Python reference takes a few seconds on the heaviest ones. A per-test
  limit of 120 seconds is ample.
- `charAt` and `strLen` should be O(1), which means storing strings as arrays
  of scalar values (or as UTF-8 plus an index) rather than scanning: several
  tests index strings inside loops.
- Map operations should be O(1) amortised with insertion order preserved — a
  hash map from key to slot index plus a vector of entries, with deletion
  marking a hole or compacting, is enough.

## 19. Architecture and size

A complete implementation has these parts.

1. **Driver and module splitting** — about 150 lines: line splitting, header
   recognition, `bad-module` / `dup-module`, and the single-diagnostic
   printer.
2. **Lexer** — 400 to 600 lines: tokens, nested block comments, numeric
   literals with separators, escapes, positions.
3. **AST and parser** — 1000 to 1400 lines: the recursive-descent parser of
   section 4, including the block-body rule, the precedence climb, lambdas,
   struct literals and patterns.
4. **Items, namespaces and type resolution** — 700 to 1000 lines: the four
   namespaces, `use`, visibility, the prelude, resolving every written type,
   `arity-type`, `bad-key-type`, `Self`.
5. **Built-in traits and the impl registry** — 400 to 600 lines: structural
   `Eq`/`Ord`/`Key` with the recursive-type assumption set, impl heads,
   coherence, trait/impl signature matching, default-method inheritance.
6. **Type checker** — 1500 to 2000 lines: the bidirectional rules of sections
   9 and 10, unification with the occurs check, generic call instantiation,
   method resolution, assignment targets, divergence and `missing-return`.
7. **Patterns** — 600 to 800 lines: pattern typing, binding collection,
   irrefutability, and the usefulness algorithm of section 12.4 including the
   list rule.
8. **Bytecode compiler** — 1200 to 1600 lines: scopes and slot allocation,
   closure capture lists, short-circuit operators, loops with `break` and
   `continue` patch lists, and match compilation.
9. **Virtual machine** — 1000 to 1400 lines: value representation, frame
   stack, the instruction loop, structural equality and ordering, list and
   insertion-ordered map objects, panics.
10. **Standard library** — 1500 to 2000 lines: the 132 built-ins, each with
    its exact edge cases.
11. **Number formatting** — 150 to 400 lines: `showFloatAt` (usually a thin
    wrapper over the host's correctly-rounded `%.*f`), `showIntRadix`,
    `parseInt`, `parseFloat`.

Total: roughly **9,000 to 12,000 lines** in a systems language, and about
5,000 to 7,500 lines of Python for the reference.

Suggested order of work: driver and lexer, parser, items and types, the
checker for a Vellum subset without generics or traits, the compiler and VM
for that subset (at which point examples 1, 2 and 8 pass), then the standard
library, then generics and inference, then traits and impls, then
exhaustiveness. The seventeen examples of section 17 make a good first test
suite, in roughly that order of difficulty.
