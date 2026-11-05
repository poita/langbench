package sqlitefile

import (
	"errors"
	"strings"
)

var errDDL = errors.New("sqlitefile: cannot parse CREATE statement")

type tokKind uint8

const (
	tokWord   tokKind = iota // unquoted run of [A-Za-z0-9_$] (and non-ASCII bytes)
	tokQuoted                // "x", `x` or [x]; text holds the unquoted name
	tokString                // 'x' string literal
	tokPunct                 // any other single character
)

type token struct {
	kind tokKind
	text string
}

// is reports whether t is the unquoted word kw (kw must be upper case).
func (t token) is(kw string) bool {
	return t.kind == tokWord && strings.EqualFold(t.text, kw)
}

func (t token) isPunct(c byte) bool {
	return t.kind == tokPunct && t.text[0] == c
}

func isWordByte(c byte) bool {
	return c == '_' || c == '$' || c >= 0x80 || isDigit(c) || (c|0x20 >= 'a' && c|0x20 <= 'z')
}

// tokenize splits DDL text into tokens, dropping whitespace and comments.
func tokenize(s string) ([]token, error) {
	var toks []token
	for i := 0; i < len(s); {
		c := s[i]
		switch {
		case c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\f' || c == '\v':
			i++
		case c == '-' && i+1 < len(s) && s[i+1] == '-':
			for i < len(s) && s[i] != '\n' {
				i++
			}
		case c == '/' && i+1 < len(s) && s[i+1] == '*':
			end := strings.Index(s[i+2:], "*/")
			if end < 0 {
				i = len(s)
			} else {
				i += end + 4
			}
		case isWordByte(c):
			j := i
			for j < len(s) && isWordByte(s[j]) {
				j++
			}
			toks = append(toks, token{tokWord, s[i:j]})
			i = j
		case c == '"' || c == '`' || c == '\'':
			var sb strings.Builder
			j := i + 1
			closed := false
			for j < len(s) {
				if s[j] == c {
					if j+1 < len(s) && s[j+1] == c {
						sb.WriteByte(c)
						j += 2
						continue
					}
					closed = true
					j++
					break
				}
				sb.WriteByte(s[j])
				j++
			}
			if !closed {
				return nil, errDDL
			}
			kind := tokQuoted
			if c == '\'' {
				kind = tokString
			}
			toks = append(toks, token{kind, sb.String()})
			i = j
		case c == '[':
			end := strings.IndexByte(s[i:], ']')
			if end < 0 {
				return nil, errDDL
			}
			toks = append(toks, token{tokQuoted, s[i+1 : i+end]})
			i += end + 1
		default:
			toks = append(toks, token{tokPunct, string(c)})
			i++
		}
	}
	return toks, nil
}

// Column describes one column of a table.
type Column struct {
	Name     string
	Type     string   // declared type, "" if none
	Affinity Affinity // derived from Type
}

// Table describes a rowid table found in the schema.
type Table struct {
	Name       string
	Root       uint32
	SQL        string
	Columns    []Column
	RowidAlias int // index of the column aliasing the rowid, or -1
	err        error
}

// Index describes an index created by an explicit CREATE INDEX statement.
type Index struct {
	Name    string
	Table   string
	Root    uint32
	SQL     string
	Unique  bool
	Columns []string
}

// ColumnIndex resolves a column name (ASCII case-insensitive) to its position.
func (t *Table) ColumnIndex(name string) int {
	for i, c := range t.Columns {
		if strings.EqualFold(c.Name, name) {
			return i
		}
	}
	return -1
}

// tableKeywords end a column's declared type.
var typeTerminators = map[string]bool{
	"CONSTRAINT": true, "PRIMARY": true, "NOT": true, "NULL": true, "UNIQUE": true,
	"CHECK": true, "DEFAULT": true, "COLLATE": true, "REFERENCES": true,
	"GENERATED": true, "AS": true, "AUTOINCREMENT": true,
}

// ParseCreateTable parses the column list and rowid alias out of a CREATE
// TABLE statement. Name and Root are left for the caller to fill in.
func ParseCreateTable(sql string) (*Table, error) {
	toks, err := tokenize(sql)
	if err != nil {
		return nil, err
	}
	i := 0
	if i >= len(toks) || !toks[i].is("CREATE") {
		return nil, errDDL
	}
	i++
	if i < len(toks) && (toks[i].is("TEMP") || toks[i].is("TEMPORARY")) {
		i++
	}
	if i >= len(toks) || !toks[i].is("TABLE") {
		return nil, errDDL
	}
	i++
	if i+2 < len(toks) && toks[i].is("IF") && toks[i+1].is("NOT") && toks[i+2].is("EXISTS") {
		i += 3
	}
	i, name, err := parseQualifiedName(toks, i)
	if err != nil {
		return nil, err
	}
	if i >= len(toks) || !toks[i].isPunct('(') {
		return nil, errDDL
	}
	items, err := splitItems(toks[i+1:])
	if err != nil {
		return nil, err
	}
	t := &Table{Name: name, RowidAlias: -1}
	pkCol := -1   // column carrying a column-level PRIMARY KEY (not DESC)
	pkTable := "" // sole column of a table-level PRIMARY KEY
	pkTableSet := false
	for _, it := range items {
		if len(it) == 0 {
			return nil, errDDL
		}
		if isConstraintStart(it[0]) {
			if col, ok := tablePrimaryKey(it); ok {
				pkTable, pkTableSet = col, true
			}
			continue
		}
		col, rest := splitColumn(it)
		if col.Name == "" {
			return nil, errDDL
		}
		col.Affinity = AffinityOf(col.Type)
		if hasColumnPrimaryKey(rest) {
			pkCol = len(t.Columns)
		}
		t.Columns = append(t.Columns, col)
	}
	if len(t.Columns) == 0 {
		return nil, errDDL
	}
	switch {
	case pkCol >= 0:
		if strings.EqualFold(t.Columns[pkCol].Type, "INTEGER") {
			t.RowidAlias = pkCol
		}
	case pkTableSet:
		if ci := t.ColumnIndex(pkTable); ci >= 0 && strings.EqualFold(t.Columns[ci].Type, "INTEGER") {
			t.RowidAlias = ci
		}
	}
	return t, nil
}

