// Package parser builds the syntax tree of one module from its tokens
// (SPEC.md section 4). It is a recursive-descent parser with precedence
// climbing; every failure is the single diagnostic `parse`.
package parser

import (
	"langvm/ast"
	"langvm/diag"
	"langvm/lexer"
)

// bail is the panic payload used to abort parsing.
type bail struct{ err *diag.Error }

// Parse parses the tokens of a module. The token slice must end with an EOF
// token, as produced by lexer.Lex.
func Parse(name string, toks []lexer.Token) (mod *ast.Module, err *diag.Error) {
	p := &parser{toks: toks}
	defer func() {
		if r := recover(); r != nil {
			if b, ok := r.(bail); ok {
				mod, err = nil, b.err
				return
			}
			panic(r)
		}
	}()
	mod = &ast.Module{Name: name}
	for p.tok().Kind != lexer.EOF {
		mod.Items = append(mod.Items, p.item())
	}
	return mod, nil
}

type parser struct {
	toks []lexer.Token
	i    int

	// halfGT is set when a `>>` token closed an inner type-argument list and
	// its second `>` is still available to the enclosing list.
	halfGT bool
	gtPos  diag.Pos
}

func (p *parser) tok() *lexer.Token { return &p.toks[p.i] }

func (p *parser) peekKind(off int) lexer.Kind {
	if p.i+off < len(p.toks) {
		return p.toks[p.i+off].Kind
	}
	return lexer.EOF
}

func (p *parser) fail(pos diag.Pos) {
	panic(bail{diag.New(diag.Parse, pos)})
}

func (p *parser) failHere() { p.fail(p.tok().Pos) }

func (p *parser) next() *lexer.Token {
	t := &p.toks[p.i]
	if t.Kind != lexer.EOF {
		p.i++
	}
	return t
}

func (p *parser) accept(k lexer.Kind) bool {
	if p.tok().Kind == k {
		p.next()
		return true
	}
	return false
}

func (p *parser) expect(k lexer.Kind) *lexer.Token {
	if p.tok().Kind != k {
		p.failHere()
	}
	return p.next()
}

func (p *parser) ident() ast.Ident {
	t := p.expect(lexer.Ident)
	return ast.Ident{Name: t.Text, Pos: t.Pos}
}

// ---------------------------------------------------------------- items

func (p *parser) item() ast.Item {
	t := p.tok()
	switch t.Kind {
	case lexer.KwUse:
		return p.useDecl()
	case lexer.KwImpl:
		return p.implDecl()
	case lexer.KwPub:
		p.next()
		return p.pubItem(true)
	}
	return p.pubItem(false)
}

func (p *parser) pubItem(pub bool) ast.Item {
	switch p.tok().Kind {
	case lexer.KwFn:
		return p.fnDecl(pub)
	case lexer.KwStruct:
		return p.structDecl(pub)
	case lexer.KwEnum:
		return p.enumDecl(pub)
	case lexer.KwTrait:
		return p.traitDecl(pub)
	}
	p.failHere()
	return nil
}

func (p *parser) useDecl() ast.Item {
	pos := p.next().Pos
	d := &ast.UseDecl{Pos: pos, Name: p.ident()}
	if p.accept(lexer.KwAs) {
		a := p.ident()
		d.Alias = &a
	}
	p.expect(lexer.Semi)
	return d
}

func (p *parser) traitRef() *ast.TraitRef {
	first := p.ident()
	if p.accept(lexer.ColonColon) {
		n := p.ident()
		return &ast.TraitRef{Pos: first.Pos, Qual: &first, Name: n}
	}
	return &ast.TraitRef{Pos: first.Pos, Name: first}
}

