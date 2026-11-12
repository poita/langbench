# scheme — interpreter for a small Scheme subset

Read a Scheme program from stdin, evaluate its top-level forms in order, and
write to stdout: the printed value of every top-level form whose value is
not the void value (one per line), interleaved with whatever `display` and
`newline` emit. On a runtime error print `error: <category>` and stop.
The exit code is always 0 (an error inside the Scheme program is normal
output, not a process failure).

Integers are arbitrary precision. Proper tail calls are required: a loop
written as a tail call must run in constant stack for millions of
iterations. Non-tail recursion to a depth of 10,000 must also work.

Write the arbitrary-precision integer arithmetic yourself: don't use an
arbitrary-precision integer type or routine from a library, the standard
library or the language (including a built-in unbounded integer type as the
number representation; where the language's only integer type is unbounded,
use it for values that fit in a machine word).

## Input

The whole of stdin is one program: a sequence of zero or more forms
(datums) in UTF-8. Programs in the tests are syntactically well formed
(balanced parentheses, every special form used correctly, strings
terminated); behaviour on malformed input is not tested. Programs are at
most about 200 KB.

### Lexical syntax

- Whitespace: space, tab, CR, LF. Whitespace separates tokens and is
  otherwise ignored.
- Comments: `;` up to (not including) the next LF is ignored.
- `(` and `)` delimit lists. Square brackets are not used.
- `'x` is shorthand for `(quote x)`, for any datum `x`. In the tests the
  datum always follows the `'` immediately (no whitespace or comment
  between them).
- A string literal is `"` ... `"`. Inside it, `\"` is a double quote,
  `\\` a backslash, `\n` a newline (LF) and `\t` a tab. A raw LF inside a
  string literal is an ordinary character of the string. No other escapes
  occur.
- Any other token is a maximal run of characters that are not whitespace
  and not one of `(` `)` `'` `"` `;`. Such a token is:
  - `#t` or `#f`: the booleans true and false;
  - an optional `+` or `-` followed by one or more ASCII digits (e.g. `42`,
    `-7`, `+5`, `007`, `-0`): an integer, of any length (`-0` is `0`);
    a lone `+` or `-` is a symbol;
  - otherwise a symbol. Symbols are case-sensitive (`Foo` and `foo`
    differ). They may contain any non-delimiter characters, e.g. `+`, `-`,
    `...`, `set!`, `list->string`, `<=`, `a.b`, `1+`.
- Inside a list, the token `.` (a lone dot) followed by exactly one datum
  and then `)` makes an improper (dotted) list: `(1 2 . 3)` is
  `(cons 1 (cons 2 3))`. `()` is the empty list.

### Values

integer, boolean (`#t`/`#f`), string, symbol, pair, the empty list `()`,
procedure (primitive or closure), and the *void* value returned by
`define`, `set!`, `display`, `newline`, a one-armed `if` whose test is
false, and a `cond` with no matching clause.

Only `#f` is false. Every other value is true, including `0`, `()` and
`""`.

## Evaluation

Each top-level form is evaluated in order in the global environment. Its
value is then printed (see Output) unless it is void. Evaluation of an
application evaluates the operator first, then the operands left to right,
then applies. Wherever this document says "left to right" (operands,
`let`/`let*`/`letrec`/named-`let` inits, `cond` tests, `and`/`or` forms,
`begin` forms, `apply` arguments) the order is observable through
`display` and is tested. The initial global environment contains exactly the
primitives listed below; special-form names (`quote`, `if`, `define`,
`set!`, `lambda`, `let`, `let*`, `letrec`, `begin`, `cond`, `and`, `or`,
`else`) are reserved and never used as variables.

### Special forms

- `(quote d)` / `'d` — the datum `d` itself (integers, booleans, strings,
  symbols, lists, dotted lists, nested). `'()` is the empty list.
- `(if test then)` and `(if test then else)` — `test` is evaluated; if it is
  not `#f`, `then` is evaluated (in tail position); otherwise `else` is
  (in tail position), or void if there is no `else`.
- `(define name expr)` — evaluates `expr` and binds `name` in the
  *innermost current environment frame* (the global frame at top level,
  the frame of the enclosing procedure call or `let` when used inside a
  body). Rebinding an existing name in the same frame replaces it.
  Value: void.
- `(define (name . params) body...)` — same as
  `(define name (lambda params body...))`, where `params` may be a proper
  list `(a b)`, a dotted list `(a b . rest)` or a single symbol `rest`.
- `(set! name expr)` — evaluates `expr`, then assigns to the nearest
  enclosing binding of `name`. If no binding exists: `error:
  unbound-variable` (the expression has already been evaluated, so any
  output it produced stays). Value: void.
- `(lambda params body...)` — a closure over the current environment.
  `params` is `(a b c)` (fixed arity), `(a b . rest)` (at least two
  arguments; the extras are collected into a fresh proper list bound to
  `rest`) or `rest` (any number of arguments, as a list). The body is one
  or more forms; the value is that of the last, which is in tail position.
  Bodies may contain `define` forms anywhere (see `define`).
