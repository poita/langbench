package sqlitefile

import (
	"fmt"
	"strings"
)

// Command identifies which of the five query forms a line holds.
type Command uint8

// The query commands.
const (
	CmdTables Command = iota // .tables
	CmdSchema                // .schema <table>
	CmdCount                 // COUNT <table>
	CmdSelect                // SELECT ... FROM <table> ...
	CmdIndex                 // INDEX <index> <literal>
)

// Op is a WHERE comparison operator.
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

var opNames = [...]string{"=", "!=", "<", "<=", ">", ">=", "IS", "IS NOT"}

// String returns the operator's spelling.
func (o Op) String() string { return opNames[o] }

// Condition is one `<column> <op> <literal>` term of a WHERE clause.
type Condition struct {
	Column string
	Op     Op
	Value  Value
}

// Query is a parsed query line. Which fields are set depends on Command.
type Query struct {
	Command Command

	Table string // .schema, COUNT and SELECT: the table name

	// SELECT
	Star    bool        // SELECT *
	Columns []string    // selected columns when !Star
	Where   []Condition // all must hold
	OrderBy string      // "" when there is no ORDER BY
	Desc    bool
	Limit   int64 // -1 when there is no LIMIT

	// INDEX
	IndexName string
	Key       Value
}

type parser struct {
	s   string
	pos int
}

func (p *parser) fail(format string, args ...any) error {
	return fmt.Errorf("%w: %s at offset %d", ErrQuery, fmt.Sprintf(format, args...), p.pos)
}

func (p *parser) skipBlank() {
	for p.pos < len(p.s) && (p.s[p.pos] == ' ' || p.s[p.pos] == '\t') {
		p.pos++
	}
}

func (p *parser) eof() bool { return p.pos >= len(p.s) }

func isWordChar(c byte) bool {
	return c == '_' || isDigit(c) || (c|0x20 >= 'a' && c|0x20 <= 'z')
}

// word consumes a maximal run of [A-Za-z0-9_] after skipping blanks.
func (p *parser) word() string {
	p.skipBlank()
	start := p.pos
	for p.pos < len(p.s) && isWordChar(p.s[p.pos]) {
		p.pos++
	}
	return p.s[start:p.pos]
}

// peekWord returns the next word without consuming anything.
func (p *parser) peekWord() string {
	save := p.pos
	w := p.word()
	p.pos = save
	return w
}

func (p *parser) keyword(kw string) error {
	if w := p.word(); !strings.EqualFold(w, kw) {
		return p.fail("expected %s", kw)
	}
	return nil
}

func (p *parser) ident() (string, error) {
	w := p.word()
	if !validIdent(w) {
		return "", p.fail("expected identifier")
	}
	return w, nil
}

func validIdent(w string) bool {
	if w == "" || isDigit(w[0]) {
		return false
	}
	for i := 0; i < len(w); i++ {
		if !isWordChar(w[i]) {
			return false
		}
	}
	return true
}

// ParseQuery parses one line of a queries file.
func ParseQuery(line string) (*Query, error) {
	if strings.HasPrefix(line, ".") {
		switch {
		case line == ".tables":
			return &Query{Command: CmdTables}, nil
		case strings.HasPrefix(line, ".schema "):
			arg := line[len(".schema "):]
			if !validIdent(arg) {
				return nil, fmt.Errorf("%w: .schema needs one bare identifier", ErrQuery)
			}
			return &Query{Command: CmdSchema, Table: arg}, nil
		}
		return nil, fmt.Errorf("%w: unknown dot command", ErrQuery)
	}
	p := &parser{s: line}
	var q *Query
	var err error
	switch kw := strings.ToUpper(p.word()); kw {
	case "COUNT":
		q = &Query{Command: CmdCount}
		q.Table, err = p.ident()
	case "SELECT":
		q = &Query{Command: CmdSelect, Limit: -1}
		err = p.parseSelect(q)
	case "INDEX":
		q = &Query{Command: CmdIndex}
		if q.IndexName, err = p.ident(); err == nil {
			q.Key, err = p.literal()
		}
	default:
		return nil, p.fail("unknown command")
	}
	if err != nil {
		return nil, err
	}
	p.skipBlank()
	if !p.eof() {
		return nil, p.fail("unexpected trailing text")
	}
	return q, nil
}