func (p *parser) generics(allowBounds bool) []*ast.GenParam {
	if p.tok().Kind != lexer.Less {
		return nil
	}
	p.next()
	var gs []*ast.GenParam
	for {
		g := &ast.GenParam{Name: p.ident()}
		if p.tok().Kind == lexer.Colon {
			if !allowBounds {
				p.failHere()
			}
			p.next()
			g.Bounds = append(g.Bounds, p.traitRef())
			for p.accept(lexer.Plus) {
				g.Bounds = append(g.Bounds, p.traitRef())
			}
		}
		gs = append(gs, g)
		if p.accept(lexer.Comma) {
			if p.tok().Kind == lexer.Greater {
				break
			}
			continue
		}
		break
	}
	p.expect(lexer.Greater)
	return gs
}

func (p *parser) params() []*ast.Param {
	var ps []*ast.Param
	for {
		name := p.ident()
		p.expect(lexer.Colon)
		ps = append(ps, &ast.Param{Name: name, Type: p.typ()})
		if p.accept(lexer.Comma) {
			if p.tok().Kind == lexer.RParen {
				break
			}
			continue
		}
		break
	}
	return ps
}

func (p *parser) fnDecl(pub bool) ast.Item {
	pos := p.next().Pos
	d := &ast.FnDecl{Pos: pos, Pub: pub, Name: p.ident()}
	d.Generics = p.generics(true)
	p.expect(lexer.LParen)
	if p.tok().Kind != lexer.RParen {
		d.Params = p.params()
	}
	p.expect(lexer.RParen)
	if p.accept(lexer.Arrow) {
		d.Ret = p.typ()
	}
	d.Body = p.block()
	return d
}

func (p *parser) structDecl(pub bool) ast.Item {
	pos := p.next().Pos
	d := &ast.StructDecl{Pos: pos, Pub: pub, Name: p.ident()}
	d.Generics = p.generics(false)
	p.expect(lexer.LBrace)
	for p.tok().Kind != lexer.RBrace {
		f := &ast.FieldDecl{Name: p.ident()}
		p.expect(lexer.Colon)
		f.Type = p.typ()
		d.Fields = append(d.Fields, f)
		if !p.accept(lexer.Comma) {
			break
		}
	}
	p.expect(lexer.RBrace)
	return d
}

func (p *parser) enumDecl(pub bool) ast.Item {
	pos := p.next().Pos
	d := &ast.EnumDecl{Pos: pos, Pub: pub, Name: p.ident()}
	d.Generics = p.generics(false)
	p.expect(lexer.LBrace)
	for p.tok().Kind != lexer.RBrace {
		v := &ast.VariantDecl{Name: p.ident()}
		if p.accept(lexer.LParen) {
			for {
				v.Payload = append(v.Payload, p.typ())
				if p.accept(lexer.Comma) {
					if p.tok().Kind == lexer.RParen {
						break
					}
					continue
				}
				break
			}
			p.expect(lexer.RParen)
		}
		d.Variants = append(d.Variants, v)
		if !p.accept(lexer.Comma) {
			break
		}
	}
	p.expect(lexer.RBrace)
	return d
}

// method parses `fn name(self [, params]) [-> T] ( ; | block )`.
func (p *parser) method(allowNoBody bool) *ast.MethodDecl {
	pos := p.expect(lexer.KwFn).Pos
	m := &ast.MethodDecl{Pos: pos, Name: p.ident()}
	p.expect(lexer.LParen)
	p.expect(lexer.KwSelf)
	if p.accept(lexer.Comma) {
		if p.tok().Kind == lexer.RParen {
			p.failHere()
		}
		m.Params = p.params()
	}
	p.expect(lexer.RParen)
	if p.accept(lexer.Arrow) {
		m.Ret = p.typ()
	}
	if allowNoBody && p.accept(lexer.Semi) {
		return m
	}
	m.Body = p.block()
	return m
}

func (p *parser) traitDecl(pub bool) ast.Item {
	pos := p.next().Pos
	d := &ast.TraitDecl{Pos: pos, Pub: pub, Name: p.ident()}
	p.expect(lexer.LBrace)
	for p.tok().Kind != lexer.RBrace {
		d.Methods = append(d.Methods, p.method(true))
	}
	p.expect(lexer.RBrace)
	return d
}

