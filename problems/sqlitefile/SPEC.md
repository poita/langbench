# sqlitefile — SQLite database file reader

Read a real SQLite 3 database file directly, byte by byte, and answer a small
set of queries against it.

Parse the file yourself: don't use a SQLite library or binding, or any other
code that already understands the format, from a library, the standard library
or the language.

This is a file-format and query-engine problem. The work splits roughly into
a pager and B-tree walker, a record decoder, a `CREATE TABLE` / `CREATE INDEX`
parser, and a tiny query evaluator. Expect around 1500–2500 lines in a systems
language, or 800–1200 in a high-level one.

## Invocation

This is a *directory-mode* problem:

```
<your program> <input directory> <output directory>
```

Nothing is read from stdin and nothing may be written outside the output
directory. Exit status 0 always, even when individual queries fail; a failing
query produces the word `error` in its result file (see **Errors**). The
output directory already exists and is empty.

### Input directory

It contains exactly two entries:

* exactly one file whose name ends in `.sqlite` — the database;
* `queries.txt` — UTF-8 text, LF line endings, one query per line, no blank
  lines, no leading or trailing spaces on a line. The final line may or may
  not end with `\n`. There are at least 1 and at most 999 queries. Apart from
  those LF line terminators the file holds no control characters, so a tab is
  the only blank a query can contain besides the space.

### Output directory

For the *n*-th query line (1-based) write the file `NNN.txt`, where `NNN` is
*n* zero-padded to three digits: `001.txt`, `002.txt`, … Write no other files
and create no subdirectories.

Each result file is UTF-8 with LF line endings; every output line, including
the last, is terminated by `\n`. A query with no result rows produces an empty
(zero-byte) file. The test runner ignores trailing whitespace at the end of a
line and trailing newlines at the end of a file.

---

## Part 1 — the SQLite file format

Everything below is the on-disk format you must decode. All multi-byte
integers in page headers and cell pointers are **big-endian and unsigned**
unless stated otherwise.

### 1.1 Database header

The first 100 bytes of the file. The fields this problem needs:

| offset | size | meaning |
|--------|------|---------|
| 0  | 16 | the string `SQLite format 3\0` |
| 16 | 2  | page size in bytes; the value `1` means 65536 |
| 20 | 1  | bytes of unused *reserved* space at the end of every page |
| 28 | 4  | database size in pages |
| 32 | 4  | page number of the first freelist trunk page, or 0 |
| 36 | 4  | total number of freelist pages |
| 52 | 4  | largest root B-tree page; non-zero only when auto-vacuum is on |
| 56 | 4  | text encoding: 1 = UTF-8, 2 = UTF-16le, 3 = UTF-16be |

Define the **usable size** `U = page_size - reserved`. Pages are numbered from
1; page *n* occupies bytes `(n-1) * page_size .. n * page_size - 1`.

*Guaranteed for every test database:* the reserved size (offset 20) is 0, the
text encoding (offset 56) is 1 (UTF-8), and auto-vacuum is off (offset 52 is
0, so there are no pointer-map pages). The page size is one of 512, 1024,
4096 or 65536. You still need the `U` formula below, because the payload
overflow thresholds are written in terms of it.

### 1.2 B-tree pages

A B-tree page begins with an 8- or 12-byte page header. **On page 1 the page
header starts at byte offset 100**, immediately after the database header; on
every other page it starts at offset 0. Let `base` be that offset.

| offset from `base` | size | meaning |
|--------|------|---------|
| 0 | 1 | page type |
| 1 | 2 | offset of the first freeblock (ignore) |
| 3 | 2 | number of cells on this page |
| 5 | 2 | start of the cell content area; 0 means 65536 (ignore) |
| 7 | 1 | number of fragmented free bytes (ignore) |
| 8 | 4 | **interior pages only**: the right-most child page number |

Page types:

| byte | page |
|------|------|
| 0x02 | interior index |
| 0x05 | interior table |
| 0x0a | leaf index |
| 0x0d | leaf table |

Immediately after the page header comes the **cell pointer array**: one
2-byte big-endian offset per cell, in key order, measured from the start of
the page (**not** from `base`). It begins at `base + 12` on interior pages and
`base + 8` on leaf pages. The cells themselves live at those offsets, in
arbitrary order.

