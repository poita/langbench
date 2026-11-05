package parser

import "fmt"

type tokKind uint8

const (
	tEOF tokKind = iota
	tIdent
	tVar
	tAnon
	tInt
	tNot
	tLParen
	tRParen
	tComma
	tDot
	tNeck  // :-
	tQuery // ?-
	tLt
	tLe
	tGt
	tGe
	tEq
	tNe
)

var tokNames = [...]string{
	tEOF: "end of input", tIdent: "identifier", tVar: "variable", tAnon: "_",
	tInt: "integer", tNot: "not", tLParen: "(", tRParen: ")", tComma: ",",
	tDot: ".", tNeck: ":-", tQuery: "?-", tLt: "<", tLe: "<=", tGt: ">",
	tGe: ">=", tEq: "=", tNe: "!=",
}

func (k tokKind) String() string { return tokNames[k] }

type token struct {
	kind tokKind
	text string // spelling for identifiers, variables and integers
	line int
}

// lexer turns source bytes into tokens on demand.
type lexer struct {
	src  []byte
	pos  int
	line int
}

func isLower(c byte) bool  { return c >= 'a' && c <= 'z' }
func isUpper(c byte) bool  { return c >= 'A' && c <= 'Z' }
func isDigit(c byte) bool  { return c >= '0' && c <= '9' }
func isIdentC(c byte) bool { return isLower(c) || isUpper(c) || isDigit(c) || c == '_' }

func (l *lexer) skipSpace() {
	for l.pos < len(l.src) {
		switch c := l.src[l.pos]; c {
		case '\n':
			l.line++
			l.pos++
		case ' ', '\t', '\r':
			l.pos++
		case '%':
			for l.pos < len(l.src) && l.src[l.pos] != '\n' {
				l.pos++
			}
		default:
			return
		}
	}
}

func (l *lexer) next() (token, error) {
	l.skipSpace()
	t := token{line: l.line}
	if l.pos >= len(l.src) {
		t.kind = tEOF
		return t, nil
	}
	s := l.src
	start := l.pos
	c := s[start]
	peek := func(i int) byte {
		if start+i < len(s) {
			return s[start+i]
		}
		return 0
	}
	one := func(k tokKind, n int) (token, error) {
		t.kind = k
		l.pos += n
		return t, nil
	}
	switch {
	case isLower(c):
		l.pos++
		for l.pos < len(s) && isIdentC(s[l.pos]) {
			l.pos++
		}
		t.text = string(s[start:l.pos])
		t.kind = tIdent
		if t.text == "not" {
			t.kind = tNot
		}
		return t, nil
	case isUpper(c) || c == '_':
		l.pos++
		for l.pos < len(s) && isIdentC(s[l.pos]) {
			l.pos++
		}
		t.text = string(s[start:l.pos])
		t.kind = tVar
		if t.text == "_" {
			t.kind = tAnon
		}
		return t, nil
	case isDigit(c) || (c == '-' && isDigit(peek(1))):
		l.pos++
		for l.pos < len(s) && isDigit(s[l.pos]) {
			l.pos++
		}
		t.text = string(s[start:l.pos])
		t.kind = tInt
		return t, nil
	case c == '(':
		return one(tLParen, 1)
	case c == ')':
		return one(tRParen, 1)
	case c == ',':
		return one(tComma, 1)
	case c == '.':
		return one(tDot, 1)
	case c == ':' && peek(1) == '-':
		return one(tNeck, 2)
	case c == '?' && peek(1) == '-':
		return one(tQuery, 2)
	case c == '<':
		if peek(1) == '=' {
			return one(tLe, 2)
		}
		return one(tLt, 1)
	case c == '>':
		if peek(1) == '=' {
			return one(tGe, 2)
		}
		return one(tGt, 1)
	case c == '=':
		return one(tEq, 1)
	case c == '!' && peek(1) == '=':
		return one(tNe, 2)
	}
	return t, &SyntaxError{Line: l.line, Msg: fmt.Sprintf("unexpected character %q", c)}
}
