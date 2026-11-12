# spreadsheet — spreadsheet engine with incremental recalculation

Implement an in-memory spreadsheet. Read a sequence of commands from stdin;
for every `get` and `dump` command write the requested cell values to stdout.
Cells hold numbers, strings or formulas. Formulas reference other cells and
must always reflect the current contents of the sheet, including after cells
are changed, cleared, or made part of a reference cycle.

## Input

Input is UTF-8 text: one command per line, lines terminated by `\n` (the last
line may lack the terminator). There are no blank lines and no leading or
trailing whitespace on a line other than inside string literals. Commands:

```
set <CELL> <content>
get <CELL>
clear <CELL>
dump
```

`<CELL>` is a cell name: one or two uppercase ASCII letters (the column,
`A`..`Z` then `AA`..`ZZ`, i.e. columns 1..702) followed by the row number
1..9999 written in decimal without leading zeros. Cell names in commands are
always valid. Exactly one space separates the command word, the cell name and
the content.

`<content>` is the rest of the line and takes one of three forms:

- A **formula**: the content starts with `=`. See *Formulas* below.
- A **string literal**: the content starts with `"`, ends with `"`, and the
  text between the quotes is the string. The text may be empty and may
  contain any characters except `"` and newline (there is no escape
  mechanism). Spaces inside the quotes are part of the string.
- Otherwise a **number literal**: `-?[0-9]+(\.[0-9]+)?` (e.g. `5`, `-3`,
  `4.50`, `007`), converted to the nearest IEEE-754 binary64 double
  (correctly rounded, ties to even, as `strtod` does). Number literals in the
  input always have at most 17 significant digits and lie within the range
  1e-300 .. 1e300 in magnitude (or are zero); the same limits apply to
  `NUMBER` tokens inside formulas. `-0` is the number zero and displays
  as `0`.

`set` replaces the cell's content. `clear` makes the cell empty (a cell that
was never set is also empty). `get` prints the cell's *displayed value* (see
*Display*) on one line; for an empty cell it prints an empty line. `dump`
prints every non-empty cell, one per line, as `<CELL> <displayed value>`,
in row-major order: ascending row number, and within a row ascending column
(`A`, `B`, ..., `Z`, `AA`, `AB`, ...). A cell is non-empty if it has content
(a string cell holding `""` is non-empty). If the sheet is empty, `dump`
prints nothing. `set` and `clear` print nothing.

## Values

Every non-empty cell has a **value** of one of these kinds:

- **number**: an IEEE-754 binary64 double, always finite.
- **string**: a sequence of characters.
- **error**: one of the four error codes `#DIV/0!`, `#REF!`, `#CYCLE!`,
  `#VALUE!`.

A number cell's value is its number, a string cell's value is its string, and
a formula cell's value is the result of evaluating the formula (which may be
an error). Empty cells have no value; formulas treat them as described under
*Empty cells*.

## Display

- A string is displayed as its characters, with no quotes.
- An error is displayed as its code (`#DIV/0!`, `#REF!`, `#CYCLE!`,
  `#VALUE!`).
