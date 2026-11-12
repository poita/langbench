package syntax

import (
	"fmt"
	"io"
)

// Parser parses a program one declaration at a time.
type Parser struct {
	lex *Lexer
	tok Token // current token
	err error // sticky error from the lexer
}

// NewParser returns a Parser for the program text src.
func NewParser(src string) *Parser {
	p := &Parser{lex: NewLexer(src)}
	p.advance()
	return p
}

// ParseProgram parses a whole program into its declarations.
func ParseProgram(src string) ([]Decl, error) {
	p := NewParser(src)
	var decls []Decl
	for {
		d, err := p.Next()
		if err == io.EOF {
			return decls, nil
		}
		if err != nil {
			return decls, err
		}
		decls = append(decls, d)
	}
}

// ParseExpr parses a single expression (without a trailing ;;).
func ParseExpr(src string) (Expr, error) {
	p := NewParser(src)
	e := p.parseExprRecover()
	if p.err == nil && p.tok.Kind != TokEOF {
		p.fail("unexpected %s after expression", p.tok.describe())
	}
	if p.err != nil {
		return nil, p.err
	}
	return e, nil
}

// Next parses the next declaration. It returns io.EOF when the input is
// exhausted, and a *Error if the input is malformed.
func (p *Parser) Next() (d Decl, err error) {
	if p.err != nil {
		return Decl{}, p.err
	}
	if p.tok.Kind == TokEOF {
		return Decl{}, io.EOF
	}
	defer func() {
		if r := recover(); r != nil {
			e, ok := r.(*Error)
			if !ok {
				panic(r)
			}
			p.err = e
			d, err = Decl{}, e
		}
	}()
	d = p.parseDecl()
	return d, nil
}

func (t Token) describe() string {
	switch t.Kind {
	case TokEOF:
		return "end of input"
	case TokInt, TokIdent:
		return fmt.Sprintf("%q", t.Text)
	}
	return fmt.Sprintf("token #%d", t.Kind)
}

// fail aborts parsing with a syntax error at the current token.
func (p *Parser) fail(format string, args ...any) {
	e := &Error{Pos: p.tok.Pos, Msg: fmt.Sprintf(format, args...)}
	if p.err == nil {
		p.err = e
	}
	panic(e)
}

func (p *Parser) advance() {
	t, err := p.lex.Next()
	if err != nil {
		p.err = err
		p.tok = Token{Kind: TokEOF, Pos: p.lex.pos}
		return
	}
	p.tok = t
}

// next advances to the next token, aborting parsing on a lexical error.
func (p *Parser) next() {
	p.advance()
	if p.err != nil {
		panic(p.err)
	}
}

func (p *Parser) expect(k TokenKind, what string) Token {
	if p.tok.Kind != k {
		p.fail("expected %s, found %s", what, p.tok.describe())
	}
	t := p.tok
	p.next()
	return t
}

func (p *Parser) parseExprRecover() (e Expr) {
	defer func() {
		if r := recover(); r != nil {
			if _, ok := r.(*Error); !ok {
				panic(r)
			}
		}
	}()
	return p.parseExpr()
}

// decl := "let" ["rec"] ident ident* "=" expr ";;" | expr ";;"
func (p *Parser) parseDecl() Decl {
	var d Decl
	if p.tok.Kind == TokLet {
		p.next()
		name, rec, value := p.parseBinding()
		d = Decl{Name: name, Rec: rec, Expr: value}
	} else {
		d = Decl{Expr: p.parseExpr()}
	}
	p.expect(TokDSemi, "';;'")
	return d
}

// parseBinding parses what follows "let": ["rec"] ident ident* "=" expr, with
// the parameters desugared into lambdas.
func (p *Parser) parseBinding() (name string, rec bool, value Expr) {
	if p.tok.Kind == TokRec {
		rec = true
		p.next()
	}
	name = p.expect(TokIdent, "identifier").Text
	var params []string
	for p.tok.Kind == TokIdent {
		params = append(params, p.tok.Text)
		p.next()
	}
	if rec && len(params) == 0 {
		p.fail("let rec needs at least one parameter")
	}
	p.expect(TokEq, "'='")
	value = p.parseExpr()
	for i := len(params) - 1; i >= 0; i-- {
		value = &Lam{Param: params[i], Body: value}
	}
	return name, rec, value
}

