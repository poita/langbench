# typeinfer — Hindley-Milner type inference

Read a program in a small ML-like language from stdin and print the
principal type of every top-level declaration, or an error line for each
declaration that does not type-check. Exit code 0 always; a type error is a
normal result. stderr is ignored.

This is classic Hindley-Milner (Damas-Milner) inference with
let-polymorphism, as in Algorithm W or Algorithm J: `let` and `let rec`
bindings are generalised, lambda-bound variables are monomorphic, recursive
functions are monomorphic inside their own body, and there is no value
restriction (every `let` is generalised, whatever its right-hand side).

## Input

The whole of stdin is one program in UTF-8 (in practice ASCII): a sequence
of zero or more declarations, each terminated by `;;`, with arbitrary
whitespace (possibly none) between and around them. A program that is empty
or contains only whitespace has zero declarations. Programs are
syntactically well formed; behaviour on malformed input is not tested.

### Lexical syntax

- Whitespace is space, tab, CR and LF. It separates tokens and is otherwise
  ignored. There are no comments.
- An integer literal is one or more ASCII digits, e.g. `0`, `42`,
  `123456789012345678901234567890`. Its value is irrelevant (only its type
  matters), so it may be arbitrarily long. There is no negative literal and
  no unary minus: write `0 - 5`.
- The keywords are `let rec in fun if then else true false`.
- An identifier is a lowercase letter `a`–`z` followed by any number of
  ASCII letters (either case), digits or `_`, and is not a keyword.
  Examples: `x`, `x1`, `acc_2`, `letx`, `funny`, `inx`. Identifiers are
  case-sensitive.
- The symbols are `;;` `->` `::` `<=` `>=` `&&` `||` `(` `)` `[` `]` `;`
  `,` `+` `-` `*` `/` `=` `<` `>`. The longest match wins (`->` is one
  token, `;;` is one token, `<=` is one token).
- Two adjacent tokens that could run together (an identifier or integer
  literal followed by another identifier, literal or keyword) are always
  separated by whitespace; `1x` and `x1y` do not occur.

### Grammar

```
program  := decl*
decl     := "let" ident ident* "=" expr ";;"          -- top-level binding
          | "let" "rec" ident ident+ "=" expr ";;"    -- top-level recursive binding
          | expr ";;"                                 -- bare expression

expr     := "let" ident ident* "=" expr "in" expr
          | "let" "rec" ident ident+ "=" expr "in" expr
          | "fun" ident+ "->" expr
          | "if" expr "then" expr "else" expr
          | or

or       := and ( "||" and )*                  -- left-associative
and      := cmp ( "&&" cmp )*                  -- left-associative
cmp      := cons ( cmpop cons )?               -- non-associative: at most one
cmpop    := "=" | "<" | ">" | "<=" | ">="
cons     := add ( "::" cons )?                 -- right-associative
add      := mul ( ("+" | "-") mul )*           -- left-associative
mul      := app ( ("*" | "/") app )*           -- left-associative
app      := atom atom*                         -- application, left-associative
atom     := integer | "true" | "false" | ident
          | "(" ")"                            -- unit
          | "(" expr ")"                       -- parenthesised expression
          | "(" expr ( "," expr )+ ")"         -- tuple of 2 or more
          | "[" "]"                            -- empty list
          | "[" expr ( ";" expr )* "]"         -- list of 1 or more
```

Notes on the grammar:

- Precedence from loosest to tightest: `let`/`fun`/`if` (their bodies
  extend as far right as possible), `||`, `&&`, comparison, `::`, `+ -`,
  `* /`, application. So `f x + g y * 2` is `(f x) + ((g y) * 2)`,
  `1 :: f x :: l` is `1 :: ((f x) :: l)`, `a < b && c` is `(a < b) && c`,
  and `fun x -> x + 1` has body `x + 1`. `a < b < c` does not occur.