func (p *parser) implDecl() ast.Item {
	pos := p.next().Pos
	d := &ast.ImplDecl{Pos: pos}
	d.Generics = p.generics(true)
	d.Trait = p.traitRef()
	p.expect(lexer.KwFor)
	d.Head = p.typ()
	p.expect(lexer.LBrace)
	for p.tok().Kind != lexer.RBrace {
		d.Methods = append(d.Methods, p.method(false))
	}
	p.expect(lexer.RBrace)
	return d
}

// ---------------------------------------------------------------- types

func (p *parser) typ() ast.Type {
	t := p.typeCore(false)
	return t
}

func (p *parser) typeCore(allowHalf bool) ast.Type {
	t := p.tok()
	var res ast.Type
	switch t.Kind {
	case lexer.LBracket:
		p.next()
		e := p.typ()
		p.expect(lexer.RBracket)
		res = &ast.ListType{Pos: t.Pos, Elem: e}
	case lexer.HashBracket:
		p.next()
		k := p.typ()
		p.expect(lexer.Colon)
		v := p.typ()
		p.expect(lexer.RBracket)
		res = &ast.MapType{Pos: t.Pos, K: k, V: v}
	case lexer.LParen:
		p.next()
		tt := &ast.TupleType{Pos: t.Pos}
		tt.Elems = append(tt.Elems, p.typ())
		p.expect(lexer.Comma)
		for {
			tt.Elems = append(tt.Elems, p.typ())
			if p.accept(lexer.Comma) {
				if p.tok().Kind == lexer.RParen {
					break
				}
				continue
			}
			break
		}
		p.expect(lexer.RParen)
		res = tt
	case lexer.KwFn:
		p.next()
		ft := &ast.FnType{Pos: t.Pos}
		p.expect(lexer.LParen)
		if p.tok().Kind != lexer.RParen {
			for {
				ft.Params = append(ft.Params, p.typ())
				if p.accept(lexer.Comma) {
					if p.tok().Kind == lexer.RParen {
						break
					}
					continue
				}
				break
			}
		}
		p.expect(lexer.RParen)
		if p.accept(lexer.Arrow) {
			ft.Ret = p.typ()
		}
		res = ft
	case lexer.Ident:
		first := p.ident()
		pt := &ast.PathType{Pos: first.Pos, Name: first}
		if p.accept(lexer.ColonColon) {
			q := first
			pt.Qual = &q
			pt.Name = p.ident()
		}
		if p.tok().Kind == lexer.Less {
			p.next()
			pt.HasArgs = true
			for {
				pt.Args = append(pt.Args, p.typeCore(true))
				if p.halfGT {
					p.halfGT = false
					break
				}
				if p.accept(lexer.Comma) {
					if p.tok().Kind == lexer.Greater || p.tok().Kind == lexer.Shr {
						// trailing comma, then the closer
						p.closeAngle()
						break
					}
					continue
				}
				p.closeAngle()
				break
			}
		}
		res = pt
	default:
		p.failHere()
	}
	if p.halfGT && !allowHalf {
		p.fail(p.gtPos)
	}
	return res
}

// closeAngle consumes the `>` (or `>>`, leaving half of it for the enclosing
// list) that ends a type-argument list.
func (p *parser) closeAngle() {
	switch p.tok().Kind {
	case lexer.Greater:
		p.next()
	case lexer.Shr:
		p.gtPos = p.tok().Pos
		p.next()
		p.halfGT = true
	default:
		p.failHere()
	}
}

// ---------------------------------------------------------------- blocks