### 1.3 Varints

A varint is 1 to 9 bytes encoding a 64-bit two's-complement integer. For the
first 8 bytes, the low 7 bits of each byte contribute to the value
(most-significant group first) and the high bit means "another byte follows".
If a ninth byte is reached, all 8 of its bits are appended, giving 56 + 8 = 64
bits. The resulting 64-bit pattern is interpreted as a signed two's-complement
integer. Payload sizes, header sizes and serial types are always non-negative
and short; a **rowid may be negative**, and a negative rowid is always written
as the full nine bytes, so the signed interpretation matters.

### 1.4 Cell formats

Let `P` be the total payload size in bytes.

* **Table leaf (0x0d)**: varint `P`, varint rowid, then `P` bytes of payload
  (possibly truncated, see 1.5).
* **Table interior (0x05)**: 4-byte left child page number, varint rowid key.
  There is no payload.
* **Index leaf (0x0a)**: varint `P`, then payload.
* **Index interior (0x02)**: 4-byte left child page number, varint `P`, then
  payload.

### 1.5 Payload overflow

Not all of a payload need live on its page. With `U` the usable size:

```
M = ((U - 12) * 32 / 255) - 23          (integer division, truncating)
X = U - 35                              for table leaf pages
X = ((U - 12) * 64 / 255) - 23          for index pages (leaf and interior)

if P <= X:            local = P
else:
    K = M + ((P - M) mod (U - 4))
    local = K if K <= X else M
```

When `local < P`, the `local` payload bytes are followed **on the same page**
by a 4-byte big-endian page number of the first **overflow page**. An overflow
page holds a 4-byte big-endian page number of the next overflow page (0 at the
end of the chain) followed by up to `U - 4` bytes of payload. Concatenate
`local` bytes from the cell with the successive overflow chunks until `P`
bytes have been gathered; the last chunk is usually shorter than `U - 4`.

### 1.6 Table B-trees

A table B-tree is keyed by rowid. An interior page's *i*-th cell points to a
subtree whose rowids are all `<= key_i`; the right-most pointer in the page
header covers rowids greater than the last key. Walking the cells left to
right, descending into each child before emitting that cell's key, and
finishing with the right-most child, visits every row in ascending rowid
order. A leaf page's cells are already in ascending rowid order.

### 1.7 Index B-trees

An index B-tree is keyed by the index record (see 1.8): the indexed column
values followed by the rowid of the table row. Both leaf and interior pages
carry payloads, so **interior cells hold real index entries too** — an
in-order walk must emit an interior cell's own entry between its left subtree
and the next child. Keys are ordered by the comparison rules of Part 3.

### 1.8 Record format

A payload (a table row, or an index entry) is a *record*:

```
varint  header size H   (counted from the first byte of the record, i.e. H
                         includes the bytes of the header-size varint itself)
varint  serial type of column 0
varint  serial type of column 1
...                              (until H bytes have been consumed)
bytes   body: the columns' values, back to back, in column order
```

Serial types:

| type | size | value |
|------|------|-------|
| 0 | 0 | NULL |
| 1 | 1 | big-endian two's-complement integer |
| 2 | 2 | big-endian two's-complement integer |
| 3 | 3 | big-endian two's-complement integer |
| 4 | 4 | big-endian two's-complement integer |
| 5 | 6 | big-endian two's-complement integer |
| 6 | 8 | big-endian two's-complement integer |
| 7 | 8 | IEEE-754 binary64, big-endian |
| 8 | 0 | the integer 0 |
| 9 | 0 | the integer 1 |
| 10, 11 | — | not used |
| N >= 12, even | (N-12)/2 | BLOB of that many bytes |
| N >= 13, odd  | (N-13)/2 | TEXT of that many bytes, UTF-8 |

*Guaranteed:* every TEXT value in every test database is well-formed UTF-8, and
every REAL is finite (no infinity, no NaN).

A record may carry **fewer** values than the table has columns (this happens
after `ALTER TABLE ... ADD COLUMN`). Missing trailing columns read as NULL.
No test database uses `ADD COLUMN` with a non-NULL default.

### 1.9 Freelist