- The body of a `fun`, the branches of an `if` and the body of a `let` are
  `expr`s, and an `expr` never contains a top-level `,` or `;` (tuples and
  lists exist only inside brackets). So such a body ends at the first `,`
  `;` `)` `]` `then` `else` `in` or `;;` that is not nested inside brackets:
  `(fun x -> x, 1)` is a pair of a function and an `int` (type
  `('a -> 'a) * int`), `[fun x -> x; fun y -> 1]` is a list of two
  functions (type `(int -> int) list`), and `(let y = 1 in y, 2)` is a pair
  of type `int * int`. (This differs from OCaml, where the body of
  `fun x -> x, 1` would extend over the comma.)
- A `let`, `fun` or `if` expression may appear as an operand of an operator
  or as an argument only when parenthesised (they are not `atom`s). The
  body of a `fun`, the branches of an `if`, the right-hand side and body of
  a `let`, the elements of tuples and lists, and a parenthesised expression
  are full `expr`s, so `fun x -> let y = x in y`, `if c then fun x -> x
  else fun y -> y` and `(1, fun x -> x)` are all valid. In `if a then b
  else c + 1`, the `else` branch is `c + 1`.
- A declaration that starts with `let` is always a top-level binding, never
  a bare let-expression; a let-expression used as a bare declaration is
  parenthesised: `(let x = 1 in x);;`.
- `let f x y = e` (with parameters) is sugar for `let f = fun x y -> e`, both
  at top level and in let-expressions. `let rec` requires at least one
  parameter: `let rec f x = e` means `f` is bound to `fun x -> e` recursively.
  `fun x y -> e` is `fun x -> fun y -> e`.
- `(e)` is just `e`; `()` is the unit value; a tuple needs at least two
  elements. `(e1, e2, e3)` is a 3-tuple, not a nested pair.
- There are no strings, no pattern matching, no sequencing (`;` only
  separates list elements), no `and`, no type annotations.

### Names

Variables are lexically scoped and may shadow anything, including the
built-ins: after `let map = 3;;`, `map` is an `int`. A `let` (without
`rec`) does not see the name it binds: in `let x = x + 1 in ...` the
right-hand `x` refers to an outer `x` (or is unbound). A `let rec` does see
its own name in its right-hand side. Parameters of one `fun` are distinct
names.

### Built-ins

The initial environment contains exactly these names, each with the given
polymorphic type scheme (every `'a`, `'b` is universally quantified):

```
not    : bool -> bool
fst    : 'a * 'b -> 'a
snd    : 'a * 'b -> 'b
hd     : 'a list -> 'a
tl     : 'a list -> 'a list
null   : 'a list -> bool
length : 'a list -> int
map    : ('a -> 'b) -> 'a list -> 'b list
fold   : ('a -> 'b -> 'a) -> 'a -> 'b list -> 'a
```

They are ordinary variables: they may be passed around, partially applied
and shadowed.

## Types

```
type := int | bool | unit
      | 'a                     -- type variable
      | type -> type           -- function
      | type * type * ... * type   -- tuple of n >= 2 components
      | type list
```

Tuple types of different arity are different types (`int * int` does not
unify with `int * int * int`) and a tuple type is not the same as a nested
pair (`int * int * int` is not `(int * int) * int`).

## Typing rules

The declarations are processed in order. Each is inferred in the current
top-level environment; a `let`/`let rec` declaration that succeeds adds its
(generalised) binding to that environment for all later declarations. A
declaration that fails adds nothing: the name keeps whatever binding it had
before (or stays unbound), and processing continues with the next
declaration.

Inference is standard Hindley-Milner:

- literals: integers are `int`, `true`/`false` are `bool`, `()` is `unit`,
  `[]` is `'a list` with a fresh `'a`.
- a variable is looked up in the environment and its type scheme is
  instantiated with fresh type variables. An unknown name is an error
  (`unbound`).
- `fun x -> e`: `x` gets a fresh monomorphic type variable `'a` in `e`; the
  result is `'a -> t` where `t` is the type of `e`.
