// Package query parses the line-oriented query language: the dot commands
// .tables and .schema, COUNT, SELECT and INDEX. Parsing is purely syntactic;
// names are resolved against a catalog by the caller.
package query

import (
	"errors"
	"strconv"
	"strings"

	"sqlitefile/value"
)

// ErrSyntax is returned (wrapped with detail) for a line that is not a
// well-formed query.
var ErrSyntax = errors.New("query: syntax error")

// Op is a comparison operator in a WHERE condition.
type Op uint8

// The eight comparison operators.
const (
	OpEq Op = iota
	OpNe
	OpLt
	OpLe
	OpGt
	OpGe
	OpIs
	OpIsNot
)

func (o Op) String() string {
	return [...]string{"=", "!=", "<", "<=", ">", ">=", "IS", "IS NOT"}[o]
}

// Query is a parsed query line: one of *Tables, *Schema, *Count, *Select or
// *Index.
type Query interface{ isQuery() }

// Tables is the ".tables" command.
type Tables struct{}

// Schema is the ".schema <table>" command.
type Schema struct{ Table string }

// Count is "COUNT <table>".
type Count struct{ Table string }

// Cond is one "<column> <op> <literal>" condition.
type Cond struct {
	Column  string
	Op      Op
	Literal value.Value
}

// Select is "SELECT <columns> FROM <table> [WHERE ...] [ORDER BY ...] [LIMIT n]".
type Select struct {
	Star    bool     // SELECT *
	Columns []string // column names when Star is false
	Table   string
	Where   []Cond // conditions joined by AND
	OrderBy string // empty when there is no ORDER BY
	Desc    bool
	Limit   int64 // meaningful only when HasLimit
	// HasLimit reports whether a LIMIT clause was given.
	HasLimit bool
}

// Index is "INDEX <index-name> <literal>".
type Index struct {
	Name    string
	Literal value.Value
}

func (*Tables) isQuery() {}
func (*Schema) isQuery() {}
func (*Count) isQuery()  {}
func (*Select) isQuery() {}
func (*Index) isQuery()  {}

type parser struct {
	s   string
	pos int
}

func errf(msg string) error { return errors.New(ErrSyntax.Error() + ": " + msg) }

// Parse parses one query line.
func Parse(line string) (Query, error) {
	if strings.HasPrefix(line, ".") {
		return parseDot(line)
	}
	p := &parser{s: line}
	p.skipSpace()
	kw := p.word()
	switch {
	case strings.EqualFold(kw, "SELECT"):
		return p.parseSelect()
	case strings.EqualFold(kw, "COUNT"):
		name, err := p.ident()
		if err != nil {
			return nil, err
		}
		if err := p.end(); err != nil {
			return nil, err
		}
		return &Count{Table: name}, nil
	case strings.EqualFold(kw, "INDEX"):
		name, err := p.ident()
		if err != nil {
			return nil, err
		}
		lit, err := p.literal()
		if err != nil {
			return nil, err
		}
		if err := p.end(); err != nil {
			return nil, err
		}
		return &Index{Name: name, Literal: lit}, nil
	}
	return nil, errf("unknown command")
}

func parseDot(line string) (Query, error) {
	switch {
	case line == ".tables":
		return &Tables{}, nil
	case strings.HasPrefix(line, ".schema "):
		arg := line[len(".schema "):]
		if !isIdent(arg) {
			return nil, errf(".schema needs one bare table name")
		}
		return &Schema{Table: arg}, nil
	}
	return nil, errf("unknown dot command")
}

func isWordByte(c byte) bool {
	return c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '_'
}

func isDigit(c byte) bool { return c >= '0' && c <= '9' }

func isIdent(s string) bool {
	if s == "" || isDigit(s[0]) {
		return false
	}
	for i := 0; i < len(s); i++ {
		if !isWordByte(s[i]) {
			return false
		}
	}
	return true
}