Pages that are no longer in use form a linked list starting at the page number
in header offset 32. A trunk page holds a 4-byte next-trunk page number (0 at
the end), a 4-byte count of leaf page numbers, and that many 4-byte page
numbers. You never have to read a free page to answer a query — free pages are
unreachable from any B-tree root — but several test databases contain hundreds
of them and their contents are stale, so **do not** discover rows by scanning
the file for leaf pages. Always start from a root page named in the schema.

### 1.10 The schema table

Page 1 is the root of the `sqlite_schema` table B-tree. Its rows have five
columns:

```
type      TEXT    'table' | 'index' | 'view' | 'trigger'
name      TEXT    the object's name
tbl_name  TEXT    the table the object belongs to
rootpage  INTEGER the object's root page, or 0/NULL for objects without one
sql       TEXT    the CREATE statement, or NULL for internally created objects
```

Rows appear in ascending rowid order; that order is the *schema order* used by
`.schema` below. Views and triggers are ordinary rows of this table with a
`rootpage` of 0 (there is no B-tree to read); their `tbl_name` is the view's own
name and the triggered table's name respectively. Indexes created automatically for `PRIMARY KEY` / `UNIQUE`
constraints are named `sqlite_autoindex_<table>_<n>` and have a NULL `sql`.

---

## Part 2 — interpreting the schema

### 2.1 `CREATE TABLE`

You only need column **names**, their **declared types**, and which column (if
any) is the rowid alias. Parse the statement as follows.

