# sqlitefile: required approach

SPEC.md defines what the program must output; this note defines how it computes
it. Where the two seem to disagree, SPEC.md wins.

Sizes: `N` is the rows of the queried table, `C` its column count, `R` the rows
that match WHERE, `K` the index entries equal to the key, `d` the B-tree depth
and `F` the cells per page.

## Algorithm

The program reads `sqlite_schema` once and parses every `CREATE TABLE` and
`CREATE INDEX` into a catalog shared by all queries. Each query is parsed in one
pass, resolved against the catalog and executed by walking B-trees from their
root pages, decoding records from their serial-type headers and following
overflow chains (SPEC.md §1.5). One three-way comparison implementing SPEC.md
Part 3 serves conditions, sorting and index search.

- **SELECT** walks the table B-tree in rowid order and filters each row.
  Without ORDER BY it stops once `LIMIT` rows have matched; with ORDER BY it
  stably sorts the matched rows, then truncates to `LIMIT`.
- **COUNT** adds up the leaf pages' cell counts.
- **INDEX** searches the index B-tree for the first entry `>=` the key, walks
  the equal entries in key order (interior pages hold entries too), and fetches
  each row by a rowid search of the table B-tree.

## Required rules

1. **SELECT is a full scan of the table B-tree**: never an index, a rowid seek
   or a scan of the file for leaf pages.
2. **ORDER BY sorts every matched row**, then applies LIMIT; no top-k
   selection.
3. **COUNT reads no records**, and **INDEX never scans** the whole index or
   table: they meet the bounds below.
4. **Nothing is cached between queries** except the catalog: no decoded
   tables, results or extra indexes.

## Complexity

SELECT is O(N·C + R log R) plus any overflow pages read; COUNT is O(pages of the
table); INDEX is O(d·log F + K) to find the entries plus O(K·d·log F) to fetch
the rows. Parsing a query is linear in its length.
