package lang

import (
	"strconv"

	"example.com/kvstore/kverr"
	"example.com/kvstore/query"
	"example.com/kvstore/value"
)

// Parse lexes and parses one command line. The returned error is a
// *kverr.Error whose kind is the first problem in source order (syntax,
// unknown-command, bad-utf8, int-range, dup-field, depth, bad-key or
// bad-path).
func Parse(line string) (*Command, error) {
	toks, err := lex(line)
	if err != nil {
		return nil, err
	}
	p := &parser{toks: toks}
	return p.command()
}

type parser struct {
	toks []token
	pos  int
}

func (p *parser) done() bool { return p.pos >= len(p.toks) }

func (p *parser) peek() *token {
	if p.pos < len(p.toks) {
		return &p.toks[p.pos]
	}
	return nil
}

// peekAt returns the token n places ahead of the current one, or nil.
func (p *parser) peekAt(n int) *token {
	if p.pos+n < len(p.toks) {
		return &p.toks[p.pos+n]
	}
	return nil
}

func (p *parser) isPunct(t *token, s string) bool {
	return t != nil && t.kind == tPunct && t.text == s
}

func (p *parser) isWord(t *token, s string) bool {
	return t != nil && t.kind == tWord && t.text == s
}

func (p *parser) expectPunct(s string) error {
	t := p.peek()
	if !p.isPunct(t, s) {
		return kverr.Syntax
	}
	p.pos++
	return nil
}

func (p *parser) end() error {
	if !p.done() {
		return kverr.Syntax
	}
	return nil
}

func (p *parser) command() (*Command, error) {
	t := p.peek()
	if t == nil || t.kind != tWord {
		return nil, kverr.Syntax
	}
	p.pos++
	c := &Command{Limit: -1, Scan: ScanOptions{Limit: -1}}
	switch t.text {
	case "begin", "commit", "rollback", "checkpoint", "stat", "indexes":
		c.Name = Name(t.text)
		return c, p.end()
	case "put":
		c.Name = Put
		key, err := p.key()
		if err != nil {
			return nil, err
		}
		c.Key = key
		if c.Value, err = p.value(1); err != nil {
			return nil, err
		}
		return c, p.end()
	case "get", "delete":
		c.Name = Name(t.text)
		key, err := p.key()
		if err != nil {
			return nil, err
		}
		c.Key = key
		return c, p.end()
	case "update":
		c.Name = Update
		key, err := p.key()
		if err != nil {
			return nil, err
		}
		c.Key = key
		if c.Path, err = p.path(); err != nil {
			return nil, err
		}
		if c.Value, err = p.value(1); err != nil {
			return nil, err
		}
		return c, p.end()
	case "unset":
		c.Name = Unset
		key, err := p.key()
		if err != nil {
			return nil, err
		}
		c.Key = key
		if c.Path, err = p.path(); err != nil {
			return nil, err
		}
		return c, p.end()
	case "scan":
		c.Name = Scan
		return c, p.scanOptions(&c.Scan)
	case "find":
		c.Name = Find
		pred, err := p.pred()
		if err != nil {
			return nil, err
		}
		c.Pred = pred
		if p.isWord(p.peek(), "limit") {
			p.pos++
			if c.Limit, err = p.limit(); err != nil {
				return nil, err
			}
		}
		return c, p.end()
	case "create", "drop":
		if !p.isWord(p.peek(), "index") {
			return nil, kverr.Syntax
		}
		p.pos++
		c.Name = CreateIndex
		if t.text == "drop" {
			c.Name = DropIndex
		}
		var err error
		if c.Path, err = p.path(); err != nil {
			return nil, err
		}
		return c, p.end()
	}
	return nil, kverr.UnknownCommand
}

// str consumes a string token and resolves its value.
func (p *parser) str() (string, error) {
	t := p.peek()
	if t == nil || t.kind != tString {
		return "", kverr.Syntax
	}
	p.pos++
	if t.bad {
		return "", kverr.BadUTF8
	}
	return t.str, nil
}

// key consumes a key argument: a string of 1..MaxKey bytes.
func (p *parser) key() ([]byte, error) {
	s, err := p.str()
	if err != nil {
		return nil, err
	}
	if len(s) == 0 || len(s) > value.MaxKey {
		return nil, kverr.BadKey
	}
	return []byte(s), nil
}

