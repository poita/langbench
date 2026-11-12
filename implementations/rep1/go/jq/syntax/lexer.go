package syntax

import (
	"fmt"
	"strconv"
	"unicode/utf8"
)

// Error is a filter syntax error.
type Error struct {
	Pos int // byte offset in the filter text
	Msg string
}

func (e *Error) Error() string { return fmt.Sprintf("jq: syntax error at offset %d: %s", e.Pos, e.Msg) }

type tokKind int

const (
	tEOF   tokKind = iota
	tIdent         // identifier or keyword
	tField         // .name
	tVar           // $name
	tNum
	tStr
	tOp // punctuation and operators
)

type token struct {
	kind tokKind
	text string // identifier/field/var name, operator text, or decoded string
	num  float64
	pos  int
}

func fail(pos int, format string, a ...any) {
	panic(&Error{Pos: pos, Msg: fmt.Sprintf(format, a...)})
}

func isIdentStart(c byte) bool {
	return c == '_' || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
}

func isDigit(c byte) bool { return c >= '0' && c <= '9' }

func isIdentChar(c byte) bool { return isIdentStart(c) || isDigit(c) }

func lex(src string) []token {
	var toks []token
	i := 0
	for {
		for i < len(src) && (src[i] == ' ' || src[i] == '\t' || src[i] == '\n' || src[i] == '\r') {
			i++
		}
		if i >= len(src) {
			return append(toks, token{kind: tEOF, pos: i})
		}
		c := src[i]
		start := i
		switch {
		case isIdentStart(c):
			for i < len(src) && isIdentChar(src[i]) {
				i++
			}
			toks = append(toks, token{kind: tIdent, text: src[start:i], pos: start})
		case isDigit(c):
			for i < len(src) && isDigit(src[i]) {
				i++
			}
			if i+1 < len(src) && src[i] == '.' && isDigit(src[i+1]) {
				i++
				for i < len(src) && isDigit(src[i]) {
					i++
				}
			}
			f, err := strconv.ParseFloat(src[start:i], 64)
			if err != nil {
				fail(start, "invalid number %q", src[start:i])
			}
			toks = append(toks, token{kind: tNum, num: f, text: src[start:i], pos: start})
		case c == '"':
			s, n := lexString(src, i)
			i = n
			toks = append(toks, token{kind: tStr, text: s, pos: start})
		case c == '$':
			i++
			if i >= len(src) || !isIdentStart(src[i]) {
				fail(start, "expected variable name after '$'")
			}
			j := i
			for i < len(src) && isIdentChar(src[i]) {
				i++
			}
			toks = append(toks, token{kind: tVar, text: src[j:i], pos: start})
		case c == '.':
			if i+1 < len(src) && isIdentStart(src[i+1]) {
				i++
				j := i
				for i < len(src) && isIdentChar(src[i]) {
					i++
				}
				toks = append(toks, token{kind: tField, text: src[j:i], pos: start})
			} else {
				i++
				toks = append(toks, token{kind: tOp, text: ".", pos: start})
			}
		default:
			two := ""
			if i+1 < len(src) {
				two = src[i : i+2]
			}
			switch two {
			case "==", "!=", "<=", ">=":
				i += 2
				toks = append(toks, token{kind: tOp, text: two, pos: start})
				continue
			}
			switch c {
			case '|', ',', '(', ')', '[', ']', '{', '}', ':', ';', '?', '+', '-', '*', '/', '%', '<', '>':
				i++
				toks = append(toks, token{kind: tOp, text: string(c), pos: start})
			default:
				fail(start, "unexpected character %q", c)
			}
		}
	}
}

// lexString decodes the string literal starting at src[i] (a quote) and
// returns its value and the offset just after the closing quote.
func lexString(src string, i int) (string, int) {
	start := i
	i++
	var buf []byte
	for i < len(src) {
		c := src[i]
		switch c {
		case '"':
			return string(buf), i + 1
		case '\\':
			i++
			if i >= len(src) {
				fail(start, "unterminated string")
			}
			switch src[i] {
			case '"', '\\', '/':
				buf = append(buf, src[i])
			case 'b':
				buf = append(buf, '\b')
			case 'f':
				buf = append(buf, '\f')
			case 'n':
				buf = append(buf, '\n')
			case 'r':
				buf = append(buf, '\r')
			case 't':
				buf = append(buf, '\t')
			case 'u':
				r, ok := hex4(src, i+1)
				if !ok {
					fail(i, "invalid \\u escape")
				}
				i += 4
				if r >= 0xD800 && r < 0xDC00 && i+6 < len(src) && src[i+1] == '\\' && src[i+2] == 'u' {
					if lo, ok := hex4(src, i+3); ok && lo >= 0xDC00 && lo < 0xE000 {
						r = 0x10000 + (r-0xD800)<<10 + (lo - 0xDC00)
						i += 6
					}
				}
				buf = utf8.AppendRune(buf, r)
			default:
				fail(i, "invalid escape")
			}
			i++
		default:
			buf = append(buf, c)
			i++
		}
	}
	fail(start, "unterminated string")
	return "", 0
}

func hex4(s string, p int) (rune, bool) {
	if p+4 > len(s) {
		return 0, false
	}
	var r rune
	for _, c := range []byte(s[p : p+4]) {
		switch {
		case c >= '0' && c <= '9':
			r = r<<4 | rune(c-'0')
		case c >= 'a' && c <= 'f':
			r = r<<4 | rune(c-'a'+10)
		case c >= 'A' && c <= 'F':
			r = r<<4 | rune(c-'A'+10)
		default:
			return 0, false
		}
	}
	return r, true
}
