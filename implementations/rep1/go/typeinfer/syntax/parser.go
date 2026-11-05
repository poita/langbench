package syntax

// Parse lexes and parses a whole program, interning identifiers in in.
//
// On a lexical or syntax error Parse returns the declarations that were
// parsed completely before the error, together with the error (of type
// *Error); the returned Program is never nil.
func Parse(src []byte, in *Interner) (*Program, error) {
	toks, lexErr := Lex(src, in)
	p := &parser{toks: toks, prog: &Program{Nodes: make([]Node, 0, len(toks)/2+8)}}
	err := p.run()
	if err == nil {
		err = lexErr
	}
	return p.prog, err
}

type parser struct {
	toks  []Token
	pos   int
	prog  *Program
	stack []int32 // scratch stack for parameter, element and operand lists
}

// bailout is the panic payload used to unwind out of the recursive descent.
type bailout struct{ err *Error }

func (p *parser) run() (err error) {
	defer func() {
		if r := recover(); r != nil {
			b, ok := r.(bailout)
			if !ok {
				panic(r)
			}
			err = b.err
		}
	}()
	for p.kind() != EOF {
		p.decl()
	}
	return nil
}

func (p *parser) kind() TokenKind { return p.toks[p.pos].Kind }

func (p *parser) next() {
	if p.pos < len(p.toks)-1 {
		p.pos++
	}
}

func (p *parser) fail(msg string) {
	panic(bailout{&Error{Pos: int(p.toks[p.pos].Pos), Msg: msg}})
}

func (p *parser) expect(k TokenKind) {
	if p.kind() != k {
		p.fail("expected " + k.String() + ", found " + p.kind().String())
	}
	p.next()
}

func (p *parser) expectIdent() int32 {
	if p.kind() != Ident {
		p.fail("expected identifier, found " + p.kind().String())
	}
	id := p.toks[p.pos].ID
	p.next()
	return id
}

func (p *parser) add(n Node) int32 {
	p.prog.Nodes = append(p.prog.Nodes, n)
	return int32(len(p.prog.Nodes) - 1)
}

// decl := "let" ["rec"] ident ident* "=" expr ";;" | expr ";;"
func (p *parser) decl() {
	var d Decl
	if p.kind() == KwLet {
		p.next()
		rec := p.kind() == KwRec
		if rec {
			p.next()
			d.Kind = DeclLetRec
		}
		d.Name, d.Expr = p.binding()
	} else {
		d.Kind = DeclExpr
		d.Expr = p.expr()
	}
	p.expect(SemiSemi)
	p.prog.Decls = append(p.prog.Decls, d)
}

// binding parses "ident ident* = expr" and returns the name and the
// right-hand side with the parameters desugared into nested functions.
func (p *parser) binding() (name, rhs int32) {
	name = p.expectIdent()
	start := len(p.stack)
	for p.kind() == Ident {
		p.stack = append(p.stack, p.toks[p.pos].ID)
		p.next()
	}
	p.expect(Eq)
	rhs = p.expr()
	rhs = p.wrapFuns(start, rhs)
	return name, rhs
}

// wrapFuns wraps body in one KFun per parameter on the scratch stack above
// start (innermost last) and pops them.
func (p *parser) wrapFuns(start int, body int32) int32 {
	for i := len(p.stack) - 1; i >= start; i-- {
		body = p.add(Node{Kind: KFun, Name: p.stack[i], A: body})
	}
	p.stack = p.stack[:start]
	return body
}

func (p *parser) expr() int32 {
	switch p.kind() {
	case KwLet:
		p.next()
		kind := KLet
		if p.kind() == KwRec {
			p.next()
			kind = KLetRec
		}
		name, rhs := p.binding()
		p.expect(KwIn)
		body := p.expr()
		return p.add(Node{Kind: kind, Name: name, A: rhs, B: body})
	case KwFun:
		p.next()
		start := len(p.stack)
		for p.kind() == Ident {
			p.stack = append(p.stack, p.toks[p.pos].ID)
			p.next()
		}
		if len(p.stack) == start {
			p.fail("expected parameter after 'fun'")
		}
		p.expect(Arrow)
		body := p.expr()
		return p.wrapFuns(start, body)
	case KwIf:
		p.next()
		c := p.expr()
		p.expect(KwThen)
		a := p.expr()
		p.expect(KwElse)
		b := p.expr()
		return p.add(Node{Kind: KIf, A: c, B: a, C: b})
	}
	return p.or()
}

