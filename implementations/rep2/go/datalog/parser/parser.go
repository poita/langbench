// Package parser turns Datalog source text into an ast.Program.
//
// The accepted language is described in the repository README: facts, rules
// with positive, negated and comparison literals, and "?-" queries, with
// "%" line comments.
package parser

import (
	"fmt"
	"strconv"

	"example.com/datalog/ast"
)

// Parse parses a whole program. It returns a *SyntaxError for malformed
// input. Parsing does not check safety or stratification; see package
// analysis.
func Parse(src string) (*ast.Program, error) {
	p := &parser{lex: lexer{src: src}}
	if err := p.advance(); err != nil {
		return nil, err
	}
	prog := &ast.Program{}
	for p.tok.kind != tEOF {
		if err := p.clause(prog); err != nil {
			return nil, err
		}
	}
	return prog, nil
}

// ParseAtom parses a single atom (a query pattern), with or without a leading
// "?-" and a trailing ".".
func ParseAtom(src string) (ast.Atom, error) {
	p := &parser{lex: lexer{src: src}}
	if err := p.advance(); err != nil {
		return ast.Atom{}, err
	}
	if p.tok.kind == tQuery {
		if err := p.advance(); err != nil {
			return ast.Atom{}, err
		}
	}
	a, err := p.atom()
	if err != nil {
		return a, err
	}
	if p.tok.kind == tDot {
		if err := p.advance(); err != nil {
			return a, err
		}
	}
	if p.tok.kind != tEOF {
		return a, p.unexpected("end of input")
	}
	return a, nil
}

type parser struct {
	lex  lexer
	tok  token
	anon int
}

func (p *parser) advance() error {
	t, err := p.lex.next()
	if err != nil {
		return err
	}
	p.tok = t
	return nil
}

func (p *parser) unexpected(want string) error {
	got := p.tok.text
	if p.tok.kind == tEOF {
		got = "end of input"
	}
	return p.lex.errorf(p.tok.pos, "expected %s, found %q", want, got)
}

func (p *parser) expect(k tokKind, what string) error {
	if p.tok.kind != k {
		return p.unexpected(what)
	}
	return p.advance()
}

func (p *parser) clause(prog *ast.Program) error {
	if p.tok.kind == tQuery {
		if err := p.advance(); err != nil {
			return err
		}
		a, err := p.atom()
		if err != nil {
			return err
		}
		if err := p.expect(tDot, "\".\""); err != nil {
			return err
		}
		prog.Queries = append(prog.Queries, a)
		return nil
	}
	head, err := p.atom()
	if err != nil {
		return err
	}
	rule := ast.Rule{Head: head}
	if p.tok.kind == tRule {
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
	if err := p.expect(tDot, "\".\""); err != nil {
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
		// Either an atom (identifier followed by "(") or a constant
		// on the left of a comparison.
		save, savePos := p.tok, p.lex.pos
		if err := p.advance(); err != nil {
			return ast.Literal{}, err
		}
		isAtom := p.tok.kind == tLParen
		p.tok, p.lex.pos = save, savePos
		if isAtom {
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
	case tEQ:
		op = ast.EQ
	case tNE:
		op = ast.NE
	case tLT:
		op = ast.LT
	case tLE:
		op = ast.LE
	case tGT:
		op = ast.GT
	case tGE:
		op = ast.GE
	default:
		return ast.Literal{}, p.unexpected("comparison operator")
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
		return ast.Atom{}, p.unexpected("predicate name")
	}
	a := ast.Atom{Pred: p.tok.text}
	if err := p.advance(); err != nil {
		return a, err
	}
	if err := p.expect(tLParen, "\"(\""); err != nil {
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
	return a, p.expect(tRParen, "\")\"")
}

func (p *parser) term() (ast.Term, error) {
	t := p.tok
	var res ast.Term
	switch t.kind {
	case tIdent:
		res = ast.C(ast.Sym(t.text))
	case tVar:
		res = ast.V(t.text)
	case tAnon:
		res = ast.V(fmt.Sprintf("_%d", p.anon))
		p.anon++
	case tInt:
		n, err := strconv.ParseInt(t.text, 10, 64)
		if err != nil {
			return res, p.lex.errorf(t.pos, "integer out of range: %s", t.text)
		}
		res = ast.C(ast.Int(n))
	default:
		return res, p.unexpected("term")
	}
	return res, p.advance()
}
