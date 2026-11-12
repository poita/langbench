# sqlitefile

A small C++20 library and command-line tool that reads a SQLite 3 database
file **directly, byte by byte**, and answers a handful of queries against it.
It does not use SQLite or any other code that understands the format: the
pager, B-tree walker, record decoder, `CREATE TABLE`/`CREATE INDEX` parser and
query evaluator are all in this repository, and only the C++ standard library
is used (GoogleTest is used for the tests).

Supported: table and index B-trees, payload overflow chains, rowid aliases
(`INTEGER PRIMARY KEY`), column affinity, UTF-8 databases, any page size from
512 to 65536. Not supported: `WITHOUT ROWID`, UTF-16 databases, auto-vacuum
pointer-map pages, writing.

## Build

Requires a C++20 compiler and CMake 3.20+. The unit tests need GoogleTest
(they are skipped with a warning if `find_package(GTest)` fails; pass
`-DSQLITEFILE_BUILD_TESTS=OFF` to skip them explicitly).

```sh
./build.sh                      # Release build into ./build
# or by hand:
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release && cmake --build build
ctest --test-dir build          # run the unit tests
```

## Command-line tool

```
run.sh <input directory> <output directory>
```

The input directory holds exactly one `*.sqlite` file and `queries.txt` with one
query per line. For the *n*-th query the tool writes `NNN.txt` (`001.txt`, …)
into the (existing) output directory. A query that fails writes the single
line `error`; the exit status is still 0.

| query | output |
|-------|--------|
| `.tables` | user tables, one per line, sorted bytewise |
| `.schema <table>` | the `CREATE` statements of that table (table, indexes, triggers) in schema order, each followed by `;` |
| `COUNT <table>` | row count |
| `SELECT <cols or *> FROM <table> [WHERE <col> <op> <literal> [AND ...]] [ORDER BY <col> [ASC\|DESC]] [LIMIT n]` | tab-separated rows; ties in `ORDER BY` break by ascending rowid; `<op>` is one of `= != < <= > >= IS` or `IS NOT`; `rowid` is a valid column name |
| `INDEX <index> <literal>` | rows found by a point lookup through a single-column index |

Values print like the `sqlite3` shell with `-nullvalue NULL`: blobs as upper-case
hex, REALs with 15 significant digits and always a `.` or exponent (`1.0`,
`1.0e+300`). The full contract is in `problems/sqlitefile/SPEC.md`.

## Library

The public headers live in `include/sqlitefile/` (`sqlitefile.hpp` includes
them all); the library is the CMake target `sqlitefile::sqlitefile`.

| module | responsibility |
|--------|----------------|
| `value.hpp` | `Value`, the SQLite ordering (`compare`), affinity, numeric-text parsing, output formatting |
| `record.hpp` | varints, record decoding (`decodeRecord`) |
| `pager.hpp` | the file in memory, the database header, page access |
| `btree.hpp` | table scan / count / rowid search, index equality search, overflow chains |
| `ddl.hpp` | `CREATE TABLE` / `CREATE INDEX` parsing: columns, affinities, rowid alias |
| `schema.hpp` | `Catalog`: `sqlite_schema` rows plus parsed tables and indexes |
| `query.hpp` | the query language parser (`parseQuery`) |
| `database.hpp` | `Database`, the facade that executes queries |

Errors are reported with exceptions derived from `sqlitefile::Error`:
`QueryError` for a bad or unresolvable query and `FormatError` for a file that
is malformed.

### Example

```cpp
#include <iostream>
#include "sqlitefile/sqlitefile.hpp"

int main() {
  using namespace sqlitefile;
  Database db = Database::open("people.sqlite");

  // High level: run a query line, get the text the CLI would write.
  try {
    std::cout << db.run("SELECT name,age FROM people WHERE age >= 40 ORDER BY age DESC");
  } catch (const QueryError& e) {
    std::cout << "error\n";
  }

  // Lower level: walk a table B-tree and decode records yourself.
  if (const TableInfo* t = db.catalog().findTable("people")) {
    BTreeReader reader(db.pager());
    reader.scanTable(t->root_page, [&](std::int64_t rowid, const Payload& payload) {
      std::vector<Value> row = decodeRecord(payload.bytes());
      std::cout << rowid << ": " << format(row.at(1)) << "\n";
      return true;  // keep going
    });
  }
}
```

Link with `target_link_libraries(app PRIVATE sqlitefile::sqlitefile)`.

## Design notes

* The schema is read once when a `Database` is opened; nothing else is cached
  between queries.
* `SELECT` always scans the table B-tree in rowid order (stopping early at
  `LIMIT` when there is no `ORDER BY`); with `ORDER BY` every matching row is
  stably sorted before `LIMIT` is applied. `COUNT` only sums leaf-page cell
  counts. `INDEX` descends the index B-tree (interior cells hold entries too),
  then fetches rows by rowid search.
* B-tree depth is capped, payload sizes and overflow chains are validated, so a
  corrupt file raises `FormatError` instead of crashing.

## Tests

`tests/` contains GoogleTest suites for each module. They build their database
images in memory with `tests/support/db_builder.*`, a small independent writer
of the file format (multi-level trees, overflow chains, negative rowids), plus an
end-to-end test of the CLI. Run them with `ctest --test-dir build`. The
problem's own corpus is run with `python3 run_tests.py sqlitefile -- sqlitefile/run.sh`
from the repository root.
