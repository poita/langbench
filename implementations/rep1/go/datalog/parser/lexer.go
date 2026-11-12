package parser

import (
	"fmt"
	"strconv"
)

type tokKind int

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
	tImplies // :-
	tQuery   // ?-
	tLt
	tLe
	tGt
	tGe
	tEq
	tNe
)

type token struct {
	kind tokKind
	text string
	num  int64
	line int
	col  int
}

func (t token) describe() string {
	switch t.kind {
	case tEOF:
		return "end of input"
	case tIdent, tVar, tInt:
		return strconv.Quote(t.text)
	}
	return strconv.Quote(t.text)
}

// SyntaxError reports malformed input.
type SyntaxError struct {
	Line, Col int
	Msg       string
}

func (e *SyntaxError) Error() string {
	return fmt.Sprintf("syntax error at %d:%d: %s", e.Line, e.Col, e.Msg)
}

type lexer struct {
	src  string
	pos  int
	line int
	col  int
}

func newLexer(src string) *lexer { return &lexer{src: src, line: 1, col: 1} }

func (l *lexer) advance(n int) {
	for i := 0; i < n; i++ {
		if l.src[l.pos] == '\n' {
			l.line++
			l.col = 1
		} else {
			l.col++
		}
		l.pos++
	}
}

func isDigit(c byte) bool { return c >= '0' && c <= '9' }
func isLower(c byte) bool { return c >= 'a' && c <= 'z' }
func isUpper(c byte) bool { return c >= 'A' && c <= 'Z' }
func isWord(c byte) bool  { return isDigit(c) || isLower(c) || isUpper(c) || c == '_' }

// skip consumes whitespace and %-comments.
func (l *lexer) skip() {
	for l.pos < len(l.src) {
		switch c := l.src[l.pos]; {
		case c == ' ' || c == '\t' || c == '\r' || c == '\n':
			l.advance(1)
		case c == '%':
			for l.pos < len(l.src) && l.src[l.pos] != '\n' {
				l.advance(1)
			}
		default:
			return
		}
	}
}

func (l *lexer) errf(format string, args ...any) error {
	return &SyntaxError{Line: l.line, Col: l.col, Msg: fmt.Sprintf(format, args...)}
}

// next returns the next token, using longest match.
func (l *lexer) next() (token, error) {
	l.skip()
	tok := token{line: l.line, col: l.col}
	if l.pos >= len(l.src) {
		tok.kind = tEOF
		return tok, nil
	}
	s := l.src
	c := s[l.pos]
	two := ""
	if l.pos+1 < len(s) {
		two = s[l.pos : l.pos+2]
	}
	punct := func(k tokKind, n int) (token, error) {
		tok.kind = k
		tok.text = s[l.pos : l.pos+n]
		l.advance(n)
		return tok, nil
	}
	switch {
	case two == ":-":
		return punct(tImplies, 2)
	case two == "?-":
		return punct(tQuery, 2)
	case two == "<=":
		return punct(tLe, 2)
	case two == ">=":
		return punct(tGe, 2)
	case two == "!=":
		return punct(tNe, 2)
	case c == '(':
		return punct(tLParen, 1)
	case c == ')':
		return punct(tRParen, 1)
	case c == ',':
		return punct(tComma, 1)
	case c == '.':
		return punct(tDot, 1)
	case c == '<':
		return punct(tLt, 1)
	case c == '>':
		return punct(tGt, 1)
	case c == '=':
		return punct(tEq, 1)
	case isDigit(c) || (c == '-' && l.pos+1 < len(s) && isDigit(s[l.pos+1])):
		end := l.pos + 1
		for end < len(s) && isDigit(s[end]) {
			end++
		}
		n, err := strconv.ParseInt(s[l.pos:end], 10, 64)
		if err != nil {
			return tok, l.errf("bad integer %q", s[l.pos:end])
		}
		tok.kind, tok.text, tok.num = tInt, s[l.pos:end], n
		l.advance(end - l.pos)
		return tok, nil
	case isLower(c) || isUpper(c) || c == '_':
		end := l.pos + 1
		for end < len(s) && isWord(s[end]) {
			end++
		}
		word := s[l.pos:end]
		tok.text = word
		switch {
		case word == "_":
			tok.kind = tAnon
		case isUpper(c):
			tok.kind = tVar
		case c == '_':
			return tok, l.errf("identifier %q may not start with '_'", word)
		case word == "not":
			tok.kind = tNot
		default:
			tok.kind = tIdent
		}
		l.advance(end - l.pos)
		return tok, nil
	}
	return tok, l.errf("unexpected character %q", string(c))
}
