// Package parser is a recursive-descent parser for Vellum (SPEC section 4).
package parser

import (
	"langvm/ast"
	"langvm/diag"
	"langvm/lexer"
)

type parser struct {
	toks []lexer.Token
	i    int
}

type bailout struct{ err *diag.Error }

// Parse parses a token array (as produced by lexer.Lex) into a module. The
// slice is modified in place when a `>>` token is split into two `>`.
func Parse(name string, toks []lexer.Token) (m *ast.Module, err *diag.Error) {
	p := &parser{toks: toks}
	defer func() {
		if r := recover(); r != nil {
			if b, ok := r.(bailout); ok {
				m, err = nil, b.err
				return
			}
			panic(r)
		}
	}()
	m = &ast.Module{Name: name}
	for p.kind() != lexer.EOF {
		m.Items = append(m.Items, p.item())
	}
	return m, nil
}

func (p *parser) tok() *lexer.Token { return &p.toks[p.i] }
func (p *parser) kind() lexer.Kind  { return p.toks[p.i].Kind }
func (p *parser) pos() ast.Pos      { return p.toks[p.i].Pos }
func (p *parser) peekKind(k int) lexer.Kind {
	if p.i+k < len(p.toks) {
		return p.toks[p.i+k].Kind
	}
	return lexer.EOF
}

func (p *parser) fail() {
	panic(bailout{diag.New(diag.Parse, p.pos())})
}

func (p *parser) next() lexer.Token {
	t := p.toks[p.i]
	if t.Kind != lexer.EOF {
		p.i++
	}
	return t
}

func (p *parser) expect(k lexer.Kind) lexer.Token {
	if p.kind() != k {
		p.fail()
	}
	return p.next()
}

func (p *parser) accept(k lexer.Kind) bool {
	if p.kind() == k {
		p.next()
		return true
	}
	return false
}

func (p *parser) ident() ast.Ident {
	t := p.expect(lexer.Ident)
	return ast.Ident{Name: t.Text, Pos: t.Pos}
}

// ------------------------------------------------------------------- items

func (p *parser) item() ast.Item {
	switch p.kind() {
	case lexer.KwUse:
		return p.useDecl()
	case lexer.KwImpl:
		return p.implDecl()
	case lexer.KwPub:
		p.next()
		switch p.kind() {
		case lexer.KwFn:
			f := p.fnDecl(false)
			f.Pub = true
			return f
		case lexer.KwStruct:
			s := p.structDecl()
			s.Pub = true
			return s
		case lexer.KwEnum:
			e := p.enumDecl()
			e.Pub = true
			return e
		case lexer.KwTrait:
			t := p.traitDecl()
			t.Pub = true
			return t
		}
		p.fail()
	case lexer.KwFn:
		return p.fnDecl(false)
	case lexer.KwStruct:
		return p.structDecl()
	case lexer.KwEnum:
		return p.enumDecl()
	case lexer.KwTrait:
		return p.traitDecl()
	}
	p.fail()
	return nil
}

func (p *parser) useDecl() *ast.UseDecl {
	u := &ast.UseDecl{Pos: p.next().Pos}
	u.Module = p.ident()
	if p.accept(lexer.KwAs) {
		a := p.ident()
		u.Alias = &a
	}
	p.expect(lexer.Semi)
	return u
}

func (p *parser) generics(allowBounds bool) []*ast.GenParam {
	if p.kind() != lexer.Lt {
		return nil
	}
	p.next()
	var out []*ast.GenParam
	for {
		g := &ast.GenParam{Name: p.ident()}
		if p.kind() == lexer.Colon {
			if !allowBounds {
				p.fail()
			}
			p.next()
			g.Bounds = append(g.Bounds, p.traitRef())
			for p.accept(lexer.Plus) {
				g.Bounds = append(g.Bounds, p.traitRef())
			}
		}
		out = append(out, g)
		if p.accept(lexer.Comma) {
			if p.kind() == lexer.Gt || p.kind() == lexer.Shr {
				break
			}
			continue
		}
		break
	}
	p.closeAngle()
	return out
}

func (p *parser) closeAngle() {
	switch p.kind() {
	case lexer.Gt:
		p.next()
	case lexer.Shr:
		t := p.tok()
		t.Kind = lexer.Gt
		t.Pos.Col++
	default:
		p.fail()
	}
}

