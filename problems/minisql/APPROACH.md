# minisql — required approach

SPEC.md defines what the program does. This note defines how it is built. Where
the two seem to disagree, SPEC.md wins.

## Overall approach

Read all of stdin into one buffer, tokenize it, and process statements one at a
time through three phases: **parse** the tokens into an AST, **bind** the AST
against the current schema (resolve every column reference to a (FROM slot,
column index) pair, assign aggregate calls to accumulator slots, run every
semantic check, turn literals into ready values), then **execute**. Binding
finishes before any table is touched, and execution cannot fail, so a failing
statement never needs undoing. Tables are row-major arrays of rows of tagged
values in insertion order. Expressions are evaluated by a tree-walking
interpreter over the bound tree. Every statement does a full scan of its
tables: single-table queries filter in one pass, two-table queries filter each
table by its own conjuncts and then hash-join on the cross-table equalities in
nested-loop order, GROUP BY uses a hash map of streaming accumulators, and
ORDER BY is a stable sort over precomputed keys. All output goes into one
buffer that is written once at the end.

Sizes below: `L` is the input size in bytes, `N` the rows of a scanned table,
`A` and `B` the rows of the first and second FROM tables, `M` the row pairs
whose hash keys match, `R` the rows that reach the select list, `G` the groups,
and `|e|` the node count of an expression.

## Required choices

1. **Input and lexing, O(L).** One bulk read of stdin. The lexer walks the
   bytes once. Keywords are recognised without a heap allocation (compare
   case-insensitively, or lower-case into a reused buffer before lookup), and
   an identifier is lower-cased at most once, into a view or a single new
   string. Integers are parsed with a digit loop. String literals are a view
   into the input unless they contain `''`, in which case they are copied once.
   Tokenizing the whole input up front or one statement at a time are both
   fine.
2. **Parse, then bind, then execute.** Each statement is parsed by a
   recursive-descent parser with one function per precedence level of the SPEC
   grammar. A separate bind pass produces the executable form. Column names are
   resolved once per statement, never per row. String literals become text
   values once at bind time, not on each evaluation. INSERT value expressions
   are bound and evaluated into new rows held aside, then appended to the table
   only after every row has passed its checks. Nothing parsed or bound is
   cached across statements.
3. **Value representation.** A small tagged value: NULL, INTEGER (`int64`),
   TEXT, and REAL stored as an integer number of hundredths (exact, because
   only AVG produces REAL and it is already rounded; an INTEGER `i` compares
   with a REAL `h` as `i·100` against `h`). TEXT is a reference to immutable
   UTF-8 bytes (a slice, a shared string, or a reference-counted pointer), so
   copying a value is O(1) and never copies or allocates text. Text compares
   bytewise. The total order of SPEC *Comparison* is one three-way function
   used by comparisons, sorting, grouping, MIN and MAX.
4. **Table storage.** A table is its column names plus an array of rows in
   insertion order. Each row is a contiguous array of values. There are no
   indexes, no statistics and no cached query results: every SELECT, UPDATE and
   DELETE scans the whole table, O(N·|e|).
5. **Expression evaluation.** A tree-walking interpreter over the bound tree,
   written either as a switch on node kind or as a tree of closures. There is
   one node per grammar operator, plus column and constant leaves. A column
   node reads `row[slot][col]` from an evaluation context that holds a
   reference to the current row of each FROM table and to the current group's
   aggregate values. Rows are never copied into the context. `AND` and `OR`
   short-circuit: a false left operand of AND gives 0, a true left operand of
   OR gives 1, and the right operand is not evaluated in either case. No
   bytecode, runtime code generation, constant folding or fused "column op
   constant" nodes.
6. **LIKE, O(|s|·|p|) worst case, no allocation.** The iterative wildcard
   matcher with a single backtrack point for the last `%`, run directly on the
   UTF-8 bytes. `_` consumes one whole UTF-8 sequence, and on backtracking the
   string position saved for the last `%` also advances by one whole sequence
   (advancing by one byte lets later `_`s match continuation bytes and gives
   wrong answers). Other pattern bytes match bytewise with ASCII-only case
   folding done inline. An INTEGER operand is formatted into a stack or scratch
   buffer. Neither string is decoded, lower-cased into a copy, or converted to
   a code-point array.
7. **Single-table scan, O(N·|e|).** Split WHERE into its top-level AND
   conjuncts at bind time. Test each row against them in order, stopping at the
   first one that is not true. Surviving rows go straight into projection, or
   into aggregation (item 9), as row references or indices. Rows are never
   copied.
8. **Two-table join: filter each side, then hash join, O(A + B + M) plus
   residual work.** Collect the top-level conjuncts of ON and WHERE at bind
   time and classify each by the tables it reads. A conjunct that reads only
   the first table (or no table) is tested once per first-table row, before
   that row probes; one that reads only the second table is tested once per
   second-table row, before that row enters the map. Every conjunct of the form
   `e1 = e2` (or `==`), where one side reads only the first table and the other
   only the second (the sides are arbitrary expressions, such as `a.age + 1 =
   b.age`), becomes part of one composite key. Build a hash map on the
   **second** table: for each row that passes its own conjuncts, in table
   order, evaluate its key, skip it if any key component is NULL, and append
   the row index to the key's bucket. Then probe with each passing row of the
   first table in table order, skipping NULL keys. For each bucket entry, in
   bucket order, evaluate only the conjuncts that read both tables and are not
   key equalities. This produces pairs in nested-loop order. Key equality is
   value equality with the type tag included, so 1 and `'1'` never match. Pairs
   are passed on as (row, row) references or index pairs and never copied into
   new rows. Without a cross-table equality, apply the same one-table filters
   (collect the passing second-table rows once as an index list), then run a
   nested loop over the passing rows testing the remaining conjuncts.
