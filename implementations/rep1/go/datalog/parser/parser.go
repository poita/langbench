// Package parser turns Datalog source text into an [ast.Program].
//
// The grammar is the one described in the repository README: facts, rules
// and queries, each terminated by a dot, with %-comments to end of line.
package parser

import (
	"strconv"

	"example.com/datalog/ast"
)

// Parse parses a whole program. It performs no semantic checks (safety and
// stratification are the job of package analysis). Each `_` is replaced by a
// distinct variable whose name begins with an underscore.
func Parse(src string) (*ast.Program, error) {
	p := &parser{lex: newLexer(src)}
	if err := p.advance(); err != nil {
		return nil, err
	}
	prog := &ast.Program{}
	for p.tok.kind != tEOF {
		p.anon = 0
		if err := p.clause(prog); err != nil {
			return nil, err
		}
	}
	return prog, nil
}

type parser struct {
	lex  *lexer
	tok  token // current token
	peek *token
	anon int
}

func (p *parser) advance() error {
	if p.peek != nil {
		p.tok, p.peek = *p.peek, nil
		return nil
	}
	t, err := p.lex.next()
	if err != nil {
		return err
	}
	p.tok = t
	return nil
}

func (p *parser) lookahead() (token, error) {
	if p.peek == nil {
		t, err := p.lex.next()
		if err != nil {
			return t, err
		}
		p.peek = &t
	}
	return *p.peek, nil
}

func (p *parser) errf(msg string) error {
	return &SyntaxError{Line: p.tok.line, Col: p.tok.col, Msg: msg + ", found " + p.tok.describe()}
}

func (p *parser) expect(k tokKind, what string) error {
	if p.tok.kind != k {
		return p.errf("expected " + what)
	}
	return p.advance()
}

func (p *parser) clause(prog *ast.Program) error {
	line := p.tok.line
	if p.tok.kind == tQuery {
		if err := p.advance(); err != nil {
			return err
		}
		a, err := p.atom()
		if err != nil {
			return err
		}
		if err := p.expect(tDot, "'.'"); err != nil {
			return err
		}
		prog.Queries = append(prog.Queries, a)
		return nil
	}
	head, err := p.atom()
	if err != nil {
		return err
	}
	rule := ast.Rule{Head: head, Line: line}
	if p.tok.kind == tImplies {
		if err := p.advance(); err != nil {
			return err
		}
		for {
			lit, err := p.literal()
			if err != nil {
				return err
			}
			rule.Body = append(rule.Body, lit)
			if p.tok.kind != tComma {
				break
			}
			if err := p.advance(); err != nil {
				return err
			}
		}
	}
	if err := p.expect(tDot, "'.'"); err != nil {
		return err
	}
	prog.Rules = append(prog.Rules, rule)
	return nil
}

func (p *parser) literal() (ast.Literal, error) {
	if p.tok.kind == tNot {
		if err := p.advance(); err != nil {
			return ast.Literal{}, err
		}
		a, err := p.atom()
		return ast.Literal{Kind: ast.Negative, Atom: a}, err
	}
	if p.tok.kind == tIdent {
		next, err := p.lookahead()
		if err != nil {
			return ast.Literal{}, err
		}
		if next.kind == tLParen {
			a, err := p.atom()
			return ast.Literal{Kind: ast.Positive, Atom: a}, err
		}
	}
	left, err := p.term()
	if err != nil {
		return ast.Literal{}, err
	}
	var op ast.CmpOp
	switch p.tok.kind {
	case tEq:
		op = ast.Eq
	case tNe:
		op = ast.Ne
	case tLt:
		op = ast.Lt
	case tLe:
		op = ast.Le
	case tGt:
		op = ast.Gt
	case tGe:
		op = ast.Ge
	default:
		return ast.Literal{}, p.errf("expected comparison operator")
	}
	if err := p.advance(); err != nil {
		return ast.Literal{}, err
	}
	right, err := p.term()
	if err != nil {
		return ast.Literal{}, err
	}
	return ast.Literal{Kind: ast.Comparison, Op: op, Left: left, Right: right}, nil
}

func (p *parser) atom() (ast.Atom, error) {
	if p.tok.kind != tIdent {
		return ast.Atom{}, p.errf("expected predicate name")
	}
	a := ast.Atom{Name: p.tok.text}
	if err := p.advance(); err != nil {
		return a, err
	}
	if err := p.expect(tLParen, "'('"); err != nil {
		return a, err
	}
	for {
		t, err := p.term()
		if err != nil {
			return a, err
		}
		a.Args = append(a.Args, t)
		if p.tok.kind != tComma {
			break
		}
		if err := p.advance(); err != nil {
			return a, err
		}
	}
	return a, p.expect(tRParen, "')'")
}

func (p *parser) term() (ast.Term, error) {
	var t ast.Term
	switch p.tok.kind {
	case tIdent:
		t = ast.Const(ast.Sym(p.tok.text))
	case tInt:
		t = ast.Const(ast.Int(p.tok.num))
	case tVar:
		t = ast.Var(p.tok.text)
	case tAnon:
		p.anon++
		t = ast.Var("_" + strconv.Itoa(p.anon))
	default:
		return t, p.errf("expected term")
	}
	return t, p.advance()
}