func (p *parser) skipSpace() {
	for p.pos < len(p.s) && (p.s[p.pos] == ' ' || p.s[p.pos] == '\t') {
		p.pos++
	}
}

func (p *parser) atEnd() bool { return p.pos >= len(p.s) }

// end requires that only whitespace remains.
func (p *parser) end() error {
	p.skipSpace()
	if !p.atEnd() {
		return errf("unexpected text after query")
	}
	return nil
}

// word consumes a maximal run of [A-Za-z0-9_] (possibly empty), then skips
// following blanks. A word is always followed by a non-word character, which
// enforces that adjacent words are separated.
func (p *parser) word() string {
	start := p.pos
	for p.pos < len(p.s) && isWordByte(p.s[p.pos]) {
		p.pos++
	}
	w := p.s[start:p.pos]
	p.skipSpace()
	return w
}

// peekWord returns the upcoming word without consuming it.
func (p *parser) peekWord() string {
	save := p.pos
	w := p.word()
	p.pos = save
	return w
}

// keyword consumes the given keyword if it is next.
func (p *parser) keyword(kw string) bool {
	if strings.EqualFold(p.peekWord(), kw) {
		p.word()
		return true
	}
	return false
}

func (p *parser) ident() (string, error) {
	w := p.word()
	if !isIdent(w) {
		return "", errf("expected a name")
	}
	return w, nil
}

func (p *parser) parseSelect() (Query, error) {
	q := &Select{}
	if p.pos < len(p.s) && p.s[p.pos] == '*' {
		p.pos++
		p.skipSpace()
		q.Star = true
	} else {
		for {
			name, err := p.ident()
			if err != nil {
				return nil, err
			}
			q.Columns = append(q.Columns, name)
			if p.pos < len(p.s) && p.s[p.pos] == ',' {
				p.pos++
				p.skipSpace()
				continue
			}
			break
		}
	}
	if !p.keyword("FROM") {
		return nil, errf("expected FROM")
	}
	var err error
	if q.Table, err = p.ident(); err != nil {
		return nil, err
	}
	if p.keyword("WHERE") {
		for {
			c, err := p.cond()
			if err != nil {
				return nil, err
			}
			q.Where = append(q.Where, c)
			if !p.keyword("AND") {
				break
			}
		}
	}
	if p.keyword("ORDER") {
		if !p.keyword("BY") {
			return nil, errf("expected BY")
		}
		if q.OrderBy, err = p.ident(); err != nil {
			return nil, err
		}
		if p.keyword("DESC") {
			q.Desc = true
		} else {
			p.keyword("ASC")
		}
	}
	if p.keyword("LIMIT") {
		w := p.word()
		if w == "" || strings.Trim(w, "0123456789") != "" {
			return nil, errf("LIMIT needs a non-negative integer")
		}
		if q.Limit, err = strconv.ParseInt(w, 10, 64); err != nil {
			q.Limit = 1<<63 - 1 // larger than any row count
		}
		q.HasLimit = true
	}
	if err := p.end(); err != nil {
		return nil, err
	}
	return q, nil
}

func (p *parser) cond() (Cond, error) {
	col, err := p.ident()
	if err != nil {
		return Cond{}, err
	}
	c := Cond{Column: col}
	rest := p.s[p.pos:]
	switch {
	case strings.HasPrefix(rest, "!="):
		c.Op, p.pos = OpNe, p.pos+2
	case strings.HasPrefix(rest, "<="):
		c.Op, p.pos = OpLe, p.pos+2
	case strings.HasPrefix(rest, ">="):
		c.Op, p.pos = OpGe, p.pos+2
	case strings.HasPrefix(rest, "="):
		c.Op, p.pos = OpEq, p.pos+1
	case strings.HasPrefix(rest, "<"):
		c.Op, p.pos = OpLt, p.pos+1
	case strings.HasPrefix(rest, ">"):
		c.Op, p.pos = OpGt, p.pos+1
	default:
		// IS / IS NOT: the IS word is only valid if the text after it can
		// start a literal; keyword() has already enforced word separation.
		if !p.keyword("IS") {
			return Cond{}, errf("expected a comparison operator")
		}
		c.Op = OpIs
		if p.keyword("NOT") {
			c.Op = OpIsNot
		}
		if c.Literal, err = p.literal(); err != nil {
			return Cond{}, err
		}
		return c, nil
	}
	p.skipSpace()
	if c.Literal, err = p.literal(); err != nil {
		return Cond{}, err
	}
	return c, nil
}