func (p *parser) parseSelect(q *Query) error {
	p.skipBlank()
	if p.pos < len(p.s) && p.s[p.pos] == '*' {
		q.Star = true
		p.pos++
	} else {
		for {
			col, err := p.ident()
			if err != nil {
				return err
			}
			q.Columns = append(q.Columns, col)
			p.skipBlank()
			if p.pos < len(p.s) && p.s[p.pos] == ',' {
				p.pos++
				continue
			}
			break
		}
	}
	if err := p.keyword("FROM"); err != nil {
		return err
	}
	var err error
	if q.Table, err = p.ident(); err != nil {
		return err
	}
	if strings.EqualFold(p.peekWord(), "WHERE") {
		p.word()
		for {
			c, err := p.condition()
			if err != nil {
				return err
			}
			q.Where = append(q.Where, c)
			if !strings.EqualFold(p.peekWord(), "AND") {
				break
			}
			p.word()
		}
	}
	if strings.EqualFold(p.peekWord(), "ORDER") {
		p.word()
		if err := p.keyword("BY"); err != nil {
			return err
		}
		if q.OrderBy, err = p.ident(); err != nil {
			return err
		}
		switch strings.ToUpper(p.peekWord()) {
		case "ASC":
			p.word()
		case "DESC":
			p.word()
			q.Desc = true
		}
	}
	if strings.EqualFold(p.peekWord(), "LIMIT") {
		p.word()
		w := p.word()
		if w == "" {
			return p.fail("expected LIMIT count")
		}
		var n int64
		for i := 0; i < len(w); i++ {
			if !isDigit(w[i]) || n > (1<<63-1-int64(w[i]-'0'))/10 {
				return p.fail("bad LIMIT count")
			}
			n = n*10 + int64(w[i]-'0')
		}
		q.Limit = n
	}
	return nil
}

func (p *parser) condition() (Condition, error) {
	var c Condition
	var err error
	if c.Column, err = p.ident(); err != nil {
		return c, err
	}
	p.skipBlank()
	if p.eof() {
		return c, p.fail("expected operator")
	}
	switch ch := p.s[p.pos]; ch {
	case '=':
		c.Op = OpEq
		p.pos++
	case '!':
		if p.pos+1 >= len(p.s) || p.s[p.pos+1] != '=' {
			return c, p.fail("bad operator")
		}
		c.Op = OpNe
		p.pos += 2
	case '<', '>':
		lt := ch == '<'
		p.pos++
		withEq := p.pos < len(p.s) && p.s[p.pos] == '='
		if withEq {
			p.pos++
		}
		switch {
		case lt && withEq:
			c.Op = OpLe
		case lt:
			c.Op = OpLt
		case withEq:
			c.Op = OpGe
		default:
			c.Op = OpGt
		}
	default:
		if !strings.EqualFold(p.word(), "IS") {
			return c, p.fail("bad operator")
		}
		c.Op = OpIs
		if strings.EqualFold(p.peekWord(), "NOT") {
			p.word()
			c.Op = OpIsNot
		}
	}
	c.Value, err = p.literal()
	return c, err
}

// literal parses a numeral, 'string', X'blob' or NULL.
func (p *parser) literal() (Value, error) {
	p.skipBlank()
	if p.eof() {
		return Value{}, p.fail("expected literal")
	}
	s := p.s
	c := s[p.pos]
	switch {
	case c == '\'':
		var b []byte
		i := p.pos + 1
		for {
			if i >= len(s) {
				return Value{}, p.fail("unterminated string")
			}
			if s[i] == '\'' {
				if i+1 < len(s) && s[i+1] == '\'' {
					b = append(b, '\'')
					i += 2
					continue
				}
				i++
				break
			}
			b = append(b, s[i])
			i++
		}
		p.pos = i
		return Value{Kind: KindText, B: b}, nil
	case (c == 'x' || c == 'X') && p.pos+1 < len(s) && s[p.pos+1] == '\'':
		i := p.pos + 2
		var b []byte
		for i < len(s) && s[i] != '\'' {
			if i+1 >= len(s) || s[i+1] == '\'' {
				return Value{}, p.fail("odd number of hex digits")
			}
			hi, ok1 := hexVal(s[i])
			lo, ok2 := hexVal(s[i+1])
			if !ok1 || !ok2 {
				return Value{}, p.fail("bad hex digit")
			}
			b = append(b, hi<<4|lo)
			i += 2
		}
		if i >= len(s) {
			return Value{}, p.fail("unterminated blob")
		}
		p.pos = i + 1
		return Value{Kind: KindBlob, B: append([]byte{}, b...)}, nil
	case c == '+' || c == '-' || isDigit(c):
		return p.numeral()
	}
	if strings.EqualFold(p.word(), "NULL") {
		return Value{}, nil
	}
	return Value{}, p.fail("bad literal")
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

func (p *parser) numeral() (Value, error) {
	s := p.s
	start := p.pos
	i := start
	if s[i] == '+' || s[i] == '-' {
		i++
	}
	d := i
	for i < len(s) && isDigit(s[i]) {
		i++
	}
	if i == d {
		return Value{}, p.fail("bad numeral")
	}
	isReal := false
	if i < len(s) && s[i] == '.' {
		isReal = true
		i++
		for i < len(s) && isDigit(s[i]) {
			i++
		}
	}
	if i < len(s) && (s[i] == 'e' || s[i] == 'E') {
		j := i + 1
		if j < len(s) && (s[j] == '+' || s[j] == '-') {
			j++
		}
		k := j
		for k < len(s) && isDigit(s[k]) {
			k++
		}
		if k > j {
			isReal = true
			i = k
		}
	}
	// A numeral ending in a digit is a word and may not touch another word.
	if i < len(s) && isDigit(s[i-1]) && isWordChar(s[i]) {
		return Value{}, p.fail("bad numeral")
	}
	p.pos = i
	v, ok := numberFromText(s[start:i], isReal)
	if !ok {
		return Value{}, p.fail("bad numeral")
	}
	return v, nil
}
