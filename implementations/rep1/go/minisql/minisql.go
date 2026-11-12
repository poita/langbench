// Package minisql is a small in-memory relational database that executes a
// subset of SQL (CREATE TABLE, INSERT, UPDATE, DELETE and SELECT with joins,
// grouping, aggregates, ordering and limits).
//
// Typical use:
//
//	db := minisql.New()
//	if _, err := db.Exec("CREATE TABLE t (a INTEGER, b TEXT)"); err != nil { ... }
//	db.Exec("INSERT INTO t VALUES (1, 'x'), (2, 'y')")
//	res, err := db.Exec("SELECT b FROM t WHERE a > 1")
//
// To run a whole script and render its results in the command-line format,
// use DB.RunScript.
//
// The implementation lives in three sub-packages: value (dynamic values and
// their ordering), syntax (lexer, AST, parser) and engine (binding and
// execution).
package minisql

import (
	"bufio"
	"errors"
	"io"
	"strconv"

	"minisql/engine"
	"minisql/syntax"
	"minisql/value"
)

// Value is a dynamically typed SQL value (NULL, INTEGER, TEXT or REAL).
type Value = value.Value

// Result holds the rows produced by a SELECT, in result order.
type Result = engine.Result

// ErrNotOneStatement is returned by DB.Exec when its argument does not hold
// exactly one statement.
var ErrNotOneStatement = errors.New("minisql: expected exactly one statement")

// DB is an in-memory database. Use New to create one. A DB is not safe for
// concurrent use.
type DB struct {
	eng *engine.Database
}

// New returns an empty database.
func New() *DB { return &DB{eng: engine.New()} }

// Outcome is the result of one statement of a script: the rows of a SELECT
// (nil for other statements) or the error that made the statement fail.
type Outcome struct {
	Result *Result
	Err    error
}

// Exec parses and executes exactly one SQL statement (a trailing ';' is
// optional). It returns the rows of a SELECT, or a nil Result for any other
// statement. A failing statement leaves the database unchanged.
func (d *DB) Exec(sql string) (*Result, error) {
	parsed := syntax.ParseScript(sql)
	if len(parsed) != 1 {
		return nil, ErrNotOneStatement
	}
	if parsed[0].Err != nil {
		return nil, parsed[0].Err
	}
	return d.eng.Exec(parsed[0].Stmt)
}

// ExecScript executes every statement of script in order and returns one
// Outcome per (non-empty) statement. A failing statement does not stop the
// script.
func (d *DB) ExecScript(script string) []Outcome {
	parsed := syntax.ParseScript(script)
	out := make([]Outcome, len(parsed))
	for i, p := range parsed {
		if p.Err != nil {
			out[i].Err = p.Err
			continue
		}
		out[i].Result, out[i].Err = d.eng.Exec(p.Stmt)
	}
	return out
}

// RunScript executes script and writes the output defined by the command-line
// contract to w: for each SELECT one tab-separated line per row followed by
// "-- N rows", and for each failing statement the single line "error".
// It returns the first write error, if any.
func (d *DB) RunScript(script string, w io.Writer) error {
	bw := bufio.NewWriter(w)
	for _, o := range d.ExecScript(script) {
		switch {
		case o.Err != nil:
			bw.WriteString("error\n")
		case o.Result != nil:
			WriteResult(bw, o.Result)
		}
	}
	return bw.Flush()
}

// WriteResult writes res in the command-line format: one line per row with
// tab-separated values, then a line "-- N rows".
func WriteResult(w *bufio.Writer, res *Result) {
	for _, row := range res.Rows {
		for i, v := range row {
			if i > 0 {
				w.WriteByte('\t')
			}
			w.WriteString(v.String())
		}
		w.WriteByte('\n')
	}
	w.WriteString("-- ")
	w.WriteString(strconv.Itoa(len(res.Rows)))
	w.WriteString(" rows\n")
}