func parseQualifiedName(toks []token, i int) (int, string, error) {
	if i >= len(toks) || (toks[i].kind != tokWord && toks[i].kind != tokQuoted) {
		return 0, "", errDDL
	}
	name := toks[i].text
	i++
	if i+1 < len(toks) && toks[i].isPunct('.') {
		if toks[i+1].kind != tokWord && toks[i+1].kind != tokQuoted {
			return 0, "", errDDL
		}
		name = toks[i+1].text
		i += 2
	}
	return i, name, nil
}

// splitItems splits the tokens after the opening parenthesis at depth-0 commas,
// stopping at the matching close parenthesis.
func splitItems(toks []token) ([][]token, error) {
	var items [][]token
	var cur []token
	depth := 0
	for _, t := range toks {
		if t.kind == tokPunct {
			switch t.text[0] {
			case '(':
				depth++
			case ')':
				if depth == 0 {
					return append(items, cur), nil
				}
				depth--
			case ',':
				if depth == 0 {
					items = append(items, cur)
					cur = nil
					continue
				}
			}
		}
		cur = append(cur, t)
	}
	return nil, errDDL
}

func isConstraintStart(t token) bool {
	return t.is("CONSTRAINT") || t.is("PRIMARY") || t.is("UNIQUE") || t.is("CHECK") || t.is("FOREIGN")
}

// splitColumn separates a column definition into name/type and the remaining
// constraint tokens.
func splitColumn(it []token) (Column, []token) {
	col := Column{Name: it[0].text}
	i := 1
	var typ []string
	for i < len(it) {
		if it[i].kind == tokWord && typeTerminators[strings.ToUpper(it[i].text)] {
			break
		}
		typ = append(typ, it[i].text)
		i++
	}
	col.Type = strings.Join(typ, " ")
	return col, it[i:]
}

// hasColumnPrimaryKey reports whether the constraint tokens contain a column
// PRIMARY KEY that is not followed by DESC.
func hasColumnPrimaryKey(rest []token) bool {
	depth := 0
	for i := 0; i < len(rest); i++ {
		t := rest[i]
		if t.kind == tokPunct {
			if t.text[0] == '(' {
				depth++
			} else if t.text[0] == ')' {
				depth--
			}
			continue
		}
		if depth == 0 && t.is("PRIMARY") && i+1 < len(rest) && rest[i+1].is("KEY") {
			return !(i+2 < len(rest) && rest[i+2].is("DESC"))
		}
	}
	return false
}

// tablePrimaryKey recognises [CONSTRAINT name] PRIMARY KEY ( col ... ) with a
// single column and returns that column's name.
func tablePrimaryKey(it []token) (string, bool) {
	i := 0
	if it[0].is("CONSTRAINT") {
		i = 2
	}
	if i+2 >= len(it) || !it[i].is("PRIMARY") || !it[i+1].is("KEY") || !it[i+2].isPunct('(') {
		return "", false
	}
	cols, err := splitItems(it[i+3:])
	if err != nil || len(cols) != 1 || len(cols[0]) == 0 {
		return "", false
	}
	return cols[0][0].text, true
}

// ParseCreateIndex parses a CREATE INDEX statement.
func ParseCreateIndex(sql string) (*Index, error) {
	toks, err := tokenize(sql)
	if err != nil {
		return nil, err
	}
	i := 0
	if i >= len(toks) || !toks[i].is("CREATE") {
		return nil, errDDL
	}
	i++
	ix := &Index{}
	if i < len(toks) && toks[i].is("UNIQUE") {
		ix.Unique = true
		i++
	}
	if i >= len(toks) || !toks[i].is("INDEX") {
		return nil, errDDL
	}
	i++
	if i+2 < len(toks) && toks[i].is("IF") && toks[i+1].is("NOT") && toks[i+2].is("EXISTS") {
		i += 3
	}
	i, ix.Name, err = parseQualifiedName(toks, i)
	if err != nil {
		return nil, err
	}
	if i >= len(toks) || !toks[i].is("ON") {
		return nil, errDDL
	}
	i, ix.Table, err = parseQualifiedName(toks, i+1)
	if err != nil {
		return nil, err
	}
	if i >= len(toks) || !toks[i].isPunct('(') {
		return nil, errDDL
	}
	items, err := splitItems(toks[i+1:])
	if err != nil {
		return nil, err
	}
	for _, it := range items {
		if len(it) == 0 {
			return nil, errDDL
		}
		ix.Columns = append(ix.Columns, it[0].text)
	}
	return ix, nil
}
