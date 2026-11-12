# minisql — mini relational database (SQL subset)

Implement an in-memory relational database that executes a small SQL
dialect. Read a script of SQL statements from stdin, execute them in order,
and print the result of every `SELECT` to stdout. The dialect is a strict
subset of SQLite's, and where this document is silent on a detail that SQLite
defines, SQLite's behaviour is the intended one — but everything a test
exercises is specified below, so you never need SQLite to implement this.

Write the database engine yourself: don't use SQLite or any other SQL engine or
database from a library, the standard library or the language.

## Input

Input is UTF-8 text (no byte-order mark) containing zero or more
statements. Each statement is terminated by a `;` token; a final statement
whose `;` is missing at end of input is still executed. Statements may span
lines, and several statements may share a line. Empty statements (`;;`, or
a `;` after only whitespace and comments) are ignored. Empty input, or input
consisting only of whitespace, comments and empty statements, produces no
output at all.

### Lexical structure

Statements are tokenized before parsing. Tokens are separated by any amount
of whitespace (space, tab, CR, LF, FF, VT) and comments. A comment starts
with `--` outside a string literal and runs to the end of the line (or end
of input); it is treated as whitespace. Note that `--` always starts a
comment, so `--5` is not "minus minus five".

Tokens:

- **Keyword / identifier**: `[A-Za-z_][A-Za-z0-9_]*`. Matching is
  case-insensitive for both keywords and identifiers (`SELECT`, `select`,
  `Select` are the same keyword; `Emp`, `EMP`, `emp` are the same table).
  The reserved keywords are:
  `SELECT FROM WHERE AND OR NOT NULL IS LIKE AS INSERT INTO VALUES DELETE
  UPDATE SET CREATE TABLE INTEGER TEXT INNER JOIN ON GROUP BY HAVING ORDER
  ASC DESC LIMIT OFFSET LEFT RIGHT FULL OUTER CROSS NATURAL`.
  A reserved keyword can never be used as a table, column or alias name
  (so `CREATE TABLE t (text TEXT)` and `SELECT a AS left FROM t` are syntax
  errors; the last six words are reserved only so that `t LEFT JOIN u`
  cannot parse as "table `t` aliased `left`"). The aggregate function names
  `COUNT SUM MIN MAX AVG` are *not* reserved: such a name followed by a `(`
  token (whitespace or comments may lie between them: `count (*)` is a
  call) is a function call, and anywhere else it is an ordinary identifier
  (a column may be named `count`).
- **Integer literal**: `[0-9]+`, a non-negative decimal integer (leading
  zeros allowed: `007` is 7). Negative numbers are written with the unary
  minus operator. There are no floating-point literals.
- **String literal**: `'...'`; a single quote inside the string is written
  as two quotes (`'it''s'` is `it's`). Strings may contain any character
  except that they cannot contain a lone `'`; there are no backslash
  escapes (`'\n'` is a backslash followed by `n`). A string may span lines.
  If a string literal is never closed, the statement containing it (from
  the previous `;` to the end of input) is one erroneous statement, and
  nothing after it is executed.
- **Operators / punctuation**: `+ - * / % = == != <> < <= > >= ( ) , . ;`.
  The longest match wins (`<=` is one token; `<>` and `!=` are both
  "not equal"; `==` is the same as `=`).

