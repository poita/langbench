package tessera

import (
	"example.com/tessera/value"
)

// CommandKind identifies a parsed command.
type CommandKind uint8

// The fifteen commands of the language.
const (
	CmdBegin CommandKind = iota
	CmdCommit
	CmdRollback
	CmdCheckpoint
	CmdStat
	CmdIndexes
	CmdPut
	CmdGet
	CmdDelete
	CmdUpdate
	CmdUnset
	CmdScan
	CmdFind
	CmdCreateIndex
	CmdDropIndex
)

// Command is a parsed line of the command language. Only the fields relevant
// to Kind are set.
type Command struct {
	Kind     CommandKind
	Key      []byte      // put, get, delete, update, unset
	Path     []string    // update, unset, create index, drop index
	Value    value.Value // put (the document), update
	Scan     ScanOptions // scan
	Pred     *Predicate  // find
	Limit    int         // find
	HasLimit bool        // find
}

var commandNames = map[string]CommandKind{
	"begin": CmdBegin, "commit": CmdCommit, "rollback": CmdRollback,
	"checkpoint": CmdCheckpoint, "stat": CmdStat, "indexes": CmdIndexes,
	"put": CmdPut, "get": CmdGet, "delete": CmdDelete, "update": CmdUpdate,
	"unset": CmdUnset, "scan": CmdScan, "find": CmdFind,
	"create": CmdCreateIndex, "drop": CmdDropIndex,
}

type parser struct {
	toks []token
	pos  int
}

func (p *parser) peek() (token, bool) {
	if p.pos < len(p.toks) {
		return p.toks[p.pos], true
	}
	return token{}, false
}

func (p *parser) peekAt(n int) (token, bool) {
	if p.pos+n < len(p.toks) {
		return p.toks[p.pos+n], true
	}
	return token{}, false
}

func (p *parser) next() (token, bool) {
	t, ok := p.peek()
	if ok {
		p.pos++
	}
	return t, ok
}

func (p *parser) peekIs(kind tokKind, text string) bool {
	t, ok := p.peek()
	return ok && t.is(kind, text)
}

func (p *parser) expect(kind tokKind, text string) error {
	if t, ok := p.next(); !ok || !t.is(kind, text) {
		return newErr(ErrSyntax)
	}
	return nil
}

// ParseCommand parses one line of the command language into a Command,
// applying the stage order of SPEC §18.2: lexing, command word, then parsing
// left to right. The returned error is an *Error.
func ParseCommand(line string) (*Command, error) {
	toks, err := lex(line)
	if err != nil {
		return nil, err
	}
	if len(toks) == 0 || toks[0].kind != tkWord {
		return nil, newErr(ErrSyntax)
	}
	kind, ok := commandNames[toks[0].text]
	if !ok {
		return nil, newErr(ErrUnknownCommand)
	}
	p := &parser{toks: toks, pos: 1}
	cmd := &Command{Kind: kind}
	switch kind {
	case CmdPut:
		if cmd.Key, err = p.key(); err == nil {
			cmd.Value, err = p.value(1)
		}
	case CmdGet, CmdDelete:
		cmd.Key, err = p.key()
	case CmdUpdate:
		if cmd.Key, err = p.key(); err == nil {
			if cmd.Path, err = p.path(); err == nil {
				cmd.Value, err = p.value(1)
			}
		}
	case CmdUnset:
		if cmd.Key, err = p.key(); err == nil {
			cmd.Path, err = p.path()
		}
	case CmdScan:
		err = p.scanOptions(cmd)
	case CmdFind:
		if cmd.Pred, err = p.pred(); err == nil && p.peekIs(tkWord, "limit") {
			p.pos++
			cmd.Limit, err = p.limit()
			cmd.HasLimit = true
		}
	case CmdCreateIndex, CmdDropIndex:
		if err = p.expectWord("index"); err == nil {
			cmd.Path, err = p.path()
		}
	}
	if err != nil {
		return nil, err
	}
	if p.pos < len(p.toks) {
		return nil, newErr(ErrSyntax)
	}
	return cmd, nil
}

func (p *parser) expectWord(w string) error {
	return p.expect(tkWord, w)
}

// str consumes a STRING token and resolves its escapes.
func (p *parser) str() (string, error) {
	t, ok := p.next()
	if !ok || t.kind != tkString {
		return "", newErr(ErrSyntax)
	}
	return decodeString(t.text)
}