Tokens are: whitespace-separated runs of `[A-Za-z0-9_$]`; the single
characters `(`, `)`, `,`, `.`, `;`; and quoted names. A quoted name is
`"..."`, `` `...` `` or `[...]`; inside `"` and `` ` `` a doubled quote
character is a literal one, and `[` … `]` has no escape. `--` to end of line
and `/* … */` are comments. Keyword matching is ASCII case-insensitive.

The statement is `CREATE [TEMP|TEMPORARY] TABLE [IF NOT EXISTS] [schema.]name
( item , item , ... )`. Split the parenthesised body at commas that are at
paren-nesting depth 0. Each item is either

* a **table constraint**, if its first token is an unquoted `CONSTRAINT`,
  `PRIMARY`, `UNIQUE`, `CHECK` or `FOREIGN`; or
* a **column definition**: a name, then an optional declared type, then
  constraints. The declared type is the run of tokens after the name up to the
  first unquoted keyword in `{CONSTRAINT, PRIMARY, NOT, NULL, UNIQUE, CHECK,
  DEFAULT, COLLATE, REFERENCES, GENERATED, AS, AUTOINCREMENT}`; a
  parenthesised size such as `(10,2)` belongs to the type. A column may have
  no declared type at all.

Column order in the file is the order the definitions appear.

### 2.2 The rowid alias (`INTEGER PRIMARY KEY`)

Every table in this problem is a rowid table. A column becomes an **alias for
the rowid** when its declared type is exactly `INTEGER` (case-insensitive, one
word, no size) **and** it is the primary key, either

* through a column constraint `PRIMARY KEY` not followed by `DESC`, or
* through a table constraint `PRIMARY KEY (<one column>)`, **whether or not**
  that column is marked `DESC`.

The two forms really do disagree about `DESC`, and the asymmetry is
deliberate: `x INTEGER PRIMARY KEY DESC` is an ordinary column, while
`x INTEGER, PRIMARY KEY(x DESC)` is a rowid alias. SQLite's own documentation
describes the second as a long-standing quirk it keeps for compatibility.
Both spellings appear in the tests.

Chinook, for instance, declares `[AlbumId] INTEGER NOT NULL, CONSTRAINT
[PK_Album] PRIMARY KEY ([AlbumId])` — the second form.

An alias column is **stored as NULL in every record**. Its value is the cell's
rowid, and you must substitute it. A table has at most one alias column. If
the primary key is anything else — a column whose declared type is not exactly
`INTEGER` (so `code INT PRIMARY KEY` is *not* an alias), several columns, or a
column-level `PRIMARY KEY DESC` — then no column is an alias and the records
carry the real values. SQLite will have created an `sqlite_autoindex_...` index
for such a constraint; it has a NULL `sql` and you never need to read it.

`WITHOUT ROWID` tables do not occur.

### 2.3 Type affinity

Each column has an affinity derived from its declared type, upper-cased, by
applying these rules **in order** and stopping at the first match:

1. contains `INT` → **INTEGER**
2. contains `CHAR`, `CLOB` or `TEXT` → **TEXT**
3. contains `BLOB`, or the declared type is empty → **BLOB**
4. contains `REAL`, `FLOA` or `DOUB` → **REAL**
5. otherwise → **NUMERIC**

So `NVARCHAR(160)` is TEXT, `NUMERIC(10,2)` is NUMERIC, `INTEGER` is INTEGER,
a column with no type is BLOB. A rowid alias column has INTEGER affinity, and
so does the `rowid` pseudo-column.

The order matters and the rules really do stop at the first match: `POINT`
and `FLOATING POINT` both contain `INT` and are therefore **INTEGER** (rule 1
beats rules 4 and 5), while `STRING` does not contain `INT` (S-T-R-I-N-G) and
is **NUMERIC** by rule 5; a type containing both `INT` and `TEXT` is
INTEGER (rule 1 beats rule 2); one containing both `CHAR` and `FLOA` is TEXT
(rule 2 beats rule 4); one containing both `BLOB` and `REAL` is BLOB (rule 3
beats rule 4).

### 2.4 The REAL storage optimisation

SQLite writes a floating-point value with no fractional part into a
**REAL-affinity** column as an integer serial type, and widens it back to a
float when reading. Therefore: **after decoding a record, every integer value
read out of a column whose affinity is REAL becomes a floating-point value.**
Without this, `0.0` in a `REAL` column prints as `0` instead of `0.0`.

This conversion applies only to REAL affinity, only to values read from a
table row, and never to the rowid.

### 2.5 `CREATE INDEX`

`CREATE [UNIQUE] INDEX [IF NOT EXISTS] [schema.]name ON table ( col [COLLATE
x] [ASC|DESC] , ... )`. You need the index name, its table, and the list of
indexed column names. No test database contains a partial index (`WHERE`
clause on an index), an expression index, or a non-`BINARY` collation.

An index entry is a record holding the indexed columns' values in order,
followed by the rowid of the indexed row.

---

## Part 3 — values, ordering and comparison

A value has one of five **storage classes**: NULL, INTEGER, REAL, TEXT, BLOB.

**Ordering.** NULL sorts before every number; every number sorts before every
TEXT; every TEXT sorts before every BLOB. Two NULLs are equal. Two numbers
compare by mathematical value regardless of whether each is an INTEGER or a
REAL. Two TEXT values compare by the unsigned byte order of their UTF-8
encodings (`BINARY` collation), shorter-is-smaller when one is a prefix of the
other. Two BLOBs compare by unsigned byte order the same way.

Two INTEGERs are compared exactly, as signed 64-bit integers; the test data
does rely on that past 2^53. *Guaranteed:* no comparison **between an INTEGER
and a REAL** in the test data depends on more precision than an IEEE-754
double provides, so for that mixed case you may widen the INTEGER to a double
before comparing.

**Applying affinity to a query literal.** Before a literal is compared against
a column, it is converted according to the column's affinity:

* affinity TEXT and the literal is an INTEGER or a REAL → convert it to TEXT
  using the output formatting of Part 5;
* affinity INTEGER, REAL or NUMERIC and the literal is TEXT that is entirely a
  **numeric constant** → convert it to that number. The text is a numeric
  constant when, after dropping any leading and trailing spaces and tabs, all
  of what remains matches

  ```
  [+-]?  ( digits [ "." digits? ]  |  "." digits )  ( [eE] [+-]? digits )?
  ```

  where `digits` is one or more ASCII decimal digits. The digits **may** begin
  after the point here, so `'.5'`, `'-.5'`, `'5.'`, `' 5 '` and `'+5e0'` are
  all numeric constants — even though `.5` is *not* a legal query numeral
  (§4.4); the two grammars are deliberately different. The result is an
  INTEGER when the text has neither a `.` nor an exponent and the value fits
  in a signed 64-bit integer, and a REAL otherwise. Which of the two you
  produce **does** matter: `'9223372036854775807'` must become that exact
  INTEGER, because rounding it to a double would make it compare equal to
  `9223372036854775806`. Anything else — `''`, `'-'`, `'0x10'`, `'inf'`,
  `'5 x'`, a number with any other character beside it — is left as TEXT;
* in every other case, including affinity BLOB and any NULL or BLOB literal,
  leave it alone.

Column values themselves are never converted; only the literal is.

---

## Part 4 — the query language

Each line of `queries.txt` is one of the five commands below. Keywords
(`SELECT`, `COUNT`, `INDEX`, `FROM`, `WHERE`, `AND`, `ORDER`, `BY`, `ASC`,
`DESC`, `LIMIT`, `IS`, `NOT`, `NULL`) are matched ASCII case-insensitively.
The two **dot commands are lower case only**: `.SCHEMA` and `.TABLES` are
unknown dot commands and therefore errors. Table, column and
index names are bare identifiers matching `[A-Za-z_][A-Za-z0-9_]*` and are
resolved ASCII case-insensitively against the schema.

**Separators.** Call a *word* any run of `[A-Za-z0-9_]`: a keyword, an
identifier, or the digits of a numeral. Two adjacent words must be separated
by at least one space or tab. Everywhere else a separator is optional and any
number of spaces and tabs is allowed. So `SELECT*FROM t`, `SELECT a,b FROM t`,
`WHERE a>=1` and `SELECT  name ,  age  FROM  t` are all legal, while `SELECTa`,
`ORDERBY a` and `LIMIT3` are not. In a dot command the command name and its
argument are separated by exactly one space in every input.

### 4.1 `.tables`

Print the `name` of every `sqlite_schema` row whose `type` is `table` and
whose name does not begin with `sqlite_` (compared ASCII case-insensitively,
so `SQLite_x` is excluded too), one per line, sorted by the unsigned byte
order of the UTF-8 name. SQLite's own bookkeeping tables — `sqlite_sequence`
for an `AUTOINCREMENT` table, for instance — are real rows of `sqlite_schema`
and must be filtered out here; `.schema sqlite_sequence` still prints its DDL,
and `SELECT`/`COUNT` read it like any other table. Rows whose `type` is
`index`, `view` or `trigger` are not tables and are never listed — note that
the real `sqlite3` shell's own `.tables` *does* list views, and this command
does not.

### 4.2 `.schema <table>`

`<table>` must be a bare identifier; `.schema 9bad`, `.schema people;`,
`.schema` with no argument and `.schema a b` are all errors.

For every `sqlite_schema` row, in ascending rowid (schema) order, whose
`tbl_name` equals `<table>` case-insensitively and whose `sql` is not NULL,
print the `sql` text followed by a single `;`. The `sql` text usually contains
newlines, so one statement may span many output lines.

The rows are matched on `tbl_name`, never on `name`, and their `type` is not
examined. So `.schema <table>` also prints the `CREATE INDEX` and
`CREATE TRIGGER` statements attached to that table, interleaved with the
`CREATE TABLE` in schema order, while `.schema <an index name>` and
`.schema <a trigger name>` print nothing at all. Automatically created indexes
have a NULL `sql` and contribute nothing. An unknown table name yields an empty
file, not an error.

### 4.3 `COUNT <table>`

Print the number of rows in the table as a single decimal line.

### 4.4 `SELECT`

```
SELECT <columns> FROM <table>
       [ WHERE <cond> [ AND <cond> ]... ]
       [ ORDER BY <column> [ ASC | DESC ] ]
       [ LIMIT <n> ]