func (p *parser) block() *ast.Block {
	open := p.expect(lexer.LBrace)
	b := &ast.Block{Pos: open.Pos}
	for p.tok().Kind != lexer.RBrace {
		t := p.tok()
		switch t.Kind {
		case lexer.KwLet:
			p.next()
			s := &ast.LetStmt{Pos: t.Pos}
			s.Pat = p.pattern()
			if p.accept(lexer.Colon) {
				s.Type = p.typ()
			}
			p.expect(lexer.Assign)
			s.Init = p.expr()
			p.expect(lexer.Semi)
			b.Stmts = append(b.Stmts, s)
		case lexer.KwVar:
			p.next()
			s := &ast.VarStmt{Pos: t.Pos, Name: p.ident()}
			if p.accept(lexer.Colon) {
				s.Type = p.typ()
			}
			p.expect(lexer.Assign)
			s.Init = p.expr()
			p.expect(lexer.Semi)
			b.Stmts = append(b.Stmts, s)
		case lexer.KwReturn:
			p.next()
			s := &ast.ReturnStmt{Pos: t.Pos}
			if p.tok().Kind != lexer.Semi {
				s.X = p.expr()
			}
			p.expect(lexer.Semi)
			b.Stmts = append(b.Stmts, s)
		case lexer.KwWhile:
			p.next()
			s := &ast.WhileStmt{Pos: t.Pos}
			s.Cond = p.expr()
			s.Body = p.block()
			b.Stmts = append(b.Stmts, s)
		case lexer.KwFor:
			p.next()
			s := &ast.ForStmt{Pos: t.Pos}
			s.Pat = p.pattern()
			p.expect(lexer.KwIn)
			s.Iter = p.expr()
			if p.accept(lexer.DotDot) {
				s.End = p.expr()
			}
			s.Body = p.block()
			b.Stmts = append(b.Stmts, s)
		case lexer.KwBreak:
			p.next()
			p.expect(lexer.Semi)
			b.Stmts = append(b.Stmts, &ast.BreakStmt{Pos: t.Pos})
		case lexer.KwContinue:
			p.next()
			p.expect(lexer.Semi)
			b.Stmts = append(b.Stmts, &ast.ContinueStmt{Pos: t.Pos})
		default:
			e := p.expr()
			switch p.tok().Kind {
			case lexer.Assign:
				p.next()
				v := p.expr()
				p.expect(lexer.Semi)
				b.Stmts = append(b.Stmts, &ast.AssignStmt{Pos: e.ExprPos(), Target: e, Value: v})
			case lexer.Semi:
				p.next()
				b.Stmts = append(b.Stmts, &ast.ExprStmt{X: e})
			case lexer.RBrace:
				b.Trailing = e
			default:
				switch e.(type) {
				case *ast.IfExpr, *ast.MatchExpr:
					b.Stmts = append(b.Stmts, &ast.ExprStmt{X: e})
				default:
					p.failHere()
				}
			}
		}
	}
	p.expect(lexer.RBrace)
	return b
}

// ---------------------------------------------------------------- expressions

func (p *parser) expr() ast.Expr { return p.binary(1) }

type opInfo struct {
	level int
	op    string
}

func binOp(k lexer.Kind) (opInfo, bool) {
	switch k {
	case lexer.OrOr:
		return opInfo{1, "||"}, true
	case lexer.AndAnd:
		return opInfo{2, "&&"}, true
	case lexer.EqEq:
		return opInfo{3, "=="}, true
	case lexer.NotEq:
		return opInfo{3, "!="}, true
	case lexer.Less:
		return opInfo{3, "<"}, true
	case lexer.LessEq:
		return opInfo{3, "<="}, true
	case lexer.Greater:
		return opInfo{3, ">"}, true
	case lexer.GreaterEq:
		return opInfo{3, ">="}, true
	case lexer.Pipe:
		return opInfo{4, "|"}, true
	case lexer.Caret:
		return opInfo{5, "^"}, true
	case lexer.Amp:
		return opInfo{6, "&"}, true
	case lexer.Shl:
		return opInfo{7, "<<"}, true
	case lexer.Shr:
		return opInfo{7, ">>"}, true
	case lexer.Plus:
		return opInfo{8, "+"}, true
	case lexer.Minus:
		return opInfo{8, "-"}, true
	case lexer.PlusPlus:
		return opInfo{8, "++"}, true
	case lexer.Star:
		return opInfo{9, "*"}, true
	case lexer.Slash:
		return opInfo{9, "/"}, true
	case lexer.Percent:
		return opInfo{9, "%"}, true
	}
	return opInfo{}, false
}