func (p *parser) key() ([]byte, error) {
	s, err := p.str()
	if err != nil {
		return nil, err
	}
	if len(s) < 1 || len(s) > MaxKey {
		return nil, newErr(ErrBadKey)
	}
	return []byte(s), nil
}

// intToken resolves an INT token to an int64.
func intToken(text string) (int64, error) {
	neg := text[0] == '-'
	digits := text
	if neg {
		digits = text[1:]
	}
	var u uint64
	for i := 0; i < len(digits); i++ {
		d := uint64(digits[i] - '0')
		if u > (1<<64-1-d)/10 {
			return 0, newErr(ErrIntRange)
		}
		u = u*10 + d
	}
	if neg {
		if u > 1<<63 {
			return 0, newErr(ErrIntRange)
		}
		return int64(-u), nil
	}
	if u > 1<<63-1 {
		return 0, newErr(ErrIntRange)
	}
	return int64(u), nil
}

// limit parses the INT argument of a limit option.
func (p *parser) limit() (int, error) {
	t, ok := p.next()
	if !ok || t.kind != tkInt {
		return 0, newErr(ErrSyntax)
	}
	n, err := intToken(t.text)
	if err != nil {
		return 0, err
	}
	if n < 0 || n > MaxLimit {
		return 0, newErr(ErrSyntax)
	}
	return int(n), nil
}

// path parses WORD { "." WORD }, checking the length limits as each segment is
// consumed.
func (p *parser) path() ([]string, error) {
	var segs []string
	size := 0
	for {
		t, ok := p.next()
		if !ok || t.kind != tkWord {
			return nil, newErr(ErrSyntax)
		}
		segs = append(segs, t.text)
		size += len(t.text)
		if len(segs) > 1 {
			size++
		}
		if len(segs) > MaxSegments || size > MaxPath {
			return nil, newErr(ErrBadPath)
		}
		if !p.peekIs(tkPunct, ".") {
			return segs, nil
		}
		p.pos++
	}
}

func (p *parser) scanOptions(cmd *Command) error {
	o := &cmd.Scan
	for {
		t, ok := p.peek()
		if !ok {
			return nil
		}
		if t.kind != tkWord {
			return newErr(ErrSyntax)
		}
		switch t.text {
		case "from":
			if o.HasFrom {
				return newErr(ErrSyntax)
			}
			p.pos++
			s, err := p.str()
			if err != nil {
				return err
			}
			o.From, o.HasFrom = []byte(s), true
		case "to":
			if o.HasTo {
				return newErr(ErrSyntax)
			}
			p.pos++
			s, err := p.str()
			if err != nil {
				return err
			}
			o.To, o.HasTo = []byte(s), true
		case "limit":
			if o.HasLimit {
				return newErr(ErrSyntax)
			}
			p.pos++
			n, err := p.limit()
			if err != nil {
				return err
			}
			o.Limit, o.HasLimit = n, true
		case "reverse":
			if o.Reverse {
				return newErr(ErrSyntax)
			}
			p.pos++
			o.Reverse = true
		case "keys":
			if o.KeysOnly {
				return newErr(ErrSyntax)
			}
			p.pos++
			o.KeysOnly = true
		default:
			return newErr(ErrSyntax)
		}
	}
}

// value parses a value literal at the given nesting level (SPEC §6.3). The
// depth check happens before the first token of a level-33 value is examined.
func (p *parser) value(level int) (value.Value, error) {
	if level > MaxDepth {
		return value.Value{}, newErr(ErrDepth)
	}
	t, ok := p.next()
	if !ok {
		return value.Value{}, newErr(ErrSyntax)
	}
	switch t.kind {
	case tkWord:
		switch t.text {
		case "null":
			return value.NullValue(), nil
		case "true":
			return value.BoolValue(true), nil
		case "false":
			return value.BoolValue(false), nil
		}
	case tkInt:
		n, err := intToken(t.text)
		if err != nil {
			return value.Value{}, err
		}
		return value.IntValue(n), nil
	case tkString:
		s, err := decodeString(t.text)
		if err != nil {
			return value.Value{}, err
		}
		return value.StringValue(s), nil
	case tkPunct:
		switch t.text {
		case "[":
			return p.list(level)
		case "{":
			return p.object(level)
		}
	}
	return value.Value{}, newErr(ErrSyntax)
}