// literal parses a numeral, string, blob or NULL, then skips blanks. A numeral
// must not be followed directly by a word character (adjacent words need a
// separator); NULL is consumed as a whole word so the same holds for it.
func (p *parser) literal() (value.Value, error) {
	s := p.s
	i := p.pos
	if i >= len(s) {
		return value.Value{}, errf("expected a literal")
	}
	var v value.Value
	switch c := s[i]; {
	case c == '\'':
		var sb strings.Builder
		j := i + 1
		for {
			if j >= len(s) {
				return value.Value{}, errf("unterminated string")
			}
			if s[j] == '\'' {
				if j+1 < len(s) && s[j+1] == '\'' {
					sb.WriteByte('\'')
					j += 2
					continue
				}
				break
			}
			sb.WriteByte(s[j])
			j++
		}
		v = value.NewText(sb.String())
		p.pos = j + 1
	case (c == 'x' || c == 'X') && i+1 < len(s) && s[i+1] == '\'':
		j := i + 2
		start := j
		for j < len(s) && s[j] != '\'' {
			j++
		}
		if j >= len(s) {
			return value.Value{}, errf("unterminated blob")
		}
		hex := s[start:j]
		if len(hex)%2 != 0 {
			return value.Value{}, errf("odd number of hex digits")
		}
		b := make([]byte, len(hex)/2)
		for k := range b {
			hi, ok1 := hexVal(hex[2*k])
			lo, ok2 := hexVal(hex[2*k+1])
			if !ok1 || !ok2 {
				return value.Value{}, errf("bad hex digit")
			}
			b[k] = hi<<4 | lo
		}
		v = value.NewBlob(b)
		p.pos = j + 1
	case c == '+' || c == '-' || isDigit(c):
		j := i
		if c == '+' || c == '-' {
			j++
		}
		d := j
		for j < len(s) && isDigit(s[j]) {
			j++
		}
		if j == d {
			return value.Value{}, errf("malformed number")
		}
		isInt := true
		if j < len(s) && s[j] == '.' {
			isInt = false
			j++
			for j < len(s) && isDigit(s[j]) {
				j++
			}
		}
		if j < len(s) && (s[j] == 'e' || s[j] == 'E') {
			k := j + 1
			if k < len(s) && (s[k] == '+' || s[k] == '-') {
				k++
			}
			e := k
			for k < len(s) && isDigit(s[k]) {
				k++
			}
			if k > e {
				isInt = false
				j = k
			}
		}
		text := s[i:j]
		if isInt {
			n, err := strconv.ParseInt(text, 10, 64)
			if err != nil {
				return value.Value{}, errf("integer out of range")
			}
			v = value.NewInt(n)
		} else {
			f, _ := strconv.ParseFloat(text, 64)
			v = value.NewReal(f)
		}
		p.pos = j
		if p.pos < len(s) && isWordByte(s[p.pos]) {
			return value.Value{}, errf("text directly after number")
		}
	default:
		w := p.peekWord()
		if !strings.EqualFold(w, "NULL") {
			return value.Value{}, errf("expected a literal")
		}
		p.word()
		return value.NullValue, nil
	}
	p.skipSpace()
	return v, nil
}

func hexVal(c byte) (byte, bool) {
	switch {
	case c >= '0' && c <= '9':
		return c - '0', true
	case c >= 'a' && c <= 'f':
		return c - 'a' + 10, true
	case c >= 'A' && c <= 'F':
		return c - 'A' + 10, true
	}
	return 0, false
}