func (p *parser) traitRef() *ast.TraitRef {
	first := p.ident()
	tr := &ast.TraitRef{Pos: first.Pos, Name: first}
	if p.accept(lexer.ColonColon) {
		m := first
		tr.Mod = &m
		tr.Name = p.ident()
	}
	return tr
}

func (p *parser) params() []*ast.Param {
	var out []*ast.Param
	for {
		name := p.ident()
		p.expect(lexer.Colon)
		out = append(out, &ast.Param{Name: name, Type: p.typ()})
		if p.accept(lexer.Comma) {
			if p.kind() == lexer.RParen {
				break
			}
			continue
		}
		break
	}
	return out
}

// fnDecl parses a function; with method set it parses a trait/impl method.
func (p *parser) fnDecl(method bool) *ast.FnDecl {
	f := &ast.FnDecl{Pos: p.expect(lexer.KwFn).Pos, IsMethod: method}
	f.Name = p.ident()
	if !method {
		f.Generics = p.generics(true)
	}
	p.expect(lexer.LParen)
	if method {
		p.expect(lexer.KwSelf)
		if p.accept(lexer.Comma) {
			f.Params = p.params()
		}
	} else if p.kind() != lexer.RParen {
		f.Params = p.params()
	}
	p.expect(lexer.RParen)
	if p.accept(lexer.Arrow) {
		f.Ret = p.typ()
	}
	if method && p.kind() == lexer.Semi {
		p.next()
		return f
	}
	f.Body = p.block()
	return f
}

func (p *parser) structDecl() *ast.StructDecl {
	s := &ast.StructDecl{Pos: p.next().Pos}
	s.Name = p.ident()
	s.Generics = p.generics(false)
	p.expect(lexer.LBrace)
	for p.kind() != lexer.RBrace {
		name := p.ident()
		p.expect(lexer.Colon)
		s.Fields = append(s.Fields, &ast.Field{Name: name, Type: p.typ()})
		if !p.accept(lexer.Comma) {
			break
		}
	}
	p.expect(lexer.RBrace)
	return s
}

func (p *parser) enumDecl() *ast.EnumDecl {
	e := &ast.EnumDecl{Pos: p.next().Pos}
	e.Name = p.ident()
	e.Generics = p.generics(false)
	p.expect(lexer.LBrace)
	for p.kind() != lexer.RBrace {
		v := &ast.Variant{Name: p.ident()}
		if p.accept(lexer.LParen) {
			for {
				v.Payload = append(v.Payload, p.typ())
				if p.accept(lexer.Comma) {
					if p.kind() == lexer.RParen {
						break
					}
					continue
				}
				break
			}
			p.expect(lexer.RParen)
		}
		e.Variants = append(e.Variants, v)
		if !p.accept(lexer.Comma) {
			break
		}
	}
	p.expect(lexer.RBrace)
	return e
}

func (p *parser) traitDecl() *ast.TraitDecl {
	t := &ast.TraitDecl{Pos: p.next().Pos}
	t.Name = p.ident()
	p.expect(lexer.LBrace)
	for p.kind() != lexer.RBrace {
		t.Methods = append(t.Methods, p.fnDecl(true))
	}
	p.expect(lexer.RBrace)
	return t
}

func (p *parser) implDecl() *ast.ImplDecl {
	d := &ast.ImplDecl{Pos: p.next().Pos}
	d.Generics = p.generics(true)
	d.Trait = p.traitRef()
	p.expect(lexer.KwFor)
	d.Head = p.typ()
	p.expect(lexer.LBrace)
	for p.kind() != lexer.RBrace {
		m := p.fnDecl(true)
		if m.Body == nil {
			// An impl method must have a body: the `;` form was accepted
			// by fnDecl, so reject it here at the semicolon's position.
			p.i--
			p.fail()
		}
		d.Methods = append(d.Methods, m)
	}
	p.expect(lexer.RBrace)
	return d
}

// -------------------------------------------------------------------- types