Any other character (for example `"`, `@`, `$`, `\`, or a non-ASCII
character outside a string literal) is an invalid token, and the statement
containing it is a syntax error. `.` is a token in its own right that is
only meaningful between two identifiers (`t.col`, also `t . col`), so
`1.5` tokenizes as `1`, `.`, `5` and is a syntax error.
Splitting into statements happens on `;` tokens only: a `;` inside a string
literal or a comment does not end a statement.

## Data model

A database holds named tables created by `CREATE TABLE`. A table has an
ordered list of named columns and an ordered list of rows. Values are
dynamically typed; every value is one of:

- **NULL**;
- **INTEGER**: a signed 64-bit integer;
- **TEXT**: a string of Unicode characters;
- **REAL**: produced only by `AVG` (see *Aggregates*); never stored in a
  table.

Column types (`INTEGER` or `TEXT`) in `CREATE TABLE` are declarative only:
the engine does not convert or reject values based on them (test inputs
always store a value of the declared type, or NULL). Comparisons, sorting
and grouping use the value's own type as described under *Comparison*.

**Row order.** Every table keeps its rows in insertion order. `INSERT`
appends rows in the order given; `UPDATE` changes values in place without
moving a row; `DELETE` removes rows and keeps the relative order of the
rest. This order is observable: it is the order a `SELECT` returns rows in
when no `ORDER BY` decides otherwise (see *Result order*).

## Statements

Grammar notation: `[x]` optional, `{x}` zero or more, `|` alternatives.
Keywords are shown in upper case. `name` is an identifier.

### CREATE TABLE

```
CREATE TABLE name ( name type {, name type} )
type := INTEGER | TEXT
```

Creates an empty table. Errors: a table with that name already exists;
two columns (case-insensitively) share a name; a type other than `INTEGER`
or `TEXT`; an empty column list. Prints nothing.

### INSERT

```
INSERT INTO name VALUES ( expr {, expr} ) {, ( expr {, expr} )}
```

Appends one row per parenthesised list, in the order written. Each
expression is evaluated with no row in scope (a column reference is an
error), and must not contain an aggregate function. Every list must have
exactly as many expressions as the table has columns; otherwise the whole
statement is an error and nothing is inserted. Prints nothing.

### DELETE

```
DELETE FROM name [WHERE expr]
```

Removes every row for which the WHERE expression is *true* (see *Boolean
context*); without WHERE removes all rows. Prints nothing.

### UPDATE

```
UPDATE name SET name = expr {, name = expr} [WHERE expr]
```

For every row for which the WHERE expression is true (all rows if there is
no WHERE), assigns each listed column. All right-hand expressions of a row
are evaluated against the row's *old* values before any assignment, so
`SET a = b, b = a` swaps. Errors: unknown table or column; an aggregate
function in any expression. Prints nothing. In UPDATE and DELETE a column
reference may be written bare (`bal`) or qualified by the table name
(`acct.bal`); the assigned column name on the left of `=` is always bare.

### SELECT

```
SELECT item {, item}
  [FROM table_ref [ , table_ref | [INNER] JOIN table_ref ON expr ]]
  [WHERE expr]
  [GROUP BY column_ref {, column_ref}]
  [HAVING expr]
  [ORDER BY order_term {, order_term}]
  [LIMIT integer [OFFSET integer]]

item       := * | expr [[AS] name]
table_ref  := name [[AS] name]
column_ref := name | name . name
order_term := expr [ASC | DESC]
```

`FROM` names one or two tables; a table may be given an alias, with or
without `AS` (`emp e`, `emp AS e`). A comma join and an `INNER JOIN ... ON`
are equivalent: the `ON` expression is simply another filter, ANDed with
the WHERE expression. The two table references must have different
effective names (the alias if given, else the table name); the same table
may appear twice under two aliases (self join). When a table has an alias,
only the alias can be used to qualify its columns.

Column references: `name` is looked up in every table of the FROM clause;
it is an error if no table has such a column or if more than one does
(ambiguous). `qual.name` looks in the table whose effective name is `qual`
(error if there is no such table or column). Errors are reported even if
the table has no rows.

`*` as an item expands to every column of the first table in FROM order,
then every column of the second; `*` may appear more than once and may be
mixed with other items. An item may be given an alias (`expr AS name` or
`expr name`); aliases have no effect on output and are only used by ORDER
BY (below). `*` cannot be aliased.

`GROUP BY` terms must be plain column references (an expression such as
`a + 1` is a syntax error). `HAVING` requires `GROUP BY`. `LIMIT` and
`OFFSET` take non-negative integer literals; `OFFSET` requires `LIMIT`.

A SELECT without FROM evaluates its items against a single row with no
columns (so `SELECT 1 + 1;` prints one row); WHERE, ORDER BY and LIMIT are
allowed there and behave as usual, but any column reference or `*` is an
error.

## Expressions

Grammar, from lowest to highest precedence (all binary operators are
left-associative):

```
expr    := and_e { OR and_e }
and_e   := not_e { AND not_e }
not_e   := NOT not_e | eq_e
eq_e    := rel_e { ( = | == | != | <> ) rel_e
                 | IS NULL | IS NOT NULL
                 | [NOT] LIKE rel_e }
rel_e   := add_e { ( < | <= | > | >= ) add_e }
add_e   := mul_e { ( + | - ) mul_e }
mul_e   := unary { ( * | / | % ) unary }
unary   := - unary | primary
primary := integer | string | NULL | ( expr ) | column_ref
         | COUNT ( * ) | COUNT ( expr ) | SUM ( expr ) | MIN ( expr )
         | MAX ( expr ) | AVG ( expr )
```

So `NOT a = 1` is `NOT (a = 1)`, `a + 1 IS NULL` is `(a + 1) IS NULL`,
`1 < 2 = 1` is `(1 < 2) = 1` (the four ordering operators bind tighter than
the equality-level operators), and `-5 % 3` is `(-5) % 3`. Only these five
functions exist; any other `name(` is a syntax error. Column reference and
NULL rules are given above; a reserved keyword where an operand is expected
is a syntax error.

### Arithmetic

`+ - * /` and `%` on two INTEGERs give an INTEGER. `/` is integer division
truncating toward zero; `%` is the remainder with the sign of the dividend
(C semantics): `-7 / 2 = -3`, `-7 % 3 = -1`, `7 % -3 = 1`. Division or
remainder by zero yields NULL (not an error). Any arithmetic operand that
is NULL makes the result NULL. Unary minus negates an INTEGER and maps
NULL to NULL. Test inputs keep every intermediate result within the signed
64-bit range.

### Comparison

`=`/`==`, `!=`/`<>`, `<`, `<=`, `>`, `>=` yield INTEGER 1 (true) or 0
(false), or NULL if either operand is NULL. Non-NULL values are compared by
a total order:

1. Values of different kinds: any number (INTEGER or REAL) is less than any
   TEXT, and numbers are never equal to text (`1 = '1'` is 0, `1 < 'a'` is
   1, `100 < '0'` is 1).
2. Numbers compare numerically (an INTEGER and a REAL compare by value:
   `2 = AVG(...)` is 1 when the average is exactly 2.00).
3. TEXT compares by Unicode code point, character by character
   (equivalently, bytewise as UTF-8); a proper prefix sorts first
   (`'' < 'a' < 'ab' < 'b'`, `'B' < 'a'`, `'Z' < 'z'`). Comparison is
   case-sensitive.

The same order (with NULL smallest of all) is used by ORDER BY, GROUP BY,
MIN and MAX.

### IS NULL, IS NOT NULL

`x IS NULL` is 1 if `x` is NULL, else 0; `IS NOT NULL` is the opposite.
Never NULL.

### LIKE

`s LIKE p` matches the text `s` against pattern `p`, yielding 1 or 0, or
NULL if either side is NULL. In the pattern `%` matches any sequence of
zero or more characters and `_` matches exactly one character; every other
character matches itself. There is no escape character. Matching is
**case-insensitive for the 26 ASCII letters only** (`'APPLE' LIKE 'apple'`
is 1, `'É' LIKE 'é'` is 0), and the whole string must match. An INTEGER on
either side is first converted to its decimal text (`12345 LIKE '12%'` is
1). `s NOT LIKE p` is `NOT (s LIKE p)`.

### Boolean logic

`AND`, `OR` and `NOT` use three-valued logic. Operands are interpreted as:
NULL = unknown, INTEGER 0 = false, any other INTEGER = true (REAL: 0.00 is
false, anything else true). Results are INTEGER 1, 0 or NULL:

| a     | b     | a AND b | a OR b |
|-------|-------|---------|--------|
| true  | true  | 1       | 1      |
| true  | false | 0       | 1      |
| false | false | 0       | 0      |
| true  | NULL  | NULL    | 1      |
| false | NULL  | 0       | NULL   |
| NULL  | NULL  | NULL    | NULL   |

`NOT true` is 0, `NOT false` is 1, `NOT NULL` is NULL.

### Boolean context

WHERE, HAVING and ON expressions select a row (or group) only when the
value is *true* under the interpretation above; NULL and 0 reject it.
`WHERE a` therefore keeps rows whose `a` is a non-zero integer.

## SELECT evaluation

1. **FROM.** With one table, the candidate rows are the table's rows in
   table order. With two tables, they are all pairs of rows in
   nested-loop order: for each row of the first table in table order, for
   each row of the second table in table order. A pair's columns are the
   first table's columns followed by the second's.
2. **WHERE / ON.** Keep the candidates whose ON (if any) and WHERE (if any)
   expressions are both true. Aggregate functions are not allowed here.
3. **Aggregation.** The query is an *aggregate query* if it has GROUP BY or
   if any aggregate function appears in the select list, HAVING or ORDER
   BY. Otherwise every remaining candidate row produces one output row and
   step 4 is skipped.
   - With GROUP BY, rows are partitioned into groups with equal values in
     all grouping columns; NULL groups with NULL, and 1 and `'1'` are
     different groups. Groups are ordered ascending by their grouping
     values (first column, then second, ...) using the comparison order,
     NULL first. There are no groups if there are no rows.
   - Without GROUP BY, all rows form a single group, even if there are
     none (so `SELECT COUNT(*) FROM empty` prints one row with `0`).
   - Outside an aggregate call, the select list, HAVING and ORDER BY may
     only reference grouping columns (a bare non-grouped column is an
     error, as is a column anywhere in a no-GROUP-BY aggregate query).
     Aggregates cannot nest.
4. **HAVING.** Keep the groups whose HAVING expression is true. Aggregates
   in HAVING are computed over the group.
5. **Select list.** Evaluate each item for each row/group, producing the
   output row.
6. **ORDER BY.** Sort the output rows by the ORDER BY terms, first term
   most significant. Each term is either:
   - a bare identifier that (case-insensitively) equals an item alias:
     the term refers to that item's value (the first such item if several
     share the alias). Aliases are recognised only as a whole term, never
     inside a larger expression, and only in ORDER BY;
   - a bare integer literal `k`: the k-th output column (1-based, counting
     the columns a `*` expands to, so in `SELECT *, x FROM a` with columns
     `x, y` the ordinal 3 is the item `x`; out of range, including 0, is an
     error). Only a bare literal is an ordinal: `1 + 0`, `-1` or `'a'` are
     ordinary (constant) expressions, under which every row compares
     equal;
   - otherwise an expression, evaluated against the row/group (subject to
     the aggregate-query restrictions).
   Comparison uses the order defined above; NULL sorts first under ASC
   and last under DESC. The sort is **stable**: rows whose keys are all
   equal keep their step-3 order (table/nested-loop order, or ascending
   group order).
7. **LIMIT / OFFSET.** Skip the first OFFSET rows, then keep at most LIMIT
   rows. Without LIMIT all rows are kept.

### Result order

Without ORDER BY the output order is exactly the step-3 order: table order
for a single table, nested-loop order for a join, ascending grouping-value
order for GROUP BY.

## Aggregates

Each aggregate is evaluated over the rows of one group. `COUNT(*)` is the
number of rows. For the others the argument is evaluated per row and NULL
results are ignored:

- `COUNT(e)`: number of non-NULL values (0 if none).
- `SUM(e)`: INTEGER sum of the non-NULL values; NULL if there are none.
- `MIN(e)` / `MAX(e)`: smallest / largest non-NULL value under the
  comparison order (works for TEXT too); NULL if there are none.
- `AVG(e)`: NULL if there are no non-NULL values. Otherwise, with `s` the
  sum and `c` the count of the non-NULL INTEGER values, the result is the
  REAL value `s / c` rounded to exactly two decimal places, half away from
  zero. In integer arithmetic the number of hundredths is
  `h = (200 * |s| + c) div (2 * c)`, negated if `s < 0`; e.g. 1,2 → 1.50;
  1,1,2 → 1.33; 1..8 → 4.50; 1,2,...,7,8 with sum 36 and c 8 → 4.50;
  −1,−2 → −1.50; 1×7 and 2 (s=9, c=8, 1.125) → 1.13; s=−9,c=8 → −1.13.
  Test data keeps `200 * |s|` within 64 bits. The REAL result may be
  printed, compared with `= != < <= > >=` against INTEGERs or other REALs
  (numerically), tested with IS NULL, used in boolean context, and used
  as an ORDER BY key; arithmetic on it is never exercised.

`SUM` and `AVG` arguments are always INTEGER or NULL in the tests.

## Output

For every executed `SELECT`, print one line per output row, in result
order, then one line `-- N rows` where N is the number of rows printed
(always the word `rows`, also for 0 and 1). Within a row, values are
separated by a single tab. NULL prints as `NULL`; an INTEGER prints in
decimal with a leading `-` if negative and no leading zeros (`-0` prints as
`0`); TEXT prints as its characters with no quotes; a REAL prints with
exactly two decimals and a leading `-` only when the rounded value is
negative (`4.50`, `-1.13`, `0.00`; an average of −1 over 201 rows rounds to
zero and prints `0.00`, never `-0.00`). Lines end with `\n`. `CREATE`, `INSERT`, `UPDATE` and `DELETE`
print nothing. Test data never contains a tab or newline inside a TEXT
value. Exit with status 0 after processing all input.

## Errors

A statement that fails prints exactly one line `error` (instead of any
result) and **has no effect on the database**; execution then continues
with the next statement. Errors are detected before a statement changes
anything, so an `INSERT` of several rows where one row has the wrong
arity inserts nothing. Error conditions include:

- syntax errors (anything not matching the grammar, including an invalid
  token, an unterminated string, missing `;`-separated pieces, unsupported
  SQL such as `DROP`, `LEFT JOIN`, three tables in FROM, `IN`, `BETWEEN`,
  `DISTINCT`, `||`, subqueries, `INSERT INTO t (cols)`, a column list with
  no type, `REAL`, or a negative `LIMIT`/`OFFSET` argument);
- unknown table; unknown or ambiguous column; using a table name for
  qualification when the table has an alias; two FROM entries with the
  same effective name;
- creating a table that exists, or with duplicate column names;
- INSERT value list with the wrong number of values, or containing a
  column reference;
- aggregate functions in WHERE, ON, INSERT, UPDATE or DELETE; nested
  aggregates; a non-grouped column outside an aggregate in an aggregate
  query; HAVING without GROUP BY; a GROUP BY term that is not a column;
- an ORDER BY ordinal out of range; OFFSET without LIMIT.

## Not exercised

The following never occur in the test inputs, and implementations may do
anything for them: arithmetic or unary minus on TEXT or REAL; integer
overflow, or an integer literal outside the signed 64-bit range; TEXT in
boolean context; `SUM`/`AVG`/`LIKE` applied to REAL; comparing a column of
one declared type with a literal of the other type (`WHERE textcol = 5`);
assigning the same column twice in one `UPDATE`; tabs or newlines inside
TEXT values; non-ASCII characters outside string literals; ORDER BY terms
that reference an alias inside a larger expression; aliases used in WHERE,
GROUP BY or HAVING; an aggregate function that appears only in ORDER BY of
a query without GROUP BY (`SELECT 1 FROM t ORDER BY COUNT(*)`); a negative
integer as a whole ORDER BY term (`ORDER BY -1`).

## Examples

### Example 1

Input:

```
CREATE TABLE emp (id INTEGER, name TEXT, dept TEXT, salary INTEGER);
INSERT INTO emp VALUES (1, 'ann', 'eng', 120), (2, 'bob', 'ops', 90), (3, 'cy', 'eng', NULL), (4, 'dee', NULL, 100);
SELECT name, salary FROM emp WHERE salary >= 100 ORDER BY salary DESC;
SELECT dept, COUNT(*), SUM(salary), AVG(salary) FROM emp GROUP BY dept;
SELECT * FROM nosuch;
UPDATE emp SET salary = salary + 5 WHERE dept = 'eng';
SELECT id, salary FROM emp;
```

Output:

```
ann	120
dee	100
-- 2 rows
NULL	1	100	100.00
eng	2	120	120.00
ops	1	90	90.00
-- 3 rows
error
1	125
2	90
3	NULL
4	100
-- 4 rows
```

(The NULL department group sorts first; `cy`'s NULL salary is ignored by
SUM and AVG but counted by `COUNT(*)`; `NULL + 5` stays NULL.)

### Example 2

Input:

```
CREATE TABLE a (x INTEGER, s TEXT);
CREATE TABLE b (y INTEGER, t TEXT);
INSERT INTO a VALUES (3, 'c'), (1, 'a'), (2, 'b'), (1, 'aa');
INSERT INTO b VALUES (1, 'p'), (2, 'q'), (1, 'r'), (3, 's');
SELECT s, t FROM a, b WHERE x = y AND t != 'p';
SELECT p.s, q.s FROM a p INNER JOIN a q ON p.x = q.x AND p.s < q.s;
SELECT x, COUNT(*) AS n FROM a, b WHERE x = y GROUP BY x ORDER BY n DESC, x LIMIT 2;
SELECT 7 / 2, -7 / 2, 7 % -3, 1 / 0, 'B' < 'a', 1 < 'a', NULL = NULL, 'Ab_c' LIKE 'ab%';
```

Output:

```
c	s
a	r
b	q
aa	r
-- 4 rows
a	aa
-- 1 rows
1	4
2	1
-- 2 rows
3	-3	1	NULL	1	1	NULL	1
-- 1 rows
```

(The join is enumerated with `a` as the outer loop: `(3,'c')` first, then
`(1,'a')` paired with both `y = 1` rows in `b`'s order, and so on.)

### Example 3

Input:

```
CREATE TABLE t (k INTEGER, v INTEGER);
INSERT INTO t VALUES (2, 10), (NULL, 20), (1, 30), (2, 40), (1, NULL);
SELECT k, v FROM t ORDER BY k;
SELECT k, v FROM t ORDER BY k DESC, v DESC;
SELECT k FROM t GROUP BY k HAVING COUNT(v) = 2;
SELECT k, v FROM t WHERE k = 1 OR v = 20 LIMIT 1 OFFSET 1;
DELETE FROM t WHERE v IS NULL OR k IS NULL;
SELECT COUNT(*), MIN(v), MAX(k), AVG(v) FROM t;
SELECT 1 FROM t WHERE 0;
```

Output:

```
NULL	20
1	30
1	NULL
2	10
2	40
-- 5 rows
2	40
2	10
1	30
1	NULL
NULL	20
-- 5 rows
2
-- 1 rows
1	30
-- 1 rows
3	10	2	26.67
-- 1 rows
-- 0 rows
```

(`ORDER BY k` is stable: the two `k = 1` rows keep table order. The
average of 10, 30, 40 is 26.666..., printed as `26.67`.)

## Input sizes

The largest tests create a 2 000-row table and a 20 000-row table
(inserted with `INSERT ... VALUES` statements of 500 rows each, about
650 KB of input), then run filters, `ORDER BY` over all 20 000 rows,
`GROUP BY` with up to 2 000 groups, `UPDATE`/`DELETE` over the big table,
and joins between the two tables (and self joins of each) on equality
conditions. A join must emit the surviving pairs in nested-loop order
(outer table order, then inner table order within each outer row),
because that order is observable whenever no ORDER BY decides otherwise.
Expected outputs are exact; the largest output is about 20 000 lines.