// expr := let | fun | if | or
func (p *Parser) parseExpr() Expr {
	switch p.tok.Kind {
	case TokLet:
		p.next()
		name, rec, value := p.parseBinding()
		p.expect(TokIn, "'in'")
		body := p.parseExpr()
		return &Let{Name: name, Rec: rec, Value: value, Body: body}
	case TokFun:
		p.next()
		var params []string
		for p.tok.Kind == TokIdent {
			params = append(params, p.tok.Text)
			p.next()
		}
		if len(params) == 0 {
			p.fail("fun needs at least one parameter")
		}
		p.expect(TokArrow, "'->'")
		body := p.parseExpr()
		for i := len(params) - 1; i >= 0; i-- {
			body = &Lam{Param: params[i], Body: body}
		}
		return body
	case TokIf:
		p.next()
		c := p.parseExpr()
		p.expect(TokThen, "'then'")
		a := p.parseExpr()
		p.expect(TokElse, "'else'")
		b := p.parseExpr()
		return &If{Cond: c, Then: a, Else: b}
	}
	return p.parseOr()
}

func (p *Parser) parseOr() Expr {
	e := p.parseAnd()
	for p.tok.Kind == TokOr {
		p.next()
		e = &BinOp{Op: OpOr, L: e, R: p.parseAnd()}
	}
	return e
}

func (p *Parser) parseAnd() Expr {
	e := p.parseCmp()
	for p.tok.Kind == TokAnd {
		p.next()
		e = &BinOp{Op: OpAnd, L: e, R: p.parseCmp()}
	}
	return e
}

func (p *Parser) parseCmp() Expr {
	e := p.parseCons()
	var op Op
	switch p.tok.Kind {
	case TokEq:
		op = OpEq
	case TokLt:
		op = OpLt
	case TokGt:
		op = OpGt
	case TokLe:
		op = OpLe
	case TokGe:
		op = OpGe
	default:
		return e
	}
	p.next()
	return &BinOp{Op: op, L: e, R: p.parseCons()}
}

func (p *Parser) parseCons() Expr {
	e := p.parseAdd()
	if p.tok.Kind == TokCons {
		p.next()
		return &Cons{Head: e, Tail: p.parseCons()}
	}
	return e
}

func (p *Parser) parseAdd() Expr {
	e := p.parseMul()
	for {
		var op Op
		switch p.tok.Kind {
		case TokPlus:
			op = OpAdd
		case TokMinus:
			op = OpSub
		default:
			return e
		}
		p.next()
		e = &BinOp{Op: op, L: e, R: p.parseMul()}
	}
}

func (p *Parser) parseMul() Expr {
	e := p.parseApp()
	for {
		var op Op
		switch p.tok.Kind {
		case TokStar:
			op = OpMul
		case TokSlash:
			op = OpDiv
		default:
			return e
		}
		p.next()
		e = &BinOp{Op: op, L: e, R: p.parseApp()}
	}
}

func (p *Parser) startsAtom() bool {
	switch p.tok.Kind {
	case TokInt, TokIdent, TokTrue, TokFalse, TokLParen, TokLBrack:
		return true
	}
	return false
}

func (p *Parser) parseApp() Expr {
	e := p.parseAtom()
	for p.startsAtom() {
		e = &App{Fn: e, Arg: p.parseAtom()}
	}
	return e
}

func (p *Parser) parseAtom() Expr {
	switch p.tok.Kind {
	case TokInt:
		t := p.tok.Text
		p.next()
		return &IntLit{Text: t}
	case TokTrue:
		p.next()
		return &BoolLit{Value: true}
	case TokFalse:
		p.next()
		return &BoolLit{Value: false}
	case TokIdent:
		n := p.tok.Text
		p.next()
		return &Var{Name: n}
	case TokLParen:
		p.next()
		if p.tok.Kind == TokRParen {
			p.next()
			return &UnitLit{}
		}
		e := p.parseExpr()
		if p.tok.Kind == TokComma {
			elems := []Expr{e}
			for p.tok.Kind == TokComma {
				p.next()
				elems = append(elems, p.parseExpr())
			}
			e = &Tuple{Elems: elems}
		}
		p.expect(TokRParen, "')'")
		return e
	case TokLBrack:
		p.next()
		var elems []Expr
		if p.tok.Kind != TokRBrack {
			elems = append(elems, p.parseExpr())
			for p.tok.Kind == TokSemi {
				p.next()
				elems = append(elems, p.parseExpr())
			}
		}
		p.expect(TokRBrack, "']'")
		return &List{Elems: elems}
	}
	p.fail("unexpected %s", p.tok.describe())
	return nil
}