func (p *parser) typ() *ast.TypeExpr {
	start := p.pos()
	switch p.kind() {
	case lexer.LBracket:
		p.next()
		t := p.typ()
		p.expect(lexer.RBracket)
		return &ast.TypeExpr{Kind: ast.TList, Pos: start, Args: []*ast.TypeExpr{t}}
	case lexer.HashBracket:
		p.next()
		k := p.typ()
		p.expect(lexer.Colon)
		v := p.typ()
		p.expect(lexer.RBracket)
		return &ast.TypeExpr{Kind: ast.TMap, Pos: start, Args: []*ast.TypeExpr{k, v}}
	case lexer.LParen:
		p.next()
		args := []*ast.TypeExpr{p.typ()}
		p.expect(lexer.Comma)
		for p.kind() != lexer.RParen {
			args = append(args, p.typ())
			if !p.accept(lexer.Comma) {
				break
			}
		}
		p.expect(lexer.RParen)
		return &ast.TypeExpr{Kind: ast.TTuple, Pos: start, Args: args}
	case lexer.KwFn:
		p.next()
		p.expect(lexer.LParen)
		var args []*ast.TypeExpr
		for p.kind() != lexer.RParen {
			args = append(args, p.typ())
			if !p.accept(lexer.Comma) {
				break
			}
		}
		p.expect(lexer.RParen)
		t := &ast.TypeExpr{Kind: ast.TFn, Pos: start, Args: args}
		if p.accept(lexer.Arrow) {
			t.Ret = p.typ()
		}
		return t
	case lexer.Ident:
		first := p.ident()
		t := &ast.TypeExpr{Kind: ast.TPath, Pos: start, Name: first}
		if p.accept(lexer.ColonColon) {
			m := first
			t.Mod = &m
			t.Name = p.ident()
		}
		if p.kind() == lexer.Lt {
			p.next()
			for {
				t.Args = append(t.Args, p.typ())
				if p.accept(lexer.Comma) {
					if p.kind() == lexer.Gt || p.kind() == lexer.Shr {
						break
					}
					continue
				}
				break
			}
			p.closeAngle()
		}
		return t
	}
	p.fail()
	return nil
}

// ------------------------------------------------------------------- blocks

func (p *parser) block() *ast.Block {
	b := &ast.Block{P: p.expect(lexer.LBrace).Pos}
	for p.kind() != lexer.RBrace {
		switch p.kind() {
		case lexer.KwLet:
			b.Stmts = append(b.Stmts, p.letStmt())
		case lexer.KwVar:
			b.Stmts = append(b.Stmts, p.varStmt())
		case lexer.KwReturn:
			r := &ast.ReturnStmt{P: p.next().Pos}
			if p.kind() != lexer.Semi {
				r.X = p.expr()
			}
			p.expect(lexer.Semi)
			b.Stmts = append(b.Stmts, r)
		case lexer.KwWhile:
			w := &ast.WhileStmt{P: p.next().Pos}
			w.Cond = p.expr()
			w.Body = p.block()
			b.Stmts = append(b.Stmts, w)
		case lexer.KwFor:
			b.Stmts = append(b.Stmts, p.forStmt())
		case lexer.KwBreak:
			s := &ast.BreakStmt{P: p.next().Pos}
			p.expect(lexer.Semi)
			b.Stmts = append(b.Stmts, s)
		case lexer.KwContinue:
			s := &ast.ContinueStmt{P: p.next().Pos}
			p.expect(lexer.Semi)
			b.Stmts = append(b.Stmts, s)
		default:
			e := p.expr()
			switch p.kind() {
			case lexer.Assign:
				pos := p.next().Pos
				v := p.expr()
				p.expect(lexer.Semi)
				b.Stmts = append(b.Stmts, &ast.AssignStmt{P: pos, Target: e, Value: v})
			case lexer.Semi:
				p.next()
				b.Stmts = append(b.Stmts, &ast.ExprStmt{X: e})
			case lexer.RBrace:
				b.Tail = e
			default:
				switch e.(type) {
				case *ast.IfExpr, *ast.MatchExpr:
					b.Stmts = append(b.Stmts, &ast.ExprStmt{X: e})
				default:
					p.fail()
				}
			}
		}
	}
	p.expect(lexer.RBrace)
	b.Div = b.Tail != nil && ast.Diverges(b.Tail)
	if !b.Div {
		for _, s := range b.Stmts {
			if ast.StmtDiverges(s) {
				b.Div = true
				break
			}
		}
	}
	return b
}

func (p *parser) letStmt() ast.Stmt {
	s := &ast.LetStmt{P: p.next().Pos}
	s.Pat = p.pattern()
	if p.accept(lexer.Colon) {
		s.Type = p.typ()
	}
	p.expect(lexer.Assign)
	s.Init = p.expr()
	p.expect(lexer.Semi)
	return s
}

func (p *parser) varStmt() ast.Stmt {
	s := &ast.VarStmt{P: p.next().Pos}
	s.Name = p.ident()
	if p.accept(lexer.Colon) {
		s.Type = p.typ()
	}
	p.expect(lexer.Assign)
	s.Init = p.expr()
	p.expect(lexer.Semi)
	return s
}