func (p *parser) list(level int) (value.Value, error) {
	var items []value.Value
	if p.peekIs(tkPunct, "]") {
		p.pos++
		return value.Value{Kind: value.List, Items: items}, nil
	}
	for {
		v, err := p.value(level + 1)
		if err != nil {
			return value.Value{}, err
		}
		items = append(items, v)
		t, ok := p.next()
		if !ok {
			return value.Value{}, newErr(ErrSyntax)
		}
		if t.is(tkPunct, "]") {
			return value.Value{Kind: value.List, Items: items}, nil
		}
		if !t.is(tkPunct, ",") {
			return value.Value{}, newErr(ErrSyntax)
		}
	}
}

func (p *parser) object(level int) (value.Value, error) {
	var fields []value.Field
	if p.peekIs(tkPunct, "}") {
		p.pos++
		return value.Value{Kind: value.Object, Fields: fields}, nil
	}
	seen := map[string]struct{}{}
	for {
		t, ok := p.next()
		if !ok || (t.kind != tkString && t.kind != tkWord) {
			return value.Value{}, newErr(ErrSyntax)
		}
		name := t.text
		if t.kind == tkString {
			var err error
			if name, err = decodeString(t.text); err != nil {
				return value.Value{}, err
			}
		}
		if _, dup := seen[name]; dup {
			return value.Value{}, newErr(ErrDupField)
		}
		seen[name] = struct{}{}
		if err := p.expect(tkPunct, ":"); err != nil {
			return value.Value{}, err
		}
		v, err := p.value(level + 1)
		if err != nil {
			return value.Value{}, err
		}
		fields = append(fields, value.Field{Name: name, Val: v})
		t, ok = p.next()
		if !ok {
			return value.Value{}, newErr(ErrSyntax)
		}
		if t.is(tkPunct, "}") {
			return value.ObjectValue(fields...), nil
		}
		if !t.is(tkPunct, ",") {
			return value.Value{}, newErr(ErrSyntax)
		}
	}
}

// pred parses a predicate: disj = conj { "or" conj }.
func (p *parser) pred() (*Predicate, error) {
	left, err := p.conj()
	if err != nil {
		return nil, err
	}
	for p.peekIs(tkWord, "or") {
		p.pos++
		right, err := p.conj()
		if err != nil {
			return nil, err
		}
		left = Or(left, right)
	}
	return left, nil
}

func (p *parser) conj() (*Predicate, error) {
	left, err := p.term()
	if err != nil {
		return nil, err
	}
	for p.peekIs(tkWord, "and") {
		p.pos++
		right, err := p.term()
		if err != nil {
			return nil, err
		}
		left = And(left, right)
	}
	return left, nil
}

func (p *parser) term() (*Predicate, error) {
	t, ok := p.peek()
	if !ok {
		return nil, newErr(ErrSyntax)
	}
	if t.is(tkPunct, "(") {
		p.pos++
		return p.parenthesised()
	}
	if t.kind != tkWord {
		return nil, newErr(ErrSyntax)
	}
	n1, _ := p.peekAt(1)
	switch {
	case t.text == "not" && n1.is(tkPunct, "("):
		p.pos += 2
		inner, err := p.parenthesised()
		if err != nil {
			return nil, err
		}
		return Not(inner), nil
	case t.text == "exists" && n1.kind == tkWord:
		p.pos++
		path, err := p.path()
		if err != nil {
			return nil, err
		}
		return Exists(path), nil
	case t.text == "missing" && n1.kind == tkWord:
		p.pos++
		path, err := p.path()
		if err != nil {
			return nil, err
		}
		return Missing(path), nil
	}
	path, err := p.path()
	if err != nil {
		return nil, err
	}
	op, ok := p.next()
	if !ok || op.kind != tkOp {
		return nil, newErr(ErrSyntax)
	}
	v, err := p.value(1)
	if err != nil {
		return nil, err
	}
	return Cmp(path, cmpOps[op.text], v), nil
}

var cmpOps = map[string]CmpOp{"==": OpEq, "!=": OpNe, "<": OpLt, "<=": OpLe, ">": OpGt, ">=": OpGe}

// parenthesised parses pred ")" after the opening parenthesis was consumed.
func (p *parser) parenthesised() (*Predicate, error) {
	inner, err := p.pred()
	if err != nil {
		return nil, err
	}
	if err := p.expect(tkPunct, ")"); err != nil {
		return nil, err
	}
	return inner, nil
}