func (p *parser) or() int32 {
	l := p.and()
	for p.kind() == OrOr {
		p.next()
		r := p.and()
		l = p.add(Node{Kind: KBinop, Op: OpOr, A: l, B: r})
	}
	return l
}

func (p *parser) and() int32 {
	l := p.cmp()
	for p.kind() == AndAnd {
		p.next()
		r := p.cmp()
		l = p.add(Node{Kind: KBinop, Op: OpAnd, A: l, B: r})
	}
	return l
}

func (p *parser) cmp() int32 {
	l := p.cons()
	var op Op
	switch p.kind() {
	case Eq:
		op = OpEq
	case Lt:
		op = OpLt
	case Gt:
		op = OpGt
	case Le:
		op = OpLe
	case Ge:
		op = OpGe
	default:
		return l
	}
	p.next()
	r := p.cons()
	return p.add(Node{Kind: KBinop, Op: op, A: l, B: r})
}

// cons parses a right-associative "::" chain iteratively.
func (p *parser) cons() int32 {
	first := p.additive()
	if p.kind() != ColonColon {
		return first
	}
	start := len(p.stack)
	p.stack = append(p.stack, first)
	for p.kind() == ColonColon {
		p.next()
		e := p.additive()
		p.stack = append(p.stack, e)
	}
	acc := p.stack[len(p.stack)-1]
	for i := len(p.stack) - 2; i >= start; i-- {
		acc = p.add(Node{Kind: KCons, A: p.stack[i], B: acc})
	}
	p.stack = p.stack[:start]
	return acc
}

// additive parses the additive level ("add" in the grammar).
func (p *parser) additive() int32 {
	l := p.mul()
	for {
		var op Op
		switch p.kind() {
		case Plus:
			op = OpAdd
		case Minus:
			op = OpSub
		default:
			return l
		}
		p.next()
		r := p.mul()
		l = p.add(Node{Kind: KBinop, Op: op, A: l, B: r})
	}
}

func (p *parser) mul() int32 {
	l := p.app()
	for {
		var op Op
		switch p.kind() {
		case Star:
			op = OpMul
		case Slash:
			op = OpDiv
		default:
			return l
		}
		p.next()
		r := p.app()
		l = p.add(Node{Kind: KBinop, Op: op, A: l, B: r})
	}
}

func (p *parser) app() int32 {
	f := p.atom()
	for startsAtom(p.kind()) {
		a := p.atom()
		f = p.add(Node{Kind: KApp, A: f, B: a})
	}
	return f
}

func startsAtom(k TokenKind) bool {
	switch k {
	case IntLit, KwTrue, KwFalse, Ident, LParen, LBrack:
		return true
	}
	return false
}

func (p *parser) atom() int32 {
	t := p.toks[p.pos]
	switch t.Kind {
	case IntLit:
		p.next()
		return p.add(Node{Kind: KInt})
	case KwTrue:
		p.next()
		return p.add(Node{Kind: KBool, A: 1})
	case KwFalse:
		p.next()
		return p.add(Node{Kind: KBool})
	case Ident:
		p.next()
		return p.add(Node{Kind: KVar, Name: t.ID})
	case LParen:
		p.next()
		if p.kind() == RParen {
			p.next()
			return p.add(Node{Kind: KUnit})
		}
		e := p.expr()
		if p.kind() != Comma {
			p.expect(RParen)
			return e
		}
		start := len(p.stack)
		p.stack = append(p.stack, e)
		for p.kind() == Comma {
			p.next()
			p.stack = append(p.stack, p.expr())
		}
		p.expect(RParen)
		return p.seq(KTuple, start)
	case LBrack:
		p.next()
		if p.kind() == RBrack {
			p.next()
			return p.add(Node{Kind: KList})
		}
		start := len(p.stack)
		p.stack = append(p.stack, p.expr())
		for p.kind() == Semi {
			p.next()
			p.stack = append(p.stack, p.expr())
		}
		p.expect(RBrack)
		return p.seq(KList, start)
	}
	p.fail("unexpected " + t.Kind.String())
	return 0
}

// seq creates a tuple or list node from the elements on the scratch stack
// above start and pops them.
func (p *parser) seq(kind NodeKind, start int) int32 {
	elems := p.stack[start:]
	first := int32(len(p.prog.Kids))
	p.prog.Kids = append(p.prog.Kids, elems...)
	n := int32(len(elems))
	p.stack = p.stack[:start]
	return p.add(Node{Kind: kind, A: first, B: n})
}