func (p *parser) forStmt() ast.Stmt {
	s := &ast.ForStmt{P: p.next().Pos}
	s.Pat = p.pattern()
	p.expect(lexer.KwIn)
	s.Seq = p.expr()
	if p.accept(lexer.DotDot) {
		s.Hi = p.expr()
	}
	s.Body = p.block()
	return s
}

// -------------------------------------------------------------- expressions

func (p *parser) expr() ast.Expr { return p.binary(1) }

func isCmp(k lexer.Kind) bool {
	switch k {
	case lexer.EqEq, lexer.NotEq, lexer.Lt, lexer.Le, lexer.Gt, lexer.Ge:
		return true
	}
	return false
}

func binOp(k lexer.Kind, level int) (ast.BinOp, bool) {
	switch level {
	case 1:
		if k == lexer.OrOr {
			return ast.OpOr, true
		}
	case 2:
		if k == lexer.AndAnd {
			return ast.OpAnd, true
		}
	case 4:
		if k == lexer.Pipe {
			return ast.OpBitOr, true
		}
	case 5:
		if k == lexer.Caret {
			return ast.OpBitXor, true
		}
	case 6:
		if k == lexer.Amp {
			return ast.OpBitAnd, true
		}
	case 7:
		switch k {
		case lexer.Shl:
			return ast.OpShl, true
		case lexer.Shr:
			return ast.OpShr, true
		}
	case 8:
		switch k {
		case lexer.Plus:
			return ast.OpAdd, true
		case lexer.Minus:
			return ast.OpSub, true
		case lexer.PlusPlus:
			return ast.OpConcat, true
		}
	case 9:
		switch k {
		case lexer.Star:
			return ast.OpMul, true
		case lexer.Slash:
			return ast.OpDiv, true
		case lexer.Percent:
			return ast.OpMod, true
		}
	}
	return 0, false
}

func cmpOp(k lexer.Kind) ast.BinOp {
	switch k {
	case lexer.EqEq:
		return ast.OpEq
	case lexer.NotEq:
		return ast.OpNe
	case lexer.Lt:
		return ast.OpLt
	case lexer.Le:
		return ast.OpLe
	case lexer.Gt:
		return ast.OpGt
	}
	return ast.OpGe
}

func (p *parser) binary(level int) ast.Expr {
	if level > 9 {
		return p.unary()
	}
	left := p.binary(level + 1)
	if level == 3 {
		if isCmp(p.kind()) {
			t := p.next()
			right := p.binary(4)
			left = &ast.Binary{Op: cmpOp(t.Kind), OpP: t.Pos, L: left, R: right}
		}
		return left
	}
	for {
		op, ok := binOp(p.kind(), level)
		if !ok {
			return left
		}
		t := p.next()
		right := p.binary(level + 1)
		left = &ast.Binary{Op: op, OpP: t.Pos, L: left, R: right}
	}
}

func (p *parser) unary() ast.Expr {
	switch p.kind() {
	case lexer.Minus:
		t := p.next()
		return &ast.Unary{P: t.Pos, Op: ast.OpNeg, X: p.unary()}
	case lexer.Bang:
		t := p.next()
		return &ast.Unary{P: t.Pos, Op: ast.OpNot, X: p.unary()}
	case lexer.Tilde:
		t := p.next()
		return &ast.Unary{P: t.Pos, Op: ast.OpBitNot, X: p.unary()}
	}
	return p.postfix()
}

func (p *parser) args(close lexer.Kind) []ast.Expr {
	var out []ast.Expr
	for p.kind() != close {
		out = append(out, p.expr())
		if !p.accept(lexer.Comma) {
			break
		}
	}
	p.expect(close)
	return out
}

func (p *parser) postfix() ast.Expr {
	e := p.primary()
	for {
		switch p.kind() {
		case lexer.LParen:
			p.next()
			e = &ast.Call{Callee: e, Args: p.args(lexer.RParen)}
		case lexer.LBracket:
			p.next()
			idx := p.expr()
			p.expect(lexer.RBracket)
			e = &ast.IndexExpr{X: e, Index: idx}
		case lexer.Dot:
			p.next()
			name := p.ident()
			if p.kind() == lexer.LParen {
				p.next()
				e = &ast.MethodCall{Recv: e, Name: name, Args: p.args(lexer.RParen)}
			} else {
				e = &ast.FieldExpr{X: e, Name: name}
			}
		default:
			return e
		}
	}
}