- `(let ((v init) ...) body...)` — evaluates all `init`s in the current
  environment (left to right), then evaluates the body in a new frame
  binding the `v`s. `(let () body...)` is allowed.
- `(let name ((v init) ...) body...)` (named let) — evaluates the `init`s
  left to right in the *current* environment (`name` is **not** visible to
  them; an outer variable called `name` is), then calls a procedure `name`
  with parameters `v...` and the given body. `name` is an ordinary variable
  bound in a frame of its own that sits between the current environment and
  the procedure's call frame, so it is visible inside the body (and only
  there), may be shadowed by a parameter, and may be `set!`. The call is in
  tail position with respect to the `let`.
- `(let* ((v init) ...) body...)` — exactly equivalent to nested `let`s,
  one per binding, with the body in the innermost: each `init` is evaluated
  with all earlier bindings of the same `let*` visible, each binding gets
  its own frame, and a `define` in the body lands in the innermost of those
  frames (so a closure created by an earlier `init` never sees it).
  `(let* () body...)` is allowed.
- `(letrec ((v init) ...) body...)` — creates a new frame, then evaluates
  the `init`s left to right *in that frame*, binding each `v` as soon as
  its `init` has been evaluated. Tests only reference a `letrec` variable
  before its initialisation from inside a `lambda` that is called later
  (the usual mutually recursive procedures).
- `(begin form...)` — evaluates the forms in order; value of the last (tail
  position). At least one form.
- `(cond clause...)` — each clause is `(test body...)` or `(test)` or, only
  as the last clause, `(else body...)`. Tests are evaluated in order; for
  the first one that is not `#f`, the value is that of its body (tail
  position), or the value of the test itself for a `(test)` clause. If no
  clause matches, void. The `=>` syntax is not used.
- `(and form...)` — evaluates left to right; the value is the first `#f`,
  or the value of the last form (tail position). `(and)` is `#t`.
- `(or form...)` — evaluates left to right; the value is the first non-`#f`
  value, or the value of the last form (tail position). `(or)` is `#f`.

"Tail position" means the implementation must not consume stack when the
form in that position is a procedure call. Tail positions: the last form of
a `lambda`, `define`-procedure, `let`, named `let`, `let*`, `letrec`,
`begin` or `cond`-clause body; both branches of `if`; the last operand of
`and` and `or`; and the call performed by `apply`. Tests run tail-recursive
loops of 200,000 iterations through every one of these (test
`tail_positions`), 1,000,000 iterations through `apply`, `or` and `cond`,
and 1,000,000 to 3,000,000 through `if` and named `let`.

### Procedure application

`(f arg...)`: if `f` evaluates to something that is not a procedure the
result is `error: type-error` (after the operands have been evaluated).
Calling a closure with the wrong number of arguments (too few, or too many
for a fixed-arity closure) is `error: arity-error`.

### Primitives

Arity is checked first (`arity-error`), then argument types
(`type-error`). For primitives that take several integers, *all* arguments
are type-checked before any comparison or arithmetic happens, so
`(< 2 1 "x")` is a `type-error`, not `#f`.

Integer arithmetic (all arguments must be integers):

| form | meaning |
|---|---|
| `(+ x ...)` | sum; `(+)` is `0` |
| `(* x ...)` | product; `(*)` is `1` |
| `(- x)` | negation |
| `(- x y z ...)` | `x - y - z - ...` (at least one argument) |
| `(quotient x y)` | integer division truncating toward zero: `(quotient -7 2)` is `-3`, `(quotient 7 -2)` is `-3` |
| `(remainder x y)` | `x - y*(quotient x y)`, so it has the sign of `x`: `(remainder -7 2)` is `-1`, `(remainder 7 -2)` is `1` |
| `(= x y ...)`, `(< x y ...)`, `(> x y ...)`, `(<= x y ...)`, `(>= x y ...)` | at least two arguments; `#t` iff the relation holds between every adjacent pair |

`quotient` and `remainder` with a zero divisor: `error: division-by-zero`.

Pairs and lists:

| form | meaning |
|---|---|
| `(cons a d)` | a new pair |
| `(car p)`, `(cdr p)` | fields of a pair; `type-error` if `p` is not a pair (including `()`) |
| `(list x ...)` | a fresh proper list of the arguments; `(list)` is `()` |
| `(null? x)` | `#t` iff `x` is `()` |
| `(pair? x)` | `#t` iff `x` is a pair |

Predicates and equivalence:

| form | meaning |
|---|---|
| `(not x)` | `#t` iff `x` is `#f` |
| `(number? x)`, `(boolean? x)`, `(string? x)`, `(symbol? x)`, `(procedure? x)` | type predicates |
| `(eq? a b)` | `#t` if both are integers and numerically equal; otherwise `#t` iff they are the same object: the same symbol (symbols with the same name are the same object), both `()`, the same boolean, both void, or the identical pair or procedure. Two distinct pairs are never `eq?`, even with equal contents. `eq?` on two strings is unspecified and never tested. |
| `(equal? a b)` | structural: pairs are `equal?` iff their cars and cdrs are; strings iff they have the same characters; everything else as `eq?`. |