- application `f a`: unify the type of `f` with `ta -> 'r` where `ta` is the
  type of `a` and `'r` is fresh; the result is `'r`.
- `let x = e1 in e2`: infer `e1` to get `t1`, generalise `t1` over every type
  variable that does not occur free in the environment, bind `x` to that
  scheme and infer `e2`. Generalisation happens for every `let`, including
  nested ones and ones whose right-hand side is an application (there is
  no value restriction): `let g = id id in (g 1, g true)` is well typed.
- `let rec f x = e1 in e2`: bind `f` to a fresh monomorphic type variable
  `'f`, infer `fun x -> e1` in that environment to get `t`, unify `'f` with
  `t`, then generalise `'f` as for `let` and infer `e2`. Inside `e1`, `f`
  is monomorphic (polymorphic recursion is not allowed): `let rec f x =
  f 1 + f true in ...` fails with `unify` (the first call fixes `f`'s
  argument type to `int`, the second cannot unify `bool` with it).
- `if c then a else b`: `c` must be `bool`; `a` and `b` must have the same
  type, which is the result.
- `(e1, ..., en)` has type `t1 * ... * tn`.
- `[e1; ...; en]`: all elements must have the same type `t`; the result is
  `t list`. `e1 :: e2`: if `e1 : t` then `e2` must be `t list`, and the
  result is `t list`.
- `+ - * /` take two `int`s and give `int`. `= < > <= >=` take two `int`s
  and give `bool` (they are not polymorphic: `true = false` is an error).
  `&& ||` take two `bool`s and give `bool`.

Top-level bindings are generalised exactly like nested ones.

### Error kinds

A declaration fails with exactly one of:

- `unbound` — a variable is not in scope.
- `occurs` — unification would bind a type variable `'a` to a type that
  contains `'a` (an infinite type), e.g. `fun x -> x x`.
- `unify` — any other unification failure: two different constructors
  (`int` vs `bool`, `int` vs `'a -> 'b`, `int list` vs `int`, tuples of
  different arity, ...).

When a declaration contains more than one problem, the kind reported is the
first one met in the following deterministic order, which is the natural
order of a single left-to-right recursive inference pass that unifies as it
goes (Algorithm J):

- Sub-expressions are inferred left to right, and each unification happens
  as soon as both sides are available:
  - `f a`: infer `f`, then infer `a`, then unify.
  - `e1 op e2`: infer `e1`, unify it with the operand type, then infer
    `e2`, unify it with the operand type.
  - `if c then a else b`: infer `c`, unify with `bool`; infer `a`; infer
    `b`; unify the branch types.
  - `[e1; ...; en]`: create a fresh element variable, then for each element
    in order: infer it and unify with the element variable.
  - `e1 :: e2`: infer `e1`, infer `e2`, then unify `e2`'s type with
    `t1 list`.
  - `let`/`let rec`: right-hand side before body; for `let rec` the
    unification of `'f` with the inferred function type happens right after
    the right-hand side, before the body.
  - tuples and `fun` bodies left to right.
- Inside one unification, `t1 -> t2` against `s1 -> s2` unifies `t1` with
  `s1` before `t2` with `s2`; tuples and lists likewise component by
  component left to right, each fully (recursively) before the next. The
  occurs check is performed whenever a variable is about to be bound.

Most test programs have at most one problem per declaration, so any correct
HM implementation reports the same kind; the order above settles the rest,
and one test is devoted to declarations where the order matters. For
instance `fun x -> if true then (x, 0) else ([x], true)` is `occurs`
(the first components `'a` and `'a list` are unified before the second
components `int` and `bool`), and `true + undefined` is `unify` (the left
operand is unified with `int` before the right operand is inferred).

## Output

One line per declaration, in order:

- `name : <type>` for a `let` or `let rec` declaration of `name`;
- `- : <type>` for a bare expression;
- `error: unify`, `error: occurs` or `error: unbound` on failure.

