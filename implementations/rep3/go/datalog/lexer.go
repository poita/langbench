package datalog

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
	tImplies // :-
	tQuery   // ?-
	tLT
	tLE
	tGT
	tGE
	tEQ
	tNE
)

type token struct {
	kind tokKind
	text string // identifier or variable name
	num  int64  // integer value
	line int
}

// SyntaxError reports malformed input.
type SyntaxError struct {
	Line int
	Msg  string
}

func (e *SyntaxError) Error() string { return fmt.Sprintf("line %d: %s", e.Line, e.Msg) }

type lexer struct {
	src  []byte
	pos  int
	line int
}

func isDigit(c byte) bool { return c >= '0' && c <= '9' }
func isLower(c byte) bool { return c >= 'a' && c <= 'z' }
func isUpper(c byte) bool { return c >= 'A' && c <= 'Z' }
func isIdentChar(c byte) bool {
	return isLower(c) || isUpper(c) || isDigit(c) || c == '_'
}

func (l *lexer) errorf(format string, args ...any) error {
	return &SyntaxError{Line: l.line, Msg: fmt.Sprintf(format, args...)}
}

// next scans one token, using longest match.
func (l *lexer) next() (token, error) {
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
			return l.scan(c)
		}
	}
	return token{kind: tEOF, line: l.line}, nil
}

func (l *lexer) at(off int) byte {
	if l.pos+off < len(l.src) {
		return l.src[l.pos+off]
	}
	return 0
}

func (l *lexer) scan(c byte) (token, error) {
	t := token{line: l.line}
	punct := func(k tokKind, n int) (token, error) {
		t.kind = k
		l.pos += n
		return t, nil
	}
	switch {
	case c == '(':
		return punct(tLParen, 1)
	case c == ')':
		return punct(tRParen, 1)
	case c == ',':
		return punct(tComma, 1)
	case c == '.':
		return punct(tDot, 1)
	case c == '=':
		return punct(tEQ, 1)
	case c == ':' && l.at(1) == '-':
		return punct(tImplies, 2)
	case c == '?' && l.at(1) == '-':
		return punct(tQuery, 2)
	case c == '<':
		if l.at(1) == '=' {
			return punct(tLE, 2)
		}
		return punct(tLT, 1)
	case c == '>':
		if l.at(1) == '=' {
			return punct(tGE, 2)
		}
		return punct(tGT, 1)
	case c == '!' && l.at(1) == '=':
		return punct(tNE, 2)
	case isDigit(c) || (c == '-' && isDigit(l.at(1))):
		start := l.pos
		neg := c == '-'
		if neg {
			l.pos++
		}
		var n int64
		for l.pos < len(l.src) && isDigit(l.src[l.pos]) {
			n = n*10 + int64(l.src[l.pos]-'0')
			if n > 1<<40 {
				return t, l.errorf("integer %q out of range", l.src[start:l.pos+1])
			}
			l.pos++
		}
		if neg {
			n = -n
		}
		t.kind, t.num = tInt, n
		return t, nil
	case isLower(c) || isUpper(c) || c == '_':
		start := l.pos
		for l.pos < len(l.src) && isIdentChar(l.src[l.pos]) {
			l.pos++
		}
		word := string(l.src[start:l.pos])
		switch {
		case word == "_":
			t.kind = tAnon
		case word == "not":
			t.kind = tNot
		case c == '_':
			return t, l.errorf("invalid token %q", word)
		case isUpper(c):
			t.kind, t.text = tVar, word
		default:
			t.kind, t.text = tIdent, word
		}
		return t, nil
	}
	return t, l.errorf("unexpected character %q", c)
}
