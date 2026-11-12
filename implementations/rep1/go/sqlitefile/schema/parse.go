// Package schema parses the CREATE TABLE and CREATE INDEX statements stored in
// sqlite_schema and builds a catalog of the tables and indexes in a database.
package schema

import (
	"errors"
	"strings"

	"sqlitefile/value"
)

// ErrSyntax is returned for a CREATE statement that cannot be understood.
var ErrSyntax = errors.New("schema: cannot parse CREATE statement")

// Column describes one column of a table.
type Column struct {
	Name     string
	Type     string // declared type, tokens joined by single spaces; may be empty
	Affinity value.Affinity
	RowidPK  bool // the column is an alias for the rowid
}

// TableDef is the parsed form of a CREATE TABLE statement.
type TableDef struct {
	Columns []Column
}

// RowidAlias returns the index of the column that aliases the rowid, or -1.
func (t *TableDef) RowidAlias() int {
	for i, c := range t.Columns {
		if c.RowidPK {
			return i
		}
	}
	return -1
}

// ColumnIndex finds a column by name, ASCII case-insensitively. It returns -1
// when there is no such column.
func (t *TableDef) ColumnIndex(name string) int {
	for i, c := range t.Columns {
		if EqualFold(c.Name, name) {
			return i
		}
	}
	return -1
}

// IndexDef is the parsed form of a CREATE INDEX statement.
type IndexDef struct {
	Columns []string // indexed column names (or expression text's first token)
}

// EqualFold compares two names ASCII case-insensitively.
func EqualFold(a, b string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := 0; i < len(a); i++ {
		x, y := a[i], b[i]
		if 'A' <= x && x <= 'Z' {
			x += 'a' - 'A'
		}
		if 'A' <= y && y <= 'Z' {
			y += 'a' - 'A'
		}
		if x != y {
			return false
		}
	}
	return true
}

var typeStopWords = []string{
	"CONSTRAINT", "PRIMARY", "NOT", "NULL", "UNIQUE", "CHECK", "DEFAULT",
	"COLLATE", "REFERENCES", "GENERATED", "AS", "AUTOINCREMENT",
}

func isTypeStop(t token) bool {
	for _, k := range typeStopWords {
		if t.isKeyword(k) {
			return true
		}
	}
	return false
}

// splitTopLevel splits toks at commas at parenthesis depth 0.
func splitTopLevel(toks []token) [][]token {
	var items [][]token
	depth, start := 0, 0
	for i, t := range toks {
		switch {
		case t.isPunct('('):
			depth++
		case t.isPunct(')'):
			depth--
		case t.isPunct(',') && depth == 0:
			items = append(items, toks[start:i])
			start = i + 1
		}
	}
	return append(items, toks[start:])
}

// parenBody returns the tokens between the first "(" at or after from and its
// matching ")", and the index just past that ")".
func parenBody(toks []token, from int) ([]token, int, bool) {
	i := from
	for i < len(toks) && !toks[i].isPunct('(') {
		i++
	}
	if i == len(toks) {
		return nil, 0, false
	}
	depth := 0
	for j := i; j < len(toks); j++ {
		switch {
		case toks[j].isPunct('('):
			depth++
		case toks[j].isPunct(')'):
			depth--
			if depth == 0 {
				return toks[i+1 : j], j + 1, true
			}
		}
	}
	return toks[i+1:], len(toks), true // unterminated: take the rest
}