Control:

| form | meaning |
|---|---|
| `(apply f a ... lst)` | calls `f` with arguments `a ...` followed by the elements of the proper list `lst`; `type-error` if `lst` is not a proper list. At least two arguments. The call is a tail call. |
| `(error x ...)` | any number of arguments; always `error: user-error`. The arguments are not printed. |

Strings and symbols (there is no string mutation; tests only use ASCII
characters inside strings, so bytes and characters coincide):

| form | meaning |
|---|---|
| `(string-append s ...)` | concatenation; `(string-append)` is `""` |
| `(string-length s)` | number of characters |
| `(number->string n)` | decimal representation, `-` prefix if negative |
| `(symbol->string s)` | the symbol's name |

Output:

| form | meaning |
|---|---|
| `(display x)` | writes `x` in *display* form (below), returns void |
| `(newline)` | writes a single LF, returns void |

### Runtime errors

When an error occurs, the output produced so far is kept, the text
`error: <category>` followed by LF is appended **directly** to the output
stream (no newline is inserted before it, even if the output does not end
with LF), and evaluation stops: no further forms are evaluated. The
categories are exactly:

| category | when |
|---|---|
| `unbound-variable` | evaluating a symbol with no binding, or `set!` of an unbound name |
| `type-error` | a primitive gets an argument of the wrong type; `apply`'s last argument is not a proper list; the operator of an application is not a procedure |
| `arity-error` | a closure or primitive is called with an unacceptable number of arguments |
| `division-by-zero` | `quotient` or `remainder` with divisor 0 |
| `user-error` | `(error ...)` was called |

Because the operator and operands are fully evaluated before arity and
type checks, `(car (display "x") (display "y"))` prints `xy` and then
`error: arity-error`.

## Output

For each top-level form whose value is not void, the value's *write* form
followed by LF. `display` output and `newline` are written at the moment
they execute, so they interleave with results in program order. Nothing
else is written. Everything is UTF-8; line terminator is LF.

### Write form

| value | printed as |
|---|---|
| integer | decimal digits, `-` prefix if negative, no `+`, no leading zeros (`0` for zero) |
| boolean | `#t` or `#f` |
| string | `"` + contents + `"`, where inside the contents `\` is written `\\`, `"` is written `\"`, LF is written `\n`, tab is written `\t`; every other character verbatim |
| symbol | its name, verbatim |
| empty list | `()` |
| pair | `(` then the elements separated by single spaces; if the chain ends in a non-`()` value `t`, ` . ` and `t` before the `)`. So `(1 2 3)`, `(1 . 2)`, `(1 2 . 3)`, `((1 2) (3 . 4) ())`. |
| procedure | `#<procedure>` (both primitives and closures) |
| void | `#<void>` (a top-level void result prints nothing at all; `#<void>` appears only when a void is nested inside a list or passed to `display`) |

`(quote x)` inside data is printed as an ordinary list: `''a` prints
`(quote a)`.

### Display form

Identical to the write form except that strings are written as their raw
contents with no quotes and no escaping, at any depth: `(display "a\"b")`
writes `a"b`, and `(display '("x" y))` writes `(x y)`.

## Examples

### Example 1

Input:
```
(define (fact n) (if (= n 0) 1 (* n (fact (- n 1)))))
(fact 20)
(display "done") (newline)
'(1 "two" (3 . 4) #t)
(cons 1 2)
```
Output:
```
2432902008176640000
done
(1 "two" (3 . 4) #t)
(1 . 2)
```

### Example 2

Input:
```
(define (make-counter)
  (let ((n 0))
    (lambda () (set! n (+ n 1)) n)))
(define c (make-counter))
(c) (c)
(let loop ((i 0) (acc 0))
  (if (= i 1000000) acc (loop (+ i 1) (+ acc i))))
(map (lambda (x) (* x x)) '(1 2 3))
```
Output:
```
1
2
499999500000
error: unbound-variable
```
(`map` is not a primitive; the program must define it itself.)

### Example 3

Input:
```
(display "a")
(display (list 1 "b" 'c))
(newline)
(if #f #f)
(list (if #f #f) car)
(quotient 1 0)
(display "never")
```
Output:
```
a(1 b c)
(#<void> #<procedure>)
error: division-by-zero
```

## Input sizes

Largest tests: tail loops of 3,000,000 iterations, three 1,000,000-iteration
loops through `apply`/`or`/`cond`, naive `fib 27` (~830,000 calls), eight
queens, a list-based sieve to 10,000, non-tail recursion 10,000 deep, and
factorials/powers with several hundred digits (`fact 2000` has 5,736
digits).