9. **Aggregation with streaming accumulators, O(R + G log G).** Each aggregate
   slot has an accumulator (count, int64 sum, current min or max value) that is
   updated as each surviving row arrives. Rows are not stored per group.
   Without GROUP BY there is exactly one accumulator set. With GROUP BY, one
   hash map goes from the grouping values to a dense group id. Hash the values
   of the current row directly, or encode them into one reused scratch buffer.
   Store an owned key only when a new group is created. Each group also keeps
   its grouping values (or a reference to its first row) for evaluating the
   select list and HAVING. After the scan, sort the group ids by grouping
   values with the total order, finish the aggregates (AVG uses the integer
   formula from SPEC), apply HAVING, and evaluate the select list per group.
10. **ORDER BY, O(R log R).** For each row or group that reaches the select
    list, evaluate the output values and then the sort keys once. An alias or
    ordinal term reuses the output value. Sort all result rows with one
    **stable** comparison sort, over a permutation of indices or over the row
    records, comparing precomputed keys with per-term direction. Then apply
    OFFSET and LIMIT by slicing. Always do the full sort, even when LIMIT is
    present.
11. **UPDATE and DELETE, O(N·|e|) in one pass.** UPDATE evaluates every
    right-hand side for a matching row into a small reused buffer, then assigns
    the values in place. DELETE does a stable in-place compaction (a read index
    and a write index over the row array), or builds one new row array with
    capacity reserved. A DELETE without WHERE empties the table.
12. **Output, O(output size).** Values are formatted straight into one output
    buffer: integers by a digit loop or an allocation-free formatter, REAL from
    its hundredths, text by copying its bytes. A statement's result rows are
    appended only after it has fully succeeded. The buffer is written to stdout
    once at the end, or through one large buffered writer flushed at exit.

## Left to the implementer

Where a language cannot meet an allocation rule above (for example, every
string or tuple is a heap object), the rule means the closest equivalent: no
copies or temporary objects beyond the ones the language itself forces, and
never per-character work outside the one lexer pass.

- Container types, struct layout, naming and module structure. Rows can be
  individually allocated or slices of one flat array per table.
- Whether text values are slices of the input buffer, interned strings,
  garbage-collected strings or reference-counted strings, provided copying is
  O(1) without allocation.
- The hash map type and hash function, and how a composite key is represented
  (a tuple, a small array, or bytes encoded into a scratch buffer), provided
  lookups take expected O(1) time and do not allocate per row.
- Whether candidates are streamed straight into projection or aggregation, or
  first collected as an array of row indices or index pairs.
- How errors propagate out of parse and bind (exceptions, result types, panics
  with recovery).
- Whether the parser works on a token array or pulls tokens from the lexer.
- Loop-level micro-optimisations: bounds-check elimination, inlining, and
  whether evaluation returns values or borrows them.

## Pitfalls

- A nested-loop join when ON/WHERE contains a cross-table equality, including
  when one side is an expression rather than a bare column (`a.age + 1 =
  b.age`). Recognising only `column = column` turns those self joins into 4×10⁶
  pair evaluations each.
- Hashing on only the first cross-table equality when there are several
  (`o.user_id = q.user_id AND o.qty = q.qty`). This multiplies the residual
  work.
- Testing one-table conjuncts (`o.status = 'done'`, `u.city = 'austin'`) per
  joined pair instead of once per row before the build or probe, or re-testing
  the key equalities on pairs the hash lookup already matched.
- Copying each surviving row or row pair into a freshly allocated row before
  projection or aggregation. Storing every row of a group (or of the whole
  table for `COUNT(*)` without GROUP BY) and aggregating afterwards. Copying
  the two source rows into a scratch row for every candidate pair.
- A value type that holds an owned string by value, so that every column read,
  every literal evaluation and every key copy duplicates the text. Building a
  new string from a literal on each evaluation.
- LIKE that decodes both operands into code-point arrays, or lower-cases them
  into new strings, on every row.
- Building an owned composite key (a new string, a new array or a vector of
  cloned values) for every row in GROUP BY or in the join build and probe,
  instead of hashing in place or reusing a buffer.
- Allocating per token in the lexer (upper-casing every word into a new string
  to look up keywords, or converting the whole input into an array of code
  points). The INSERT-heavy part of the input is over 1 MB.
- Allocating a fresh buffer per row for UPDATE results, or building a string
  per output value (generic `to_string`-style conversion followed by
  concatenation) instead of appending into the output buffer.
- Re-resolving column names, or re-evaluating sort keys, inside the comparison
  function or the row loop.
- An unstable sort, or a sort that breaks ties by anything but the pre-sort
  position. Both give wrong output, not just slower output.
- Adding indexes on `id`-like columns or caching results between statements.
  This changes the work being measured. Every point query is a full scan.
