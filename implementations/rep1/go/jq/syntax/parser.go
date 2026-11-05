package syntax

import (
	"fmt"

	"github.com/peter/jq/value"
)

// maxDepth bounds the nesting of the filter grammar.
const maxDepth = 1000

type parser struct {
	toks  []token
	i     int
	depth int
}

// Parse parses a jq filter into an AST.
func Parse(src string) (*Node, error) {
	toks, err := lex(src)
	if err != nil {
		return nil, err
	}
	p := &parser{toks: toks}
	n, err := p.pipe()
	if err != nil {
		return nil, err
	}
	if p.cur().kind != tEOF {
		return nil, p.errf("unexpected %s", p.describe())
	}
	return n, nil
}

func (p *parser) cur() token  { return p.toks[p.i] }
func (p *parser) next() token { t := p.toks[p.i]; p.i++; return t }

func (p *parser) describe() string {
	t := p.cur()
	switch t.kind {
	case tEOF:
		return "end of filter"
	case tString:
		return "string"
	case tNumber:
		return "number " + t.text
	}
	return fmt.Sprintf("%q", t.text)
}

func (p *parser) errf(format string, args ...any) error {
	return &Error{p.cur().pos, fmt.Sprintf(format, args...)}
}

func (p *parser) isPunct(s string) bool {
	t := p.cur()
	return t.kind == tPunct && t.text == s
}

func (p *parser) isKeyword(s string) bool {
	t := p.cur()
	return t.kind == tIdent && t.text == s
}

func (p *parser) expectPunct(s string) error {
	if !p.isPunct(s) {
		return p.errf("expected %q but found %s", s, p.describe())
	}
	p.i++
	return nil
}

func (p *parser) expectKeyword(s string) error {
	if !p.isKeyword(s) {
		return p.errf("expected %q but found %s", s, p.describe())
	}
	p.i++
	return nil
}

func (p *parser) enter() error {
	p.depth++
	if p.depth > maxDepth {
		return p.errf("filter nested too deeply")
	}
	return nil
}

func (p *parser) leave() { p.depth-- }

// pipe := postfix "as" "$" IDENT "|" pipe | comma [ "|" pipe ]
func (p *parser) pipe() (*Node, error) {
	if err := p.enter(); err != nil {
		return nil, err
	}
	defer p.leave()
	lhs, err := p.comma()
	if err != nil {
		return nil, err
	}
	if p.isKeyword("as") {
		p.i++
		t := p.cur()
		if t.kind != tVar {
			return nil, p.errf("expected variable after \"as\"")
		}
		p.i++
		if err := p.expectPunct("|"); err != nil {
			return nil, err
		}
		body, err := p.pipe()
		if err != nil {
			return nil, err
		}
		return &Node{Op: OpAs, A: lhs, Name: t.text, B: body}, nil
	}
	if p.isPunct("|") {
		p.i++
		rhs, err := p.pipe()
		if err != nil {
			return nil, err
		}
		return &Node{Op: OpPipe, A: lhs, B: rhs}, nil
	}
	return lhs, nil
}

func (p *parser) comma() (*Node, error) {
	lhs, err := p.or()
	if err != nil {
		return nil, err
	}
	for p.isPunct(",") {
		p.i++
		rhs, err := p.or()
		if err != nil {
			return nil, err
		}
		lhs = &Node{Op: OpComma, A: lhs, B: rhs}
	}
	return lhs, nil
}

func (p *parser) or() (*Node, error) {
	lhs, err := p.and()
	if err != nil {
		return nil, err
	}
	for p.isKeyword("or") {
		p.i++
		rhs, err := p.and()
		if err != nil {
			return nil, err
		}
		lhs = &Node{Op: OpOr, A: lhs, B: rhs}
	}
	return lhs, nil
}

func (p *parser) and() (*Node, error) {
	lhs, err := p.cmp()
	if err != nil {
		return nil, err
	}
	for p.isKeyword("and") {
		p.i++
		rhs, err := p.cmp()
		if err != nil {
			return nil, err
		}
		lhs = &Node{Op: OpAnd, A: lhs, B: rhs}
	}
	return lhs, nil
}

var cmpOps = map[string]BinOp{"==": Eq, "!=": Ne, "<": Lt, "<=": Le, ">": Gt, ">=": Ge}

func (p *parser) cmp() (*Node, error) {
	lhs, err := p.add()
	if err != nil {
		return nil, err
	}
	if t := p.cur(); t.kind == tPunct {
		if op, ok := cmpOps[t.text]; ok {
			p.i++
			rhs, err := p.add()
			if err != nil {
				return nil, err
			}
			return &Node{Op: OpBinary, Bin: op, A: lhs, B: rhs}, nil
		}
	}
	return lhs, nil
}

func (p *parser) add() (*Node, error) {
	lhs, err := p.mul()
	if err != nil {
		return nil, err
	}
	for {
		op := Add
		switch {
		case p.isPunct("+"):
		case p.isPunct("-"):
			op = Sub
		default:
			return lhs, nil
		}
		p.i++
		rhs, err := p.mul()
		if err != nil {
			return nil, err
		}
		lhs = &Node{Op: OpBinary, Bin: op, A: lhs, B: rhs}
	}
}