func (p *parser) binary(minLevel int) ast.Expr {
	left := p.unary()
	for {
		info, ok := binOp(p.tok().Kind)
		if !ok || info.level < minLevel {
			return left
		}
		opTok := p.next()
		right := p.binary(info.level + 1)
		left = &ast.BinaryExpr{Pos: left.ExprPos(), Op: info.op, OpPos: opTok.Pos, L: left, R: right}
		if info.level == 3 {
			// comparison is non-associative
			if next, ok := binOp(p.tok().Kind); ok && next.level == 3 {
				p.failHere()
			}
		}
	}
}

func (p *parser) unary() ast.Expr {
	t := p.tok()
	switch t.Kind {
	case lexer.Minus, lexer.Bang, lexer.Tilde:
		p.next()
		x := p.unary()
		op := "-"
		if t.Kind == lexer.Bang {
			op = "!"
		} else if t.Kind == lexer.Tilde {
			op = "~"
		}
		return &ast.UnaryExpr{Pos: t.Pos, Op: op, X: x}
	}
	return p.postfix()
}

func (p *parser) args() []ast.Expr {
	var as []ast.Expr
	if p.tok().Kind == lexer.RParen {
		return as
	}
	for {
		as = append(as, p.expr())
		if p.accept(lexer.Comma) {
			if p.tok().Kind == lexer.RParen {
				break
			}
			continue
		}
		break
	}
	return as
}

func (p *parser) postfix() ast.Expr {
	e := p.primary()
	for {
		switch p.tok().Kind {
		case lexer.LParen:
			p.next()
			as := p.args()
			p.expect(lexer.RParen)
			e = &ast.CallExpr{Pos: e.ExprPos(), Callee: e, Args: as}
		case lexer.LBracket:
			p.next()
			i := p.expr()
			p.expect(lexer.RBracket)
			e = &ast.IndexExpr{Pos: e.ExprPos(), X: e, I: i}
		case lexer.Dot:
			p.next()
			name := p.ident()
			if p.tok().Kind == lexer.LParen {
				p.next()
				as := p.args()
				p.expect(lexer.RParen)
				e = &ast.MethodCallExpr{Pos: e.ExprPos(), Recv: e, Name: name, Args: as}
			} else {
				e = &ast.FieldExpr{Pos: e.ExprPos(), X: e, Name: name}
			}
		default:
			return e
		}
	}
}

func (p *parser) primary() ast.Expr {
	t := p.tok()
	switch t.Kind {
	case lexer.Int:
		p.next()
		return &ast.IntLit{Pos: t.Pos, Val: t.Int}
	case lexer.Float:
		p.next()
		return &ast.FloatLit{Pos: t.Pos, Val: t.Float}
	case lexer.Str:
		p.next()
		return &ast.StrLit{Pos: t.Pos, Val: t.Str}
	case lexer.Char:
		p.next()
		return &ast.CharLit{Pos: t.Pos, Val: rune(t.Int)}
	case lexer.KwTrue, lexer.KwFalse:
		p.next()
		return &ast.BoolLit{Pos: t.Pos, Val: t.Kind == lexer.KwTrue}
	case lexer.KwSelf:
		p.next()
		return &ast.SelfExpr{Pos: t.Pos}
	case lexer.LParen:
		p.next()
		first := p.expr()
		if p.accept(lexer.RParen) {
			return first
		}
		p.expect(lexer.Comma)
		elems := []ast.Expr{first}
		for {
			elems = append(elems, p.expr())
			if p.accept(lexer.Comma) {
				if p.tok().Kind == lexer.RParen {
					break
				}
				continue
			}
			break
		}
		p.expect(lexer.RParen)
		return &ast.TupleLit{Pos: t.Pos, Elems: elems}
	case lexer.LBracket:
		p.next()
		l := &ast.ListLit{Pos: t.Pos}
		if p.tok().Kind != lexer.RBracket {
			for {
				l.Elems = append(l.Elems, p.expr())
				if p.accept(lexer.Comma) {
					if p.tok().Kind == lexer.RBracket {
						break
					}
					continue
				}
				break
			}
		}
		p.expect(lexer.RBracket)
		return l
	case lexer.HashBracket:
		p.next()
		m := &ast.MapLit{Pos: t.Pos}
		if p.tok().Kind != lexer.RBracket {
			for {
				k := p.expr()
				p.expect(lexer.Colon)
				v := p.expr()
				m.Entries = append(m.Entries, &ast.MapEntry{K: k, V: v})
				if p.accept(lexer.Comma) {
					if p.tok().Kind == lexer.RBracket {
						break
					}
					continue
				}
				break
			}
		}
		p.expect(lexer.RBracket)
		return m
	case lexer.Pipe, lexer.OrOr:
		return p.lambda()
	case lexer.KwIf:
		return p.ifExpr()
	case lexer.KwMatch:
		return p.matchExpr()
	case lexer.Ident:
		path := p.valuePath()
		if p.tok().Kind == lexer.Dot && p.peekKind(1) == lexer.LBrace {
			p.next()
			p.next()
			s := &ast.StructLit{Pos: path.Pos, Path: path}
			if p.tok().Kind != lexer.RBrace {
				for {
					name := p.ident()
					p.expect(lexer.Colon)
					s.Fields = append(s.Fields, &ast.FieldInit{Name: name, Value: p.expr()})
					if p.accept(lexer.Comma) {
						if p.tok().Kind == lexer.RBrace {
							break
						}
						continue
					}
					break
				}
			}
			p.expect(lexer.RBrace)
			return s
		}
		return path
	}
	p.failHere()
	return nil
}

