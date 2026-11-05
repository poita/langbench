package minisql

import (
	"bytes"
	"io"
)

// Table is a named table: an ordered column list and rows in insertion order.
type Table struct {
	name  string
	cols  []string // lower-cased column names
	types []string // "integer" or "text"; declarative only
	rows  [][]Value
}

func (t *Table) colIndex(name string) int {
	for i, c := range t.cols {
		if c == name {
			return i
		}
	}
	return -1
}

// Result is the outcome of a successful SELECT. Statements that return no
// rows (CREATE, INSERT, UPDATE, DELETE) yield a nil *Result.
type Result struct {
	Rows [][]Value
}

// DB is an in-memory database. The zero value is not usable; call New.
// A DB is not safe for concurrent use.
type DB struct {
	tables map[string]*Table // keyed by lower-cased name
}

// New returns an empty database.
func New() *DB { return &DB{tables: map[string]*Table{}} }

// Outcome is the result of one statement of a script: a non-nil Err, or a
// Result for a SELECT, or neither for other statements.
type Outcome struct {
	Result *Result
	Err    error
}

// Exec executes a single statement (an optional trailing ';' is allowed).
// On error the database is unchanged. It returns a nil Result for statements
// that produce no rows.
func (db *DB) Exec(sql string) (*Result, error) {
	stmts := splitStatements(tokenize(sql))
	if len(stmts) != 1 {
		return nil, &Error{SyntaxError, "expected exactly one statement"}
	}
	return db.execTokens(stmts[0])
}

// ExecScript executes every statement of script in order and returns one
// Outcome per statement. A failing statement does not stop the script.
func (db *DB) ExecScript(script string) []Outcome {
	var outs []Outcome
	for _, st := range splitStatements(tokenize(script)) {
		r, err := db.execTokens(st)
		outs = append(outs, Outcome{r, err})
	}
	return outs
}

// RunScript executes script as the command-line tool does and writes the
// output to w: each SELECT prints its rows (tab-separated, NULL as "NULL")
// followed by "-- N rows"; each failing statement prints "error".
func (db *DB) RunScript(script string, w io.Writer) error {
	var out []byte
	for _, st := range splitStatements(tokenize(script)) {
		r, err := db.execTokens(st)
		switch {
		case err != nil:
			out = append(out, "error\n"...)
		case r != nil:
			out = r.AppendTo(out)
		}
	}
	_, err := io.Copy(w, bytes.NewReader(out))
	return err
}

// execTokens parses, binds and executes one statement. Parsing and binding
// signal errors by panicking with *Error; execution cannot fail.
func (db *DB) execTokens(toks []token) (res *Result, err error) {
	defer func() {
		if r := recover(); r != nil {
			e, ok := r.(*Error)
			if !ok {
				panic(r)
			}
			res, err = nil, e
		}
	}()
	switch s := parseStatement(toks).(type) {
	case *createStmt:
		db.execCreate(s)
	case *insertStmt:
		db.execInsert(db.bindInsert(s))
	case *deleteStmt:
		db.execDelete(db.bindDelete(s))
	case *updateStmt:
		db.execUpdate(db.bindUpdate(s))
	case *selectStmt:
		return db.execSelect(db.bindSelect(s)), nil
	}
	return nil, nil
}
