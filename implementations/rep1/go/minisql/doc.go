// Package minisql is a small in-memory relational database that executes a
// strict subset of SQLite's SQL dialect.
//
// Supported statements are CREATE TABLE, INSERT, UPDATE, DELETE and SELECT
// (with comma/INNER joins of up to two tables, WHERE, GROUP BY, HAVING,
// ORDER BY, LIMIT and OFFSET, and the aggregates COUNT, SUM, MIN, MAX and
// AVG). Values are dynamically typed NULL, INTEGER, TEXT (and REAL, produced
// only by AVG).
//
// Each statement goes through three phases: it is parsed into an AST, bound
// against the current schema (names resolved, semantic checks performed), and
// then executed. Binding finishes before any table is touched, so a failing
// statement never changes the database.
//
// Typical use:
//
//	db := minisql.New()
//	res, err := db.Exec("SELECT 1 + 1")
//
// or, to process a whole script exactly as the command-line tool does:
//
//	err := db.RunScript(script, os.Stdout)
//
// Source layout: value.go (values and ordering), lexer.go, ast.go, parser.go,
// bind.go (name resolution and checks), eval.go and like.go (expression
// evaluation), select.go and dml.go (execution), db.go (public API) and
// output.go (result formatting).
package minisql