func (p *parser) valuePath() *ast.PathExpr {
	first := p.ident()
	pe := &ast.PathExpr{Pos: first.Pos, Name: first}
	if p.accept(lexer.ColonColon) {
		q := first
		pe.Qual = &q
		pe.Name = p.ident()
	}
	return pe
}

func (p *parser) lambda() ast.Expr {
	t := p.next()
	l := &ast.Lambda{Pos: t.Pos}
	if t.Kind == lexer.Pipe {
		for {
			lp := &ast.LParam{Name: p.ident()}
			if p.accept(lexer.Colon) {
				lp.Type = p.typ()
			}
			l.Params = append(l.Params, lp)
			if p.accept(lexer.Comma) {
				if p.tok().Kind == lexer.Pipe {
					break
				}
				continue
			}
			break
		}
		p.expect(lexer.Pipe)
	}
	if p.accept(lexer.Arrow) {
		l.Ret = p.typ()
	}
	if p.tok().Kind == lexer.LBrace {
		l.Body = p.block()
	} else {
		l.Body = p.expr()
	}
	return l
}

func (p *parser) ifExpr() ast.Expr {
	t := p.next()
	e := &ast.IfExpr{Pos: t.Pos}
	e.Cond = p.expr()
	e.Then = p.block()
	if p.accept(lexer.KwElse) {
		if p.tok().Kind == lexer.KwIf {
			e.Else = p.ifExpr()
		} else {
			e.Else = p.block()
		}
	}
	return e
}

func (p *parser) matchExpr() ast.Expr {
	t := p.next()
	m := &ast.MatchExpr{Pos: t.Pos}
	m.Scr = p.expr()
	p.expect(lexer.LBrace)
	for p.tok().Kind != lexer.RBrace {
		arm := &ast.Arm{Pat: p.pattern()}
		if p.accept(lexer.KwWhen) {
			arm.Guard = p.expr()
		}
		p.expect(lexer.Arrow)
		blockBody := false
		if p.tok().Kind == lexer.LBrace {
			arm.Body = p.block()
			blockBody = true
		} else {
			arm.Body = p.expr()
		}
		m.Arms = append(m.Arms, arm)
		if !p.accept(lexer.Comma) {
			if p.tok().Kind != lexer.RBrace && !blockBody {
				p.failHere()
			}
		}
	}
	p.expect(lexer.RBrace)
	return m
}

// ---------------------------------------------------------------- patterns