// ParseTable parses a CREATE TABLE statement.
func ParseTable(sql string) (*TableDef, error) {
	toks := tokenize(sql)
	if len(toks) == 0 || !toks[0].isKeyword("CREATE") {
		return nil, ErrSyntax
	}
	i := 1
	if i < len(toks) && (toks[i].isKeyword("TEMP") || toks[i].isKeyword("TEMPORARY")) {
		i++
	}
	if i >= len(toks) || !toks[i].isKeyword("TABLE") {
		return nil, ErrSyntax
	}
	body, _, ok := parenBody(toks, i+1)
	if !ok {
		return nil, ErrSyntax
	}

	def := &TableDef{}
	var pkCols [][]token // table-level PRIMARY KEY column lists
	pkColumn := -1       // column-level PRIMARY KEY (non-DESC)

	for _, item := range splitTopLevel(body) {
		if len(item) == 0 {
			continue
		}
		first := item[0]
		if first.isKeyword("CONSTRAINT") || first.isKeyword("PRIMARY") || first.isKeyword("UNIQUE") ||
			first.isKeyword("CHECK") || first.isKeyword("FOREIGN") {
			if cols, ok := tablePrimaryKey(item); ok {
				pkCols = append(pkCols, cols)
			}
			continue
		}
		if !first.isName() {
			return nil, ErrSyntax
		}
		col := Column{Name: first.text}
		j := 1
		var typ []string
		for j < len(item) && !isTypeStop(item[j]) {
			typ = append(typ, item[j].text)
			j++
		}
		col.Type = strings.Join(typ, " ")
		col.Affinity = value.AffinityOf(col.Type)
		intType := len(typ) == 1 && item[1].isName() && strings.EqualFold(typ[0], "INTEGER")

		depth := 0
		for ; j < len(item); j++ {
			switch {
			case item[j].isPunct('('):
				depth++
			case item[j].isPunct(')'):
				depth--
			case depth == 0 && item[j].isKeyword("PRIMARY") && j+1 < len(item) && item[j+1].isKeyword("KEY"):
				desc := j+2 < len(item) && item[j+2].isKeyword("DESC")
				if intType && !desc {
					pkColumn = len(def.Columns)
				}
			}
		}
		def.Columns = append(def.Columns, col)
	}

	alias := pkColumn
	if alias < 0 && len(pkCols) == 1 && len(pkCols[0]) == 1 {
		// A table-level PRIMARY KEY on one INTEGER column aliases the rowid
		// whether or not the column is marked DESC.
		if idx := def.ColumnIndex(pkCols[0][0].text); idx >= 0 &&
			strings.EqualFold(def.Columns[idx].Type, "INTEGER") {
			alias = idx
		}
	}
	if alias >= 0 {
		def.Columns[alias].RowidPK = true
		def.Columns[alias].Affinity = value.AffinityInteger
	}
	return def, nil
}

// tablePrimaryKey recognises [CONSTRAINT name] PRIMARY KEY ( col ... ) and
// returns the column name tokens (only the first token of each column).
func tablePrimaryKey(item []token) ([]token, bool) {
	i := 0
	if item[0].isKeyword("CONSTRAINT") {
		i = 2
	}
	if i+1 >= len(item) || !item[i].isKeyword("PRIMARY") || !item[i+1].isKeyword("KEY") {
		return nil, false
	}
	body, _, ok := parenBody(item, i+2)
	if !ok {
		return nil, false
	}
	var cols []token
	for _, c := range splitTopLevel(body) {
		if len(c) == 0 || !c[0].isName() {
			return nil, false
		}
		cols = append(cols, c[0])
	}
	return cols, true
}

// ParseIndex parses a CREATE INDEX statement and returns its indexed columns.
func ParseIndex(sql string) (*IndexDef, error) {
	toks := tokenize(sql)
	i := 0
	if i >= len(toks) || !toks[i].isKeyword("CREATE") {
		return nil, ErrSyntax
	}
	i++
	if i < len(toks) && toks[i].isKeyword("UNIQUE") {
		i++
	}
	// Skip to the ON keyword that follows the index name.
	for ; i < len(toks) && !toks[i].isKeyword("ON"); i++ {
	}
	if i >= len(toks) {
		return nil, ErrSyntax
	}
	body, _, ok := parenBody(toks, i+1)
	if !ok {
		return nil, ErrSyntax
	}
	def := &IndexDef{}
	for _, c := range splitTopLevel(body) {
		if len(c) == 0 || !c[0].isName() {
			return nil, ErrSyntax
		}
		def.Columns = append(def.Columns, c[0].text)
	}
	return def, nil
}
