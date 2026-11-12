package parser

import "fmt"

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
	tRule  // :-
	tQuery // ?-
	tLT
	tLE
	tGT
	tGE
	tEQ
	tNE
)

type token struct {
	kind tokKind
	text string
	pos  int // byte offset
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
	src string
	pos int
}

func (l *lexer) errorf(pos int, format string, args ...any) *SyntaxError {
	line, col := 1, 1
	for i := 0; i < pos && i < len(l.src); i++ {
		if l.src[i] == '\n' {
			line++
			col = 1
		} else {
			col++
		}
	}
	return &SyntaxError{line, col, fmt.Sprintf(format, args...)}
}

func isLower(c byte) bool { return c >= 'a' && c <= 'z' }
func isUpper(c byte) bool { return c >= 'A' && c <= 'Z' }
func isDigit(c byte) bool { return c >= '0' && c <= '9' }
func isIdent(c byte) bool { return isLower(c) || isUpper(c) || isDigit(c) || c == '_' }

// next scans the next token, skipping whitespace and comments.
func (l *lexer) next() (token, error) {
	s := l.src
	for l.pos < len(s) {
		c := s[l.pos]
		if c == ' ' || c == '\t' || c == '\r' || c == '\n' {
			l.pos++
		} else if c == '%' {
			for l.pos < len(s) && s[l.pos] != '\n' {
				l.pos++
			}
		} else {
			break
		}
	}
	start := l.pos
	if start >= len(s) {
		return token{kind: tEOF, pos: start}, nil
	}
	c := s[start]
	at := func(n int, k tokKind) (token, error) {
		l.pos += n
		return token{k, s[start:l.pos], start}, nil
	}
	peek := func(i int) byte {
		if start+i < len(s) {
			return s[start+i]
		}
		return 0
	}
	switch {
	case c == '(':
		return at(1, tLParen)
	case c == ')':
		return at(1, tRParen)
	case c == ',':
		return at(1, tComma)
	case c == '.':
		return at(1, tDot)
	case c == '=':
		return at(1, tEQ)
	case c == ':' && peek(1) == '-':
		return at(2, tRule)
	case c == '?' && peek(1) == '-':
		return at(2, tQuery)
	case c == '!' && peek(1) == '=':
		return at(2, tNE)
	case c == '<':
		if peek(1) == '=' {
			return at(2, tLE)
		}
		return at(1, tLT)
	case c == '>':
		if peek(1) == '=' {
			return at(2, tGE)
		}
		return at(1, tGT)
	case isDigit(c) || (c == '-' && isDigit(peek(1))):
		i := start + 1
		for i < len(s) && isDigit(s[i]) {
			i++
		}
		l.pos = i
		return token{tInt, s[start:i], start}, nil
	case isLower(c) || isUpper(c) || c == '_':
		i := start + 1
		for i < len(s) && isIdent(s[i]) {
			i++
		}
		l.pos = i
		text := s[start:i]
		switch {
		case text == "_":
			return token{tAnon, text, start}, nil
		case text == "not":
			return token{tNot, text, start}, nil
		case isLower(c):
			return token{tIdent, text, start}, nil
		case isUpper(c):
			return token{tVar, text, start}, nil
		}
	}
	return token{}, l.errorf(start, "unexpected character %q", c)
}