// intTok consumes an INT token and resolves it to an int64.
func (p *parser) intTok() (int64, error) {
	t := p.peek()
	if t == nil || t.kind != tInt {
		return 0, kverr.Syntax
	}
	p.pos++
	n, err := strconv.ParseInt(t.text, 10, 64)
	if err != nil {
		return 0, kverr.IntRange
	}
	return n, nil
}

// limit consumes the INT of a limit option, which must lie in 0..MaxLimit.
func (p *parser) limit() (int, error) {
	n, err := p.intTok()
	if err != nil {
		return 0, err
	}
	if n < 0 || n > value.MaxLimit {
		return 0, kverr.Syntax
	}
	return int(n), nil
}

func (p *parser) scanOptions(o *ScanOptions) error {
	var seenFrom, seenTo, seenLimit, seenReverse, seenKeys bool
	for !p.done() {
		t := p.peek()
		if t.kind != tWord {
			return kverr.Syntax
		}
		seen := func(flag *bool) bool {
			if *flag {
				return true
			}
			*flag = true
			return false
		}
		switch t.text {
		case "from":
			if seen(&seenFrom) {
				return kverr.Syntax
			}
			p.pos++
			s, err := p.str()
			if err != nil {
				return err
			}
			o.From, o.HasFrom = []byte(s), true
		case "to":
			if seen(&seenTo) {
				return kverr.Syntax
			}
			p.pos++
			s, err := p.str()
			if err != nil {
				return err
			}
			o.To, o.HasTo = []byte(s), true
		case "limit":
			if seen(&seenLimit) {
				return kverr.Syntax
			}
			p.pos++
			n, err := p.limit()
			if err != nil {
				return err
			}
			o.Limit = n
		case "reverse":
			if seen(&seenReverse) {
				return kverr.Syntax
			}
			p.pos++
			o.Reverse = true
		case "keys":
			if seen(&seenKeys) {
				return kverr.Syntax
			}
			p.pos++
			o.KeyOnly = true
		default:
			return kverr.Syntax
		}
	}
	return nil
}

// path consumes a field path, checking the segment and length limits as each
// segment is consumed.
func (p *parser) path() (value.Path, error) {
	var segs value.Path
	size := 0
	for {
		t := p.peek()
		if t == nil || t.kind != tWord {
			return nil, kverr.Syntax
		}
		p.pos++
		segs = append(segs, t.text)
		size += len(t.text)
		if len(segs) > 1 {
			size++
		}
		if len(segs) > value.MaxPathSegments || size > value.MaxPath {
			return nil, kverr.BadPath
		}
		if !p.isPunct(p.peek(), ".") {
			return segs, nil
		}
		p.pos++
	}
}

// value parses a value literal whose nesting level is level (1 = outermost).
func (p *parser) value(level int) (value.Value, error) {
	if level > value.MaxDepth {
		return value.Value{}, kverr.Depth
	}
	t := p.peek()
	if t == nil {
		return value.Value{}, kverr.Syntax
	}
	switch t.kind {
	case tWord:
		p.pos++
		switch t.text {
		case "null":
			return value.NewNull(), nil
		case "true":
			return value.NewBool(true), nil
		case "false":
			return value.NewBool(false), nil
		}
		return value.Value{}, kverr.Syntax
	case tInt:
		n, err := p.intTok()
		if err != nil {
			return value.Value{}, err
		}
		return value.NewInt(n), nil
	case tString:
		s, err := p.str()
		if err != nil {
			return value.Value{}, err
		}
		return value.NewString(s), nil
	case tPunct:
		switch t.text {
		case "[":
			p.pos++
			return p.list(level)
		case "{":
			p.pos++
			return p.object(level)
		}
	}
	return value.Value{}, kverr.Syntax
}

