// Package sqlitefile reads SQLite 3 database files directly, without any
// SQLite library, and answers a small set of queries against them.
//
// The library is layered by responsibility:
//
//   - package value: storage classes, ordering, type affinity and output format
//   - package record: varints and the record (row) encoding
//   - package btree: the pager, B-tree pages, overflow chains, scans and searches
//   - package schema: CREATE TABLE / CREATE INDEX parsing and the schema catalog
//   - package query: the query-language parser
//
// This package ties them together: Open a database, then Exec query lines.
//
//	db, err := sqlitefile.Open("people.sqlite")
//	if err != nil { ... }
//	lines, err := db.Exec("SELECT name FROM people WHERE age > 40 ORDER BY name")
//
// The supported queries are ".tables", ".schema <table>", "COUNT <table>",
// "SELECT <cols> FROM <table> [WHERE ...] [ORDER BY col [ASC|DESC]] [LIMIT n]"
// and "INDEX <index> <literal>"; see the README for details.
package sqlitefile