The printed type is the (generalised) principal type, rendered as follows:

- Type variables are renamed in order of first appearance when reading the
  printed type left to right: the first is `'a`, then `'b`, ..., `'z`, then
  `'a1`, `'b1`, ..., `'z1`, `'a2`, ... (variable number *i*, counting from
  0, is the letter `'a' + i mod 26` followed by `i div 26` if that is
  nonzero). Renaming is per declaration.
- `->` is right-associative and printed with spaces: `'a -> 'b -> 'c`. A
  function type on the *left* of an arrow is parenthesised:
  `('a -> 'b) -> 'a list -> 'b list`.
- Tuples are printed with ` * ` between components: `int * bool * unit`. A
  component that is itself a function or tuple type is parenthesised:
  `(int -> int) * (int * int) * int`. A tuple on either side of an arrow is
  not parenthesised: `'a * 'b -> 'a`, `int -> int * int`.
- `list` is postfix: `int list`, `int list list`. A function or tuple
  element type is parenthesised: `('a -> 'a) list`, `(int * bool) list`.
- Parentheses appear only where these rules require them. No other
  whitespace: exactly one space around `->` and `*`, one before `list`.

Every line ends with `\n`. An empty program produces no output.

## Examples

Input:

```
let id = fun x -> x;;
let compose f g x = f (g x);;
compose;;
let rec len l = if null l then 0 else 1 + len (tl l);;
(id 1, id true, len [true]);;
fun f -> (f 1, f true);;
```

Output:

```
id : 'a -> 'a
compose : ('a -> 'b) -> ('c -> 'a) -> 'c -> 'b
- : ('a -> 'b) -> ('c -> 'a) -> 'c -> 'b
len : 'a list -> int
- : int * bool * int
error: unify
```

(In the last declaration `f` is lambda-bound, hence monomorphic, so it
cannot be applied to both an `int` and a `bool`.)

Input:

```
let succ n = fun f x -> f (n f x);;
let add m n = fun f x -> m f (n f x);;
fun x -> x x;;
let g = id id;;
let id = fun x -> x;;
let g = id id;;
(g 1, g true);;
[fun p -> (snd p, fst p)];;
```

Output:

```
succ : (('a -> 'b) -> 'c -> 'a) -> ('a -> 'b) -> 'c -> 'b
add : ('a -> 'b -> 'c) -> ('a -> 'd -> 'b) -> 'a -> 'd -> 'c
error: occurs
error: unbound
id : 'a -> 'a
g : 'a -> 'a
- : int * bool
- : ('a * 'b -> 'b * 'a) list
```

(The first `let g` fails because `id` is not yet defined, so `g` stays
unbound until the second `let g`, which is generalised even though its
right-hand side is an application.)

Input:

```
let map = 3;;
map;;
fun a b c -> let p = (a, b) in (fun x -> [x; c], p, fst p);;
let rec bad x = bad 1 + bad true;;
1 :: [true];;
```

Output:

```
map : int
- : int
- : 'a -> 'b -> 'c -> ('c -> 'c list) * ('a * 'b) * 'a
error: unify
error: unify
```

## Limits

- Input is at most 1.2 MB and contains at most 6000 declarations.
- Expressions nest at most 5000 deep (this includes an application with
  5000 arguments, which is a chain of 5000 nested application nodes, and
  chains of 3000 parentheses, 2000 nested tuples, lists, `fun`s or `if`s,
  and 3000 nested `let ... in`s). A list literal may have 100,000 elements
  and a `::` chain 2000.
- A `fun` may have 1000 parameters; a type may mention more than 8000
  distinct type variables (so names like `'c315` occur).
- Inferred types can be large: nested 3000 deep, or with 2^12 leaves. The
  largest expected output is about 600 KB.
- Generalisation must not be quadratic in the size of the environment: one
  test has 5000+ top-level bindings and another 3000 nested `let`s.