func (p *parser) mul() (*Node, error) {
	lhs, err := p.unary()
	if err != nil {
		return nil, err
	}
	for {
		var op BinOp
		switch {
		case p.isPunct("*"):
			op = Mul
		case p.isPunct("/"):
			op = Div
		case p.isPunct("%"):
			op = Mod
		default:
			return lhs, nil
		}
		p.i++
		rhs, err := p.unary()
		if err != nil {
			return nil, err
		}
		lhs = &Node{Op: OpBinary, Bin: op, A: lhs, B: rhs}
	}
}

func (p *parser) unary() (*Node, error) {
	if p.isPunct("-") {
		p.i++
		if err := p.enter(); err != nil {
			return nil, err
		}
		defer p.leave()
		a, err := p.unary()
		if err != nil {
			return nil, err
		}
		return &Node{Op: OpNeg, A: a}, nil
	}
	return p.postfix()
}

func (p *parser) postfix() (*Node, error) {
	n, err := p.primary()
	if err != nil {
		return nil, err
	}
	// pathOp is true while the last suffix was a field/index/iterate/slice
	// that a following "?" should make tolerant.
	pathOp := n.Op == OpIndex && n.A.Op == OpIdentity
	for {
		switch {
		case p.cur().kind == tField:
			t := p.next()
			n = fieldNode(n, t.text)
			pathOp = true
		case p.isPunct(".") && p.i+1 < len(p.toks) && p.toks[p.i+1].kind == tString &&
			p.toks[p.i+1].pos == p.cur().end:
			p.i++
			n = fieldNode(n, p.next().text)
			pathOp = true
		case p.isPunct(".") && p.i+1 < len(p.toks) && p.toks[p.i+1].kind == tPunct &&
			p.toks[p.i+1].text == "[" && p.toks[p.i+1].pos == p.cur().end:
			p.i++ // "a.[0]" is the same as "a[0]"
		case p.isPunct("["):
			p.i++
			n, err = p.bracket(n)
			if err != nil {
				return nil, err
			}
			pathOp = true
		case p.isPunct("?"):
			p.i++
			if pathOp {
				n.Optional = true
			} else {
				n = &Node{Op: OpTry, A: n}
			}
			pathOp = false
		default:
			return n, nil
		}
	}
}

func fieldNode(target *Node, name string) *Node {
	return &Node{Op: OpIndex, A: target, B: &Node{Op: OpLiteral, Val: value.String(name)}}
}

// bracket parses the inside of "[...]" after the opening bracket.
func (p *parser) bracket(target *Node) (*Node, error) {
	if p.isPunct("]") {
		p.i++
		return &Node{Op: OpIter, A: target}, nil
	}
	var from *Node
	if !p.isPunct(":") {
		var err error
		if from, err = p.pipe(); err != nil {
			return nil, err
		}
		if p.isPunct("]") {
			p.i++
			return &Node{Op: OpIndex, A: target, B: from}, nil
		}
	}
	if err := p.expectPunct(":"); err != nil {
		return nil, err
	}
	var to *Node
	if !p.isPunct("]") {
		var err error
		if to, err = p.pipe(); err != nil {
			return nil, err
		}
	}
	if err := p.expectPunct("]"); err != nil {
		return nil, err
	}
	return &Node{Op: OpSlice, A: target, B: from, C: to}, nil
}

func (p *parser) primary() (*Node, error) {
	t := p.cur()
	switch t.kind {
	case tField:
		p.i++
		return fieldNode(&Node{Op: OpIdentity}, t.text), nil
	case tNumber:
		p.i++
		return &Node{Op: OpLiteral, Val: value.Number(t.num)}, nil
	case tString:
		p.i++
		return &Node{Op: OpLiteral, Val: value.String(t.text)}, nil
	case tVar:
		p.i++
		return &Node{Op: OpVar, Name: t.text}, nil
	case tIdent:
		return p.identPrimary()
	case tPunct:
		switch t.text {
		case ".":
			p.i++
			if nt := p.cur(); nt.kind == tString && nt.pos == t.end {
				p.i++
				return fieldNode(&Node{Op: OpIdentity}, nt.text), nil
			}
			return &Node{Op: OpIdentity}, nil
		case "(":
			p.i++
			n, err := p.pipe()
			if err != nil {
				return nil, err
			}
			if err := p.expectPunct(")"); err != nil {
				return nil, err
			}
			return n, nil
		case "[":
			p.i++
			if p.isPunct("]") {
				p.i++
				return &Node{Op: OpArray}, nil
			}
			n, err := p.pipe()
			if err != nil {
				return nil, err
			}
			if err := p.expectPunct("]"); err != nil {
				return nil, err
			}
			return &Node{Op: OpArray, A: n}, nil
		case "{":
			p.i++
			return p.object()
		}
	}
	return nil, p.errf("unexpected %s", p.describe())
}