```

* `<columns>` is either `*` or a list of one or more column names separated by
  `,` (spaces around the comma are allowed). `*` means every column of the
  table in declared order — it does **not** include the rowid unless a column
  aliases it.
* `<table>` must name a `sqlite_schema` row whose `type` is `table`. A view,
  an index or a trigger name is an error, and so is `sqlite_schema` itself,
  which is not one of its own rows.
* A column name may be `rowid`, referring to the row's rowid. (No test table
  has a column actually named `rowid`; a real column always wins if one did.)
  `rowid` may appear in the select list, in a condition and in `ORDER BY`.
  SQLite's other spellings of the rowid, `_rowid_` and `oid`, are **not**
  recognised here: they are ordinary column names, and therefore errors unless
  the table really has a column so named.
* `<cond>` is `<column> <op> <literal>` with `<op>` **exactly** one of the
  eight spellings `=` `!=` `<` `<=` `>` `>=` `IS` `IS NOT` (the two word
  operators are case-insensitive and are separated from `NOT` by at least one
  space or tab). Any other spelling is a malformed query and therefore an
  error — in particular SQL's `==` and `<>` are **not** accepted here.
  - For the six comparison operators, a condition is false whenever either
    side is NULL.
  - `IS` is NULL-safe equality: `x IS NULL` is true exactly when the value is
    NULL, and `IS` otherwise behaves like `=`. `IS NOT` is its negation.
  - Conditions joined by `AND` must all hold.
* `<literal>` is one of
  - a **numeral**: an optional `+` or `-`, then **one or more** decimal digits,
    then optionally a `.` followed by zero or more digits, then optionally an
    exponent (`e` or `E`, an optional sign, and one or more digits). At least
    one digit must precede the `.`, so `1.5`, `1.`, `-2.5e-3` and `+7` are all
    legal but `.5` and `1e` are malformed. A numeral with neither a `.` nor an
    exponent is an **integer** and always fits in a signed 64-bit integer;
    otherwise it is a **real**.
  - a string: `'...'`, where `''` inside means one `'`. A string that is not
    closed before the end of the line is malformed.
  - a blob: `X'` or `x'`, followed by an **even** number of hex digits (either
    case) and `'`. An odd digit count or a non-hex character is malformed.
  - `NULL` (case-insensitive).