// list parses the rest of a list literal after its "[".
func (p *parser) list(level int) (value.Value, error) {
	elems := []value.Value{}
	if p.isPunct(p.peek(), "]") {
		p.pos++
		return value.NewList(elems), nil
	}
	for {
		v, err := p.value(level + 1)
		if err != nil {
			return value.Value{}, err
		}
		elems = append(elems, v)
		t := p.peek()
		switch {
		case p.isPunct(t, ","):
			p.pos++
		case p.isPunct(t, "]"):
			p.pos++
			return value.NewList(elems), nil
		default:
			return value.Value{}, kverr.Syntax
		}
	}
}

// object parses the rest of an object literal after its "{".
func (p *parser) object(level int) (value.Value, error) {
	var fields []value.Field
	seen := map[string]struct{}{}
	if p.isPunct(p.peek(), "}") {
		p.pos++
		return value.NewObject(nil), nil
	}
	for {
		t := p.peek()
		if t == nil {
			return value.Value{}, kverr.Syntax
		}
		var name string
		switch t.kind {
		case tWord:
			p.pos++
			name = t.text
		case tString:
			s, err := p.str()
			if err != nil {
				return value.Value{}, err
			}
			name = s
		default:
			return value.Value{}, kverr.Syntax
		}
		if _, dup := seen[name]; dup {
			return value.Value{}, kverr.DupField
		}
		seen[name] = struct{}{}
		if err := p.expectPunct(":"); err != nil {
			return value.Value{}, err
		}
		v, err := p.value(level + 1)
		if err != nil {
			return value.Value{}, err
		}
		fields = append(fields, value.Field{Name: name, Value: v})
		t = p.peek()
		switch {
		case p.isPunct(t, ","):
			p.pos++
		case p.isPunct(t, "}"):
			p.pos++
			return value.NewObject(fields), nil
		default:
			return value.Value{}, kverr.Syntax
		}
	}
}

// pred parses a predicate: disj = conj { "or" conj }.
func (p *parser) pred() (query.Node, error) {
	left, err := p.conj()
	if err != nil {
		return nil, err
	}
	for p.isWord(p.peek(), "or") {
		p.pos++
		right, err := p.conj()
		if err != nil {
			return nil, err
		}
		left = query.Or{L: left, R: right}
	}
	return left, nil
}

func (p *parser) conj() (query.Node, error) {
	left, err := p.term()
	if err != nil {
		return nil, err
	}
	for p.isWord(p.peek(), "and") {
		p.pos++
		right, err := p.term()
		if err != nil {
			return nil, err
		}
		left = query.And{L: left, R: right}
	}
	return left, nil
}

func (p *parser) term() (query.Node, error) {
	t := p.peek()
	switch {
	case t == nil:
		return nil, kverr.Syntax
	case p.isPunct(t, "("):
		p.pos++
		n, err := p.pred()
		if err != nil {
			return nil, err
		}
		if err := p.expectPunct(")"); err != nil {
			return nil, err
		}
		return n, nil
	case p.isWord(t, "not") && p.isPunct(p.peekAt(1), "("):
		p.pos += 2
		n, err := p.pred()
		if err != nil {
			return nil, err
		}
		if err := p.expectPunct(")"); err != nil {
			return nil, err
		}
		return query.Not{X: n}, nil
	case p.isWord(t, "exists") && p.peekAt(1) != nil && p.peekAt(1).kind == tWord:
		p.pos++
		path, err := p.path()
		if err != nil {
			return nil, err
		}
		return query.Exists{Path: path}, nil
	case p.isWord(t, "missing") && p.peekAt(1) != nil && p.peekAt(1).kind == tWord:
		p.pos++
		path, err := p.path()
		if err != nil {
			return nil, err
		}
		return query.Missing{Path: path}, nil
	case t.kind == tWord:
		path, err := p.path()
		if err != nil {
			return nil, err
		}
		op := p.peek()
		if op == nil || op.kind != tOp {
			return nil, kverr.Syntax
		}
		p.pos++
		v, err := p.value(1)
		if err != nil {
			return nil, err
		}
		return query.Cmp{Path: path, Op: opOf(op.text), Val: v}, nil
	}
	return nil, kverr.Syntax
}

func opOf(s string) query.Op {
	switch s {
	case "==":
		return query.Eq
	case "!=":
		return query.Ne
	case "<":
		return query.Lt
	case "<=":
		return query.Le
	case ">":
		return query.Gt
	}
	return query.Ge
}