func (p *parser) identPrimary() (*Node, error) {
	t := p.next()
	switch t.text {
	case "true":
		return &Node{Op: OpLiteral, Val: value.True}, nil
	case "false":
		return &Node{Op: OpLiteral, Val: value.False}, nil
	case "null":
		return &Node{Op: OpLiteral, Val: value.Null}, nil
	case "if":
		return p.ifExpr()
	case "reduce":
		src, err := p.postfix()
		if err != nil {
			return nil, err
		}
		if err := p.expectKeyword("as"); err != nil {
			return nil, err
		}
		v := p.cur()
		if v.kind != tVar {
			return nil, p.errf("expected variable after \"as\"")
		}
		p.i++
		if err := p.expectPunct("("); err != nil {
			return nil, err
		}
		init, err := p.pipe()
		if err != nil {
			return nil, err
		}
		if err := p.expectPunct(";"); err != nil {
			return nil, err
		}
		upd, err := p.pipe()
		if err != nil {
			return nil, err
		}
		if err := p.expectPunct(")"); err != nil {
			return nil, err
		}
		return &Node{Op: OpReduce, A: src, Name: v.text, B: init, C: upd}, nil
	case "then", "elif", "else", "end", "as", "and", "or":
		p.i--
		return nil, p.errf("unexpected keyword %q", t.text)
	}
	n := &Node{Op: OpCall, Name: t.text}
	if p.isPunct("(") {
		p.i++
		for {
			arg, err := p.pipe()
			if err != nil {
				return nil, err
			}
			n.Args = append(n.Args, arg)
			if p.isPunct(";") {
				p.i++
				continue
			}
			break
		}
		if err := p.expectPunct(")"); err != nil {
			return nil, err
		}
	}
	return n, nil
}

// ifExpr parses the rest of an if-expression after the "if" keyword.
func (p *parser) ifExpr() (*Node, error) {
	cond, err := p.pipe()
	if err != nil {
		return nil, err
	}
	if err := p.expectKeyword("then"); err != nil {
		return nil, err
	}
	then, err := p.pipe()
	if err != nil {
		return nil, err
	}
	n := &Node{Op: OpIf, A: cond, B: then}
	switch {
	case p.isKeyword("elif"):
		p.i++
		if n.C, err = p.ifExpr(); err != nil {
			return nil, err
		}
		return n, nil
	case p.isKeyword("else"):
		p.i++
		if n.C, err = p.pipe(); err != nil {
			return nil, err
		}
	}
	if err := p.expectKeyword("end"); err != nil {
		return nil, err
	}
	return n, nil
}

// object parses the rest of an object construction after "{".
func (p *parser) object() (*Node, error) {
	n := &Node{Op: OpObject}
	if p.isPunct("}") {
		p.i++
		return n, nil
	}
	for {
		e, err := p.objectEntry()
		if err != nil {
			return nil, err
		}
		n.Entries = append(n.Entries, e)
		if p.isPunct(",") {
			p.i++
			continue
		}
		if err := p.expectPunct("}"); err != nil {
			return nil, err
		}
		return n, nil
	}
}

func (p *parser) objectEntry() (ObjectEntry, error) {
	t := p.cur()
	var key *Node
	switch {
	case t.kind == tIdent || t.kind == tString:
		p.i++
		key = &Node{Op: OpLiteral, Val: value.String(t.text)}
		if !p.isPunct(":") {
			if t.kind == tIdent && (t.text == "if" || t.text == "reduce") {
				return ObjectEntry{}, p.errf("expected \":\" after object key")
			}
			return ObjectEntry{key, fieldNode(&Node{Op: OpIdentity}, t.text)}, nil
		}
	case t.kind == tVar:
		p.i++
		return ObjectEntry{
			&Node{Op: OpLiteral, Val: value.String(t.text)},
			&Node{Op: OpVar, Name: t.text},
		}, nil
	case p.isPunct("("):
		p.i++
		k, err := p.pipe()
		if err != nil {
			return ObjectEntry{}, err
		}
		if err := p.expectPunct(")"); err != nil {
			return ObjectEntry{}, err
		}
		key = k
		if !p.isPunct(":") {
			return ObjectEntry{}, p.errf("expected \":\" after object key")
		}
	default:
		return ObjectEntry{}, p.errf("unexpected %s in object construction", p.describe())
	}
	p.i++ // ":"
	val, err := p.objVal()
	if err != nil {
		return ObjectEntry{}, err
	}
	return ObjectEntry{key, val}, nil
}

// objVal := objterm { "|" objterm }
func (p *parser) objVal() (*Node, error) {
	lhs, err := p.objTerm()
	if err != nil {
		return nil, err
	}
	for p.isPunct("|") {
		p.i++
		rhs, err := p.objTerm()
		if err != nil {
			return nil, err
		}
		lhs = &Node{Op: OpPipe, A: lhs, B: rhs}
	}
	return lhs, nil
}

func (p *parser) objTerm() (*Node, error) {
	if p.isPunct("-") {
		p.i++
		a, err := p.objTerm()
		if err != nil {
			return nil, err
		}
		return &Node{Op: OpNeg, A: a}, nil
	}
	return p.postfix()
}