* `<n>` in `LIMIT` is a decimal integer with no sign — digits only, so
  `LIMIT -1` is malformed — and always fits in a signed 64-bit integer.

**Row order.** Without `ORDER BY`, rows come out in ascending rowid order.
With `ORDER BY <column>`, rows are ordered by that column using the Part 3
ordering, ascending unless `DESC` is given; **ties are always broken by
ascending rowid, in both directions.** NULLs are smallest, so they come first
for `ASC` and last for `DESC`. `LIMIT` is applied last, keeping the first `n`
rows.

**Output.** One line per row: the selected columns formatted as in Part 5 and
joined with a single TAB (`U+0009`). *Guaranteed:* no TEXT value in any test
database contains a tab, a newline or a carriage return, so the rows are
unambiguous.

### 4.5 `INDEX <index-name> <literal>`

A point lookup that must go through the index B-tree rather than scanning the
table. The named index must be one created by a `CREATE INDEX` statement
(`sql` not NULL) with **exactly one** indexed column; anything else is an
error (see below).

Apply the indexed column's affinity to the literal (Part 3), then find every
index entry whose key equals it. A NULL key matches nothing, so
`INDEX <name> NULL` always yields an empty result. For each matching entry,
read the table row with that rowid and print it exactly as `SELECT * FROM
<table>` would, in ascending rowid order.

### 4.6 Errors

A query whose result cannot be produced writes a file containing the single
line `error` and nothing else. The program still exits 0. This covers:

* a line that does not parse as one of the five commands (an unknown dot
  command, including an upper-case `.SCHEMA`; a dot command with the wrong
  number of arguments, or with an argument that is not a bare identifier; a
  missing clause; a malformed literal; trailing text
  after a complete query, such as a second `ASC`/`DESC`; an unsupported
  operator such as `==` or `<>`);
* a reference to a table, column or index that does not exist, including
  `SELECT` or `COUNT` naming a view, a trigger, an index or `sqlite_schema`;
* `INDEX` naming a table, a view, an auto-created index (`sql` is NULL), or an
  index with more than one column.

`.schema <unknown table>` is *not* an error; it produces an empty file, as
does any `SELECT` whose `WHERE` matches nothing.

---

## Part 5 — printing values

Values are printed the way the `sqlite3` shell prints them in its default list
mode, with `-nullvalue NULL`, and with blobs hex-encoded:

| class | output |
|-------|--------|
| NULL | the four characters `NULL` |
| INTEGER | decimal, with a leading `-` when negative, no `+`, no padding |
| REAL | see below |
| TEXT | the characters themselves, UTF-8, unquoted, unescaped |
| BLOB | uppercase hexadecimal, two digits per byte, no `0x`, no separators; an empty blob prints as the empty string |

**REAL** is printed with the equivalent of C's `%.15g` — round to 15
significant decimal digits, drop trailing zeros in the fraction, and use
exponential form when the decimal exponent is below -4 or at least 15 — with
two adjustments:

1. if the resulting mantissa contains no `.`, append `.0` to it (so `1`
   becomes `1.0` and `1e+300` becomes `1.0e+300`);
2. zero prints as `0.0`, never `-0.0`.

The exponent is written as `e`, then `+` or `-`, then at least two decimal
digits. Examples:

| value | printed |
|-------|---------|
| 1.0 | `1.0` |
| 0.1 | `0.1` |
| -3.25 | `-3.25` |
| 1/3 | `0.333333333333333` |
| 1e300 | `1.0e+300` |
| 2.5e-10 | `2.5e-10` |
| 1.5e16 | `1.5e+16` |
| 1e14 | `100000000000000.0` |
| 1e15 | `1.0e+15` |
| 0.0001 | `0.0001` |
| 1e-5 | `1.0e-05` |
| 0.0 | `0.0` |
| -0.0 | `0.0` |

*Guaranteed:* every REAL stored in a test database satisfies
`strtod(sprintf("%.15g", v)) == v`, so rounding to 15 significant digits is
never an exact tie and every correctly rounding implementation prints the same
digits.

---

## Worked examples

Take a database `mini.sqlite` built by

```sql
PRAGMA page_size=4096;
CREATE TABLE people(
    id INTEGER PRIMARY KEY,
    name TEXT NOT NULL,
    age INTEGER,
    height REAL,
    photo BLOB);
INSERT INTO people VALUES
    (1,'Ada',36,1.65,x'000102'),
    (2,'Grace',45,1.7,NULL),
    (3,'Alan',NULL,1.8,x''),
    (6,'',0,0.0,x'7f');
CREATE INDEX people_age ON people(age);
```

and this `queries.txt`:

```
.tables
SELECT * FROM people
SELECT name,height FROM people ORDER BY height DESC LIMIT 2
SELECT name FROM people WHERE age IS NULL
SELECT name FROM people WHERE age > 40
SELECT rowid,name FROM people WHERE photo IS NOT NULL
INDEX people_age 45
COUNT people
SELECT nope FROM people
```

The output directory then holds:

`001.txt`
```
people
```

`002.txt` — `id` is the rowid alias, so the NULL stored in the record is
replaced by the rowid; `height` of row 6 was written to disk as an integer but
the column's affinity is REAL, so it reads back as `0.0`; blobs are uppercase
hex and an empty blob is an empty field.
```
1	Ada	36	1.65	000102
2	Grace	45	1.7	NULL
3	Alan	NULL	1.8	
6		0	0.0	7F
```

`003.txt`
```
Alan	1.8
Grace	1.7
```

`004.txt`
```
Alan
```

`005.txt` — `Alan`'s NULL age makes the comparison false.
```
Grace
```

`006.txt`
```
1	Ada
3	Alan
6	
```

`007.txt` — an index point lookup prints the whole row.
```
2	Grace	45	1.7	NULL
```

`008.txt`
```
4
```

`009.txt`
```
error
```

Note the difference between a NULL blob (row 2, printed `NULL`) and an empty
blob (row 3, printed as nothing at all).

---

## Test data

The `tests/` corpus runs from hand-written edge cases to real databases:
Chinook (MIT licence) and an import of the OurAirports public-domain dataset
with 86,112 airports and 48,250 runways across two tables and four indexes.
Page sizes 512, 1024, 4096 and 65536 all appear; so do multi-page overflow
chains for blobs, text and index keys, payloads sized exactly on and one byte
past both local-payload thresholds, explicit rowids covering every varint
width (negatives included), a database with nearly two thousand freelist pages
left behind by deletes, short records from `ALTER TABLE ADD COLUMN`,
`AUTOINCREMENT` and its internal `sqlite_sequence` table, declared type names
that pin the order of the affinity rules, primary keys in every shape that
does and does not alias the rowid, a view and a trigger among the
`sqlite_schema` rows, a low-cardinality index deep enough that one key's run of
entries spans whole subtrees rooted at interior index pages, and UTF-8 text
from several scripts. Expected outputs were produced by the reference
implementation and cross-checked query by query against the `sqlite3`
command-line shell.

The reference implementation reads the whole file into memory. The largest
test database is 16 MB.