- A number `v` is displayed by this rule:
  1. If `v` is zero (including negative zero): `0`.
  2. Else if `v` is integral (`v == floor(v)`) and `|v| < 1e15`: the integer
     in decimal, with a leading `-` if negative, no decimal point, no
     exponent, no leading zeros. E.g. `42`, `-7`, `123456789012345`.
  3. Otherwise the output is exactly what C's `printf("%.10g", v)` produces,
     which is defined as follows. Round `v` to 10 significant decimal digits
     (correct rounding of the exact binary value; exact ties round to even).
     Write the result as `d1.d2d3...d10 × 10^E` with `d1 ≠ 0` and let `E` be
     the decimal exponent *after* rounding (so 9999999999.7 rounds to
     1.000000000 × 10^10 and `E` is 10). Remove trailing zeros from the
     mantissa digits.
     - If `E < -4` or `E >= 10`: **scientific** notation: the mantissa digits
       with a `.` after the first digit (omit the `.` when only one digit
       remains), then `e`, then the sign of `E` (`+` or `-`, always present),
       then `|E|` in decimal padded to at least two digits. Examples:
       `1e+20`, `-1.5e+15`, `1.23456789e+15`, `1e-05`, `2.5e-10`.
     - Otherwise: **fixed** notation: the digits placed around the decimal
       point per `E`, with trailing zeros removed and no trailing `.`.
       Examples: `0.5`, `1234567.891`, `0.3333333333`, `0.0001234`,
       `-2.5`, `1234567890` (from 1234567890.4), `1e+10` (from 9999999999.7,
       since `E` becomes 10).

  A number's *text form* (used by the `&` operator) is the same string.

Rule 2 takes precedence over rule 3: `1e14` displays as `100000000000000`
and `1e15` displays as `1e+15`. Non-integral values with more than 10
significant digits are rounded: `1/3` → `0.3333333333`, `2/3` →
`0.6666666667`, `1234567890.5` → `1234567890` (a tie, rounded to even),
`2500000000.75` → `2500000001`, `1200000000.4` → `1200000000`.

An exact tie can only occur when the exact binary value of `v` has exactly
11 significant decimal digits ending in 5 (such as `1234567890.5`); a value
like `0.1` is not a tie because its exact value is
0.1000000000000000055511151231257827... Do not assume your platform's
formatter matches C: JavaScript's `toPrecision(10)` and Java's
`String.format("%.10g")`, for instance, round ties away from zero and use
different exponent thresholds. Check your formatter against every example
in this section (all of them appear in the tests).

## Formulas

A formula is `=` followed by an expression. Space characters (0x20) may
appear between tokens and are ignored; they never appear inside a token
other than a string literal. Every formula in the input is syntactically
valid under this grammar (an implementation need not handle syntax errors):

```
expr     := cmp
cmp      := cat ( ("=" | "<>" | "<" | ">" | "<=" | ">=") cat )*
cat      := add ( "&" add )*
add      := mul ( ("+" | "-") mul )*
mul      := unary ( ("*" | "/") unary )*
unary    := "-" unary | primary
primary  := NUMBER | STRING | REF | call | "(" expr ")"
call     := AGG "(" arg ( "," arg )* ")"
          | "IF" "(" expr "," expr "," expr ")"
arg      := expr | REF ":" REF
AGG      := "SUM" | "MIN" | "MAX" | "AVG" | "COUNT"
NUMBER   := [0-9]+ ( "." [0-9]+ )?
STRING   := '"' <any chars except '"' and newline> '"'
REF      := [A-Z]+ [0-9]+
```

All binary operators are left-associative. Precedence from lowest to
highest: comparisons (`= <> < > <= >=`), concatenation `&`, additive `+ -`,
multiplicative `* /`, unary minus. So `=1+2*3` is 7, `=-2*3-4` is -10,
`=1<2+3` is 1, `=1+2&3` is the string `33`, and `=--5` is 5.

Function names are uppercase. `IF` takes exactly three arguments;
`SUM`/`MIN`/`MAX`/`AVG`/`COUNT` take one or more arguments, each of which is
either an expression or a **range** `REF:REF` (written without spaces). A
range denotes the rectangle spanned by its two corner cells in either order
(`B2:A1` is the same as `A1:B2`). Ranges appear only as direct arguments of
the five aggregate functions.

### References

A `REF` token is one or more uppercase letters followed by one or more
digits. It is a **valid** reference only if it has at most two letters and
the digits form a row number 1..9999 with no leading zero (`A1`, `ZZ9999`,
`AB123`). Any other `REF` token (`AAA1`, `A0`, `A10000`, `A01`) is invalid.
A formula containing an invalid reference anywhere (including as a range
corner or inside an unselected `IF` branch) has the value `#REF!`, and it
depends on no cells.