func (p *parser) pattern() ast.Pattern {
	t := p.tok()
	switch t.Kind {
	case lexer.Underscore:
		p.next()
		return &ast.WildPat{Pos: t.Pos}
	case lexer.Int:
		p.next()
		return &ast.LitPat{Pos: t.Pos, Kind: ast.LitInt, Int: t.Int}
	case lexer.Float:
		p.next()
		return &ast.LitPat{Pos: t.Pos, Kind: ast.LitFloat}
	case lexer.Minus:
		p.next()
		n := p.tok()
		switch n.Kind {
		case lexer.Int:
			p.next()
			return &ast.LitPat{Pos: t.Pos, Kind: ast.LitInt, Int: -n.Int}
		case lexer.Float:
			p.next()
			return &ast.LitPat{Pos: t.Pos, Kind: ast.LitFloat}
		}
		p.failHere()
	case lexer.Str:
		p.next()
		return &ast.LitPat{Pos: t.Pos, Kind: ast.LitStr, Str: t.Str}
	case lexer.Char:
		p.next()
		return &ast.LitPat{Pos: t.Pos, Kind: ast.LitChar, Int: t.Int}
	case lexer.KwTrue:
		p.next()
		return &ast.LitPat{Pos: t.Pos, Kind: ast.LitBool, Int: 1}
	case lexer.KwFalse:
		p.next()
		return &ast.LitPat{Pos: t.Pos, Kind: ast.LitBool, Int: 0}
	case lexer.LParen:
		p.next()
		tp := &ast.TuplePat{Pos: t.Pos}
		tp.Elems = append(tp.Elems, p.pattern())
		p.expect(lexer.Comma)
		for {
			tp.Elems = append(tp.Elems, p.pattern())
			if p.accept(lexer.Comma) {
				if p.tok().Kind == lexer.RParen {
					break
				}
				continue
			}
			break
		}
		p.expect(lexer.RParen)
		return tp
	case lexer.LBracket:
		p.next()
		lp := &ast.ListPat{Pos: t.Pos}
		for p.tok().Kind != lexer.RBracket {
			if p.accept(lexer.DotDot) {
				lp.HasRest = true
				if p.tok().Kind == lexer.Ident {
					r := p.ident()
					lp.Rest = &r
				}
				break
			}
			lp.Elems = append(lp.Elems, p.pattern())
			if !p.accept(lexer.Comma) {
				break
			}
		}
		p.expect(lexer.RBracket)
		return lp
	case lexer.Ident:
		first := p.ident()
		path := &ast.PathExpr{Pos: first.Pos, Name: first}
		if p.accept(lexer.ColonColon) {
			q := first
			path.Qual = &q
			path.Name = p.ident()
		}
		if p.tok().Kind == lexer.Dot && p.peekKind(1) == lexer.LBrace {
			p.next()
			p.next()
			sp := &ast.StructPat{Pos: path.Pos, Path: path}
			for p.tok().Kind != lexer.RBrace {
				if p.accept(lexer.DotDot) {
					sp.HasRest = true
					break
				}
				fp := &ast.FieldPat{Name: p.ident()}
				if p.accept(lexer.Colon) {
					fp.Pat = p.pattern()
				}
				sp.Fields = append(sp.Fields, fp)
				if !p.accept(lexer.Comma) {
					break
				}
			}
			p.expect(lexer.RBrace)
			return sp
		}
		if p.tok().Kind == lexer.LParen {
			p.next()
			vp := &ast.VariantPat{Pos: path.Pos, Path: path}
			for {
				vp.Args = append(vp.Args, p.pattern())
				if p.accept(lexer.Comma) {
					if p.tok().Kind == lexer.RParen {
						break
					}
					continue
				}
				break
			}
			p.expect(lexer.RParen)
			return vp
		}
		if path.Qual != nil {
			return &ast.VariantPat{Pos: path.Pos, Path: path}
		}
		return &ast.IdentPat{Pos: first.Pos, Name: first.Name}
	}
	p.failHere()
	return nil
}