func (p *parser) primary() ast.Expr {
	t := p.tok()
	pos := t.Pos
	switch t.Kind {
	case lexer.IntLit:
		p.next()
		return &ast.IntLit{P: pos, Val: t.Int}
	case lexer.FloatLit:
		p.next()
		return &ast.FloatLit{P: pos, Val: t.Float}
	case lexer.StrLit:
		p.next()
		return &ast.StrLit{P: pos, Val: t.Str}
	case lexer.CharLit:
		p.next()
		return &ast.CharLit{P: pos, Val: rune(t.Int)}
	case lexer.KwTrue:
		p.next()
		return &ast.BoolLit{P: pos, Val: true}
	case lexer.KwFalse:
		p.next()
		return &ast.BoolLit{P: pos, Val: false}
	case lexer.KwSelf:
		p.next()
		return &ast.SelfExpr{P: pos}
	case lexer.LParen:
		p.next()
		first := p.expr()
		if p.kind() == lexer.Comma {
			elems := []ast.Expr{first}
			for p.accept(lexer.Comma) {
				if len(elems) >= 2 && p.kind() == lexer.RParen {
					break
				}
				elems = append(elems, p.expr())
			}
			p.expect(lexer.RParen)
			return &ast.TupleLit{P: pos, Elems: elems}
		}
		p.expect(lexer.RParen)
		return first
	case lexer.LBracket:
		p.next()
		return &ast.ListLit{P: pos, Elems: p.args(lexer.RBracket)}
	case lexer.HashBracket:
		p.next()
		m := &ast.MapLit{P: pos}
		for p.kind() != lexer.RBracket {
			k := p.expr()
			p.expect(lexer.Colon)
			v := p.expr()
			m.Keys = append(m.Keys, k)
			m.Vals = append(m.Vals, v)
			if !p.accept(lexer.Comma) {
				break
			}
		}
		p.expect(lexer.RBracket)
		return m
	case lexer.OrOr:
		p.next()
		return p.lambdaRest(pos, nil)
	case lexer.Pipe:
		p.next()
		var ps []*ast.LParam
		for {
			lp := &ast.LParam{Name: p.ident()}
			if p.accept(lexer.Colon) {
				lp.Type = p.typ()
			}
			ps = append(ps, lp)
			if p.accept(lexer.Comma) {
				if p.kind() == lexer.Pipe {
					break
				}
				continue
			}
			break
		}
		p.expect(lexer.Pipe)
		return p.lambdaRest(pos, ps)
	case lexer.KwIf:
		return p.ifExpr()
	case lexer.KwMatch:
		return p.matchExpr()
	case lexer.Ident:
		first := p.ident()
		path := &ast.PathExpr{P: pos, Name: first}
		if p.accept(lexer.ColonColon) {
			m := first
			path.Mod = &m
			path.Name = p.ident()
		}
		if p.kind() == lexer.Dot && p.peekKind(1) == lexer.LBrace {
			p.next()
			p.next()
			sl := &ast.StructLit{P: pos, Mod: path.Mod, Name: path.Name}
			for p.kind() != lexer.RBrace {
				name := p.ident()
				p.expect(lexer.Colon)
				sl.Fields = append(sl.Fields, &ast.FieldInit{Name: name, X: p.expr()})
				if !p.accept(lexer.Comma) {
					break
				}
			}
			p.expect(lexer.RBrace)
			return sl
		}
		return path
	}
	p.fail()
	return nil
}

func (p *parser) lambdaRest(pos ast.Pos, ps []*ast.LParam) ast.Expr {
	l := &ast.Lambda{P: pos, Params: ps}
	if p.accept(lexer.Arrow) {
		l.Ret = p.typ()
	}
	if p.kind() == lexer.LBrace {
		l.Body = p.block()
	} else {
		l.Body = p.expr()
	}
	return l
}

func (p *parser) ifExpr() ast.Expr {
	e := &ast.IfExpr{P: p.next().Pos}
	e.Cond = p.expr()
	e.Then = p.block()
	if p.accept(lexer.KwElse) {
		if p.kind() == lexer.KwIf {
			e.Else = p.ifExpr()
		} else {
			e.Else = p.block()
		}
		e.Div = e.Then.Div && ast.Diverges(e.Else)
	}
	return e
}

