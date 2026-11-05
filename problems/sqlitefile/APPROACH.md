# sqlitefile — required approach

SPEC.md defines what the program does. This note defines how it is built. Where
the two seem to disagree, SPEC.md wins.

## Overall approach

Read the whole database file into one in-memory buffer at startup, then read
`sqlite_schema` once and parse every `CREATE TABLE` / `CREATE INDEX` into a
catalog that all queries share. Every page access is an offset or slice into
that buffer. Each query line is parsed by a hand-written scanner, resolved
against the catalog (columns become indices, literals get affinity applied),
then executed. `SELECT` and `COUNT` walk the table B-tree in rowid order.
`SELECT` tests each row's WHERE columns straight from the record bytes and
only builds values for rows that match. `INDEX` does a key-directed descent of
the index B-tree followed by one rowid descent of the table B-tree per match.
Each query's output is built in one buffer and written to its result file with
a single write.

Sizes below: `N` is the rows in the scanned table, `C` its column count, `R`
the rows that match WHERE, `K` the index entries equal to the key, `d` the
B-tree depth and `F` the cells per page.

## Required choices

1. **Whole file in memory, pages never copied.** Read the file with one bulk
   read (mapping it is also fine). A page is a base offset into the buffer or
   a slice/view of it. Cell pointers, varints and big-endian fields are decoded
   in place. Never copy a page into a new buffer, and never build a per-page
   object that allocates.
2. **Schema read once.** At startup, walk the page-1 B-tree once. Keep the
   rows in schema order (for `.schema`) and parse each `CREATE TABLE` and
   `CREATE INDEX` once into column names, affinities, rowid-alias position and
   index column lists. Queries look objects up in this catalog. No query
   re-reads `sqlite_schema` or re-parses DDL.
3. **Payload access without copying, O(local) or O(P).** Compute the local
   size from SPEC 1.5. When the whole payload is local (almost always), the
   record is a view into the page. Only when it overflows, concatenate the
   local bytes and the chain into a scratch buffer reused across cells, and
   copy out of it only the values a matching row keeps.
4. **Record decoding is header-first and lazy.** For each cell, read the
   serial types in the record header into a small reusable array of
   (serial type, body offset), O(C) with no allocation. A column value is
   decoded only when it is needed, directly from its offset. Missing trailing
   columns read as NULL, and the rowid alias and the REAL widening of SPEC 2.4
   are applied when a value is read, not in a second pass over the row. TEXT
   and BLOB values are byte views. They are not copied, decoded to code points
   or checked as UTF-8. Where the language cannot compare a view without
   slicing out a copy, copying the single value a condition
   or sort key needs is acceptable, but never every column of the row.
5. **SELECT is one full table scan, O(N·C + R log R).** Walk the table B-tree
   in order (recursive or with an explicit stack). For each row, evaluate the
   WHERE conditions in order, decoding only the column each one names and
   stopping at the first false one. Rows that fail cost no heap allocation
   (beyond any boxing the language runtime itself performs). Without ORDER BY, format
   each matching row straight into the output buffer as it is found, and stop
   the walk as soon as `LIMIT` rows have matched. With ORDER BY, extract the
   key once plus the selected values (views, copied out only when they point
   into the reused overflow buffer), append them to the result list, and
   format only the rows that survive LIMIT after the sort; never format a row
   that LIMIT then drops. SELECT never uses an index and never uses a rowid
   seek, even when WHERE would allow one.
6. **Query preparation happens once per query, not per row.** Resolve column
   names to indices (or the rowid marker), apply column affinity to each
   literal (SPEC Part 3), and turn TEXT/BLOB literals into byte strings, all
   before the scan starts. Per-row work is: decode a value, then compare it.
7. **One comparison function, no allocation.** A three-way compare
   implementing SPEC Part 3: storage-class rank, then exact int64 compare,
   double compare for mixed numbers, and unsigned bytewise compare
   (memcmp-style) for TEXT and BLOB. Conditions, sorting and index search all
   use it.
