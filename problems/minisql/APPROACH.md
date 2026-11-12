# minisql: required approach

SPEC.md defines what the program must output; this note defines how it computes
it. Where the two seem to disagree, SPEC.md wins.

Sizes: `L` is the input size, `N` the rows of a scanned table, `A` and `B` the
rows of the first and second FROM tables, `M` the row pairs whose join keys
match, `R` the rows that reach the select list, `G` the groups, `|e|` the size
of an expression.

## Algorithm

Each statement is tokenized, **parsed** by recursive descent into a syntax
tree, **bound** against the current schema (every column reference resolved to
a table and column, every semantic check run) and then **executed**. Binding
finishes before any table changes, so a failing statement has no effect. A
table is its column names and its rows in insertion order. Expressions are
evaluated over the bound tree, with one three-way comparison implementing
SPEC.md's total order for comparisons, sorting, grouping, MIN and MAX.

Execution scans whole tables. WHERE and ON are split into AND conjuncts; those
reading one table filter it before a join. A two-table query with cross-table
equalities is a hash join on all of them as one composite key. GROUP BY groups
rows in a hash map, then sorts the groups.

## Required rules

1. **No indexes and no caching across statements.** Every SELECT, UPDATE and
   DELETE scans its tables in full; nothing parsed, bound or computed is reused
   by a later statement.
2. **Hash joins.** A join with at least one cross-table equality (whose sides
   may be any expressions) costs O(A + B + M) expected evaluations, not O(A·B);
   only without one is it a nested loop over the filtered rows.
3. **LIKE is a wildcard matcher with one backtrack point** (the last `%`),
   O(|s|·|p|) worst case, without conversion to a regular expression.
4. **Expressions are interpreted from the bound tree.** No compilation to
   bytecode or native code, and no constant folding.
5. **ORDER BY is one stable comparison sort of all result rows**, even when
   LIMIT is present (no top-k selection).

## Complexity

Lexing and parsing are O(L). A scan, UPDATE or DELETE is O(N·|e|). A join is
O((A + B + M)·|e|) expected. Grouping is O(R) expected plus O(G log G) to sort
the groups, and ORDER BY is O(R log R).