func (p *parser) matchExpr() ast.Expr {
	m := &ast.MatchExpr{P: p.next().Pos}
	m.Scrut = p.expr()
	p.expect(lexer.LBrace)
	for p.kind() != lexer.RBrace {
		arm := &ast.Arm{Pat: p.pattern()}
		if p.accept(lexer.KwWhen) {
			arm.Guard = p.expr()
		}
		p.expect(lexer.Arrow)
		isBlock := p.kind() == lexer.LBrace
		if isBlock {
			arm.Body = p.block()
		} else {
			arm.Body = p.expr()
		}
		m.Arms = append(m.Arms, arm)
		if !p.accept(lexer.Comma) {
			if p.kind() != lexer.RBrace && !isBlock {
				p.fail()
			}
		}
	}
	p.expect(lexer.RBrace)
	if len(m.Arms) > 0 {
		m.Div = true
		for _, a := range m.Arms {
			if !ast.Diverges(a.Body) {
				m.Div = false
				break
			}
		}
	}
	return m
}

// ----------------------------------------------------------------- patterns

func (p *parser) pattern() ast.Pattern {
	t := p.tok()
	pos := t.Pos
	switch t.Kind {
	case lexer.Underscore:
		p.next()
		return &ast.WildPat{P: pos}
	case lexer.IntLit:
		p.next()
		return &ast.LitPat{P: pos, Kind: ast.LitInt, Int: t.Int}
	case lexer.FloatLit:
		p.next()
		return &ast.LitPat{P: pos, Kind: ast.LitFloat}
	case lexer.Minus:
		p.next()
		n := p.tok()
		switch n.Kind {
		case lexer.IntLit:
			p.next()
			return &ast.LitPat{P: pos, Kind: ast.LitInt, Neg: true, Int: n.Int}
		case lexer.FloatLit:
			p.next()
			return &ast.LitPat{P: pos, Kind: ast.LitFloat, Neg: true}
		}
		p.fail()
	case lexer.StrLit:
		p.next()
		return &ast.LitPat{P: pos, Kind: ast.LitStr, Str: t.Str}
	case lexer.CharLit:
		p.next()
		return &ast.LitPat{P: pos, Kind: ast.LitChar, Int: t.Int}
	case lexer.KwTrue:
		p.next()
		return &ast.LitPat{P: pos, Kind: ast.LitBool, Bool: true}
	case lexer.KwFalse:
		p.next()
		return &ast.LitPat{P: pos, Kind: ast.LitBool, Bool: false}
	case lexer.LParen:
		p.next()
		elems := []ast.Pattern{p.pattern()}
		p.expect(lexer.Comma)
		for p.kind() != lexer.RParen {
			elems = append(elems, p.pattern())
			if !p.accept(lexer.Comma) {
				break
			}
		}
		p.expect(lexer.RParen)
		return &ast.TuplePat{P: pos, Elems: elems}
	case lexer.LBracket:
		p.next()
		lp := &ast.ListPat{P: pos}
		for {
			if p.kind() == lexer.DotDot {
				p.next()
				lp.HasRest = true
				if p.kind() == lexer.Ident {
					id := p.ident()
					lp.RestName = &id
				}
				p.expect(lexer.RBracket)
				break
			}
			if p.kind() == lexer.RBracket {
				p.next()
				break
			}
			lp.Elems = append(lp.Elems, p.pattern())
			if p.accept(lexer.Comma) {
				continue
			}
			p.expect(lexer.RBracket)
			break
		}
		return lp
	case lexer.Ident:
		first := p.ident()
		var mod *ast.Ident
		name := first
		if p.accept(lexer.ColonColon) {
			m := first
			mod = &m
			name = p.ident()
		}
		if p.kind() == lexer.Dot && p.peekKind(1) == lexer.LBrace {
			p.next()
			p.next()
			sp := &ast.StructPat{P: pos, Mod: mod, Name: name}
			for p.kind() != lexer.RBrace {
				if p.kind() == lexer.DotDot {
					p.next()
					sp.Rest = true
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
		if p.kind() == lexer.LParen {
			p.next()
			vp := &ast.VariantPat{P: pos, Mod: mod, Name: name}
			for {
				vp.Args = append(vp.Args, p.pattern())
				if p.accept(lexer.Comma) {
					if p.kind() == lexer.RParen {
						break
					}
					continue
				}
				break
			}
			p.expect(lexer.RParen)
			return vp
		}
		return &ast.NamePat{P: pos, Mod: mod, Name: name}
	}
	p.fail()
	return nil
}