8. **ORDER BY is one stable sort over precomputed keys, O(R log R).** Sort the
   matched rows by their stored key. DESC negates the key comparison rather
   than reversing an ascending result, so rowid ties stay ascending. Either use
   a stable sort (rows arrive in rowid order) or compare (key, rowid)
   explicitly. Always sort all matched rows, then apply LIMIT by truncation.
9. **COUNT reads no payloads, O(pages of the table).** Walk the interior
   pages and add up the leaf cell counts from the page headers.
10. **INDEX is a key-directed descent, O(d·log F + K + pages holding the run),
    then O(K·d·log F) for the rows.** On each index page, binary search the
    cells for the first one whose first column is `>=` the key. Compare by
    decoding only the first column of the cell's record. Descend into that
    cell's left child (or the right-most child if every cell is smaller), and
    walk in order from there, emitting each equal entry's rowid (its last
    record column, read from the header offsets) and including interior cells'
    own entries. Stop at the first entry greater than the key. Then fetch each
    row with a rowid descent: binary search on interior-cell keys and on leaf
    cells' rowids. The rowids of equal keys are already ascending; sorting and
    de-duplicating them is allowed. A NULL key returns at once.
11. **Output is formatted straight into a byte buffer.** Integers use a digit
    loop or an allocation-free integer formatter. REAL uses one `%.15g`-style
    conversion into a scratch buffer, plus SPEC Part 5's `.0` and `-0.0` fixes.
    TEXT bytes are copied as they are. BLOBs go through a 16-entry hex table.
    Tabs and newlines are appended directly. Do not build a string per value
    and then join. Each query's buffer is written to `NNN.txt` with one
    create/write/close. An error discards the buffer and writes `error\n`.
12. **Query parsing is a single pass over the line, O(line length).** Scan
    the line with a hand-written cursor and case-insensitive keyword
    comparison. No regular expressions and no per-token upper-casing copies.
    No parsed query or result is cached between lines.

## Left to the implementer

- Container types, struct layout, naming, module structure, and whether pages
  are passed as offsets, slices or small value structs.
- Recursion or an explicit stack for B-tree walks, and visitor callbacks,
  iterators or inline loops for delivering rows.
- The representation of values (tagged struct, sum type, interface, the
  language's native objects) as long as TEXT/BLOB stay views or are copied only for
  matched rows.
- How errors propagate (exceptions, result types, panics with recovery).
  Errors are rare.
- Name lookup in the catalog (hash map or linear search over the few schema
  rows) and other micro-optimisations: bounds-check elimination, inlining,
  specialising the comparison per literal type.

## Pitfalls

- Materialising every row of the table (all columns, for every row) into a
  list and only then filtering. This allocates on the order of N·C values per
  query and dominates full-scan time.
- Allocating per scanned row: a new serial-type array, a new value array, a
  second array after alias and REAL fix-ups, appending to arrays without
  reserving, or copying every TEXT/BLOB column into an owned string
  (including lossy or validating UTF-8 conversion) for rows that are then
  rejected.
- Copying each cell's payload into a fresh buffer even when it is entirely
  local, or slicing a page out of the file as a copy on every access. In
  languages where slicing a byte string copies, use offsets or a zero-copy
  view instead.
- Decoding whole index records (with allocation) at every cell visited during
  an index search, or scanning index pages linearly from the first cell
  instead of binary searching. Walking the entire index, or scanning the
  table for `INDEX`, turns a point lookup into a full read.
- Linear scans of interior-cell keys during rowid seeks repeated for every
  matched index entry.
- Re-parsing `CREATE TABLE`/`CREATE INDEX` or re-walking `sqlite_schema` for
  every query. With hundreds of small queries this is a large share of the
  cost.
- COUNT that decodes records or follows overflow chains.
- Re-extracting the sort column, or re-resolving column names, inside the sort
  comparator. Building a fresh value object per comparison.
- Formatting every matched row of an ORDER BY query when LIMIT keeps only a
  few of them.
- Formatting with a generic formatted-print call per integer, building a
  string per value and joining them, or flushing a writer per line.
- Caching decoded tables, query results or extra indexes across queries, or
  using an index to answer SELECT. This changes the work being measured.
- Discovering rows by scanning the file for leaf pages. This is wrong because
  of freelist pages, not just slow.
