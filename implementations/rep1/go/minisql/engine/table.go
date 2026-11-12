// Package engine implements the minisql database: tables, binding of parsed
// statements against the schema, and their execution.
package engine

import (
	"errors"
	"fmt"
	"strings"

	"minisql/syntax"
	"minisql/value"
)

// Table is a named list of columns and its rows in insertion order.
type Table struct {
	Name    string
	Columns []string // lower-case column names
	Rows    [][]value.Value
}

func (t *Table) columnIndex(name string) int {
	for i, c := range t.Columns {
		if c == name {
			return i
		}
	}
	return -1
}

// Result is the output of a SELECT.
type Result struct {
	Rows [][]value.Value
}

// Database is an in-memory collection of tables. The zero value is not
// usable; create one with New.
type Database struct {
	tables map[string]*Table
}

// New returns an empty database.
func New() *Database {
	return &Database{tables: make(map[string]*Table)}
}

// Table returns the named table (case-insensitively), or nil.
func (db *Database) Table(name string) *Table {
	return db.tables[strings.ToLower(name)]
}

// Error is a semantic error found while binding or executing a statement.
type Error struct{ Msg string }

func (e *Error) Error() string { return e.Msg }

func errorf(format string, args ...any) error {
	return &Error{fmt.Sprintf(format, args...)}
}

// Exec binds and executes one parsed statement. A failing statement leaves
// the database unchanged. SELECT returns its rows; every other statement
// returns a nil Result.
func (db *Database) Exec(stmt syntax.Stmt) (*Result, error) {
	switch s := stmt.(type) {
	case *syntax.CreateTable:
		return nil, db.execCreate(s)
	case *syntax.Insert:
		return nil, db.execInsert(s)
	case *syntax.Delete:
		return nil, db.execDelete(s)
	case *syntax.Update:
		return nil, db.execUpdate(s)
	case *syntax.Select:
		return db.execSelect(s)
	}
	return nil, errors.New("unsupported statement")
}

func (db *Database) lookup(name string) (*Table, error) {
	t := db.tables[name]
	if t == nil {
		return nil, errorf("no such table: %s", name)
	}
	return t, nil
}