### Dependencies and cycles

The dependencies of a formula cell are all cells named by its valid
references plus every cell covered by its ranges (including empty cells).
Dependencies are static: both branches of an `IF` count, and so do all cells
of a range whether or not they hold numbers.

A cell is **cyclic** if there is a path of dependencies from the cell back to
itself (a self-reference such as `set A1 =A1+1` counts; so does a cell whose
range includes itself). Every cyclic cell has the value `#CYCLE!`, regardless
of what its formula would otherwise compute. Cells that are not themselves
cyclic but read a cyclic cell get `#CYCLE!` by ordinary error propagation
(so `IF` can mask it by not selecting the branch). When an edit removes the
cycle, the cells that were cyclic are evaluated normally again.

The sheet is always consistent: after each command, every formula cell's
value equals what evaluating its formula against the current sheet gives.

### Evaluation

Evaluation proceeds left to right, depth first. Whenever a step below says
"the result is X", evaluation of the enclosing expression stops with that
result, so the **first problem encountered in evaluation order wins**.

Values during evaluation are numbers, strings, errors, or *empty* (the
result of referencing an empty cell). If the value of the whole formula is
empty, the cell's value is the number `0`.

- `NUMBER`, `STRING`: the literal. `REF`: the value of that cell (empty if
  the cell is empty; the referenced cell's error if it holds one).
- Unary `-x`: evaluate `x`; an error is the result; a string gives
  `#VALUE!`; empty counts as 0; otherwise negate.
- `a + b`, `a - b`, `a * b`, `a / b`: evaluate `a`; if it is an error, that
  is the result; if it is a string, `#VALUE!`; empty counts as 0. Then do the
  same for `b`. For `/`, if `b` is zero (either sign) the result is
  `#DIV/0!`. Compute the IEEE double operation; if the result is not finite
  (infinity or NaN) the result is `#VALUE!`. Underflow to zero or to a
  subnormal is not an error.
- `a & b`: evaluate `a`; an error is the result; then `b` likewise. The
  result is the string formed by concatenating the text forms: a string is
  itself, empty is the empty string, a number is its display string.
- Comparisons `a = b`, `a <> b`, `a < b`, `a > b`, `a <= b`, `a >= b`:
  evaluate `a`; an error is the result; then `b` likewise. If both are empty
  they become the number 0 and 0. If exactly one is empty it becomes 0 when
  the other is a number and `""` when the other is a string. If one operand
  is now a number and the other a string: `=` gives 0, `<>` gives 1, and the
  four ordering operators give `#VALUE!`. Two numbers compare numerically;
  two strings compare lexicographically by Unicode code point (equivalently
  by UTF-8 bytes), case-sensitively, a proper prefix sorting first. The
  result is the number 1 (true) or 0 (false). Note that comparing UTF-16
  code units (the native string order of JavaScript, Java and C#) is *not*
  code-point order: `"😀"` (U+1F600) sorts after `"ｚ"` (U+FF5A) by code
  point but before it by UTF-16 code units.
- `IF(c, a, b)`: evaluate `c`; an error is the result; a string gives
  `#VALUE!`; empty counts as 0. If `c` is nonzero the result is the value of
  `a`, otherwise the value of `b`. **Only the selected branch is evaluated**,
  so an error in the other branch has no effect. The selected branch may
  yield a string, a number, an error, or empty.
- `SUM`, `MIN`, `MAX`, `AVG`, `COUNT`: process the arguments left to right,
  collecting a list of numbers:
  - A range argument: visit its cells in row-major order. A cell holding an
    error makes that error the result. A cell holding a number is collected.
    Empty cells and string cells are skipped.
  - An expression argument: evaluate it. An error is the result; a string
    gives `#VALUE!`; empty is skipped; a number is collected.

  Then, with the collected numbers in order: `COUNT` is how many there are;
  `SUM` adds them left to right starting from 0 (`0` if none); `MIN`/`MAX`
  is the smallest/largest (`0` if none); `AVG` is the `SUM` divided by the
  `COUNT` (`#DIV/0!` if none). If `SUM` or `AVG` is not finite the result is
  `#VALUE!`.

There is no implicit conversion of strings to numbers: `="5"+1` is `#VALUE!`.
Comparison of a number to a string never converts either side.

Parentheses do not change a value, and `IF` returns the selected branch's
value unchanged, so *empty* passes through both: with `Z1` empty,
`=(Z1)&"x"` and `=IF(1,Z1,7)&"x"` are the string `x`, `=(Z1)=""` is 1, and
`=COUNT((Z1))` is 0. Unary minus and arithmetic coerce empty to a number:
`=-Z1&"x"` is `0x`.

### Empty cells

Summary of how empty cells behave: in arithmetic and as an `IF` condition
they count as 0; in `&` as `""`; in comparisons per the other operand; in
aggregates they are skipped; a formula whose whole result is empty yields 0.

## Output

For each `get`, one line: the displayed value of the cell (an empty line for
an empty cell). For each `dump`, one line per non-empty cell in row-major
order, `<CELL> <displayed value>`. Lines are terminated by `\n`. Nothing
else is printed. If there are no `get` or `dump` commands, print nothing.
Trailing whitespace on an output line is not significant (the checker
strips it), so a cell holding the empty string may be dumped as either
`A2 ` or `A2`.

## Worked examples

### Example 1 — dependencies, a cycle created and broken

Input:
```
set A1 10
set A2 32
set A3 =A1+A2
get A3
set A1 =A3
get A1
get A3
set A1 5
get A3
dump
```
Output:
```
42
#CYCLE!
#CYCLE!
37
A1 5
A2 32
A3 37
```

### Example 2 — strings, ranges, IF, errors propagating

Input:
```
set A1 "Total"
set B1 3
set B2 4.5
set B3 "x"
set C1 =SUM(B1:B3)
set C2 =A1&": "&C1
set C3 =IF(C1>7, "big", "small")
set C4 =AVG(B1:B3)
set C5 =COUNT(B1:B3)
set C6 =B1/(B2-4.5)
set C7 =C6+1
set C8 =1/3
dump
```
Output (note the row-major order: A1, B1, C1 come before B2):
```
A1 Total
B1 3
C1 7.5
B2 4.5
C2 Total: 7.5
B3 x
C3 big
C4 3.75
C5 2
C6 #DIV/0!
C7 #DIV/0!
C8 0.3333333333
```

### Example 3 — precedence, number formatting, clearing

Input:
```
set A1 =1+2*3
set A2 =(1+2)*3
set A3 =-2*3-4
set A4 =2*-3
set A5 =1<2+3
set A6 =1+2&3
set A7 =100000000000000000000
set A8 =0.00001
set A9 =1234567.891
set A10 =2/3*3
set B1 =A9
clear A9
get B1
dump
```
Output:
```
0
A1 7
B1 0
A2 9
A3 -10
A4 -6
A5 1
A6 33
A7 1e+20
A8 1e-05
A10 2
```

## Input sizes

The largest tests have up to about 70,000 commands (about 1.3 MB of input):
dependency chains of 10,000 cells re-evaluated after each of 100 edits at
the head, aggregate ranges of 9,999 cells re-summed after each of 100 edits,
a sheet of 50,000 cells followed by 5,000 point edits each followed by
`get`, and a random workbook of 8,000 commands over 360 heavily
interconnected cells. Formulas are at most a few thousand
characters long, nest at most about 100 levels deep, and no range spans more
than 10,000 cells. Dependency chains are up to 10,000 cells deep, so an
evaluator that recurses from cell to cell needs a correspondingly deep call
stack (or an explicit stack).
