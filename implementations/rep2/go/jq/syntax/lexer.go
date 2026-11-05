package syntax

import (
	"fmt"
	"strconv"
	"unicode/utf8"
)

type tokKind uint8

const (
	tEOF tokKind = iota
	tNum
	tStr
	tIdent
	tVar
	tPunct // text holds the operator
)

type token struct {
	kind tokKind
	text string // identifier / variable name / punctuation / decoded string
	num  float64
	pos  int
}

// SyntaxError is returned for filters that cannot be parsed.
type SyntaxError struct {
	Pos int
	Msg string
}

func (e *SyntaxError) Error() string {
	return fmt.Sprintf("jq: syntax error at offset %d: %s", e.Pos, e.Msg)
}

func isIdentStart(c byte) bool {
	return c == '_' || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
}

func isDigit(c byte) bool { return c >= '0' && c <= '9' }

func lex(src string) ([]token, error) {
	var toks []token
	i := 0
	for {
		for i < len(src) && (src[i] == ' ' || src[i] == '\t' || src[i] == '\n' || src[i] == '\r') {
			i++
		}
		if i >= len(src) {
			toks = append(toks, token{kind: tEOF, pos: i})
			return toks, nil
		}
		c := src[i]
		start := i
		switch {
		case isIdentStart(c):
			for i < len(src) && (isIdentStart(src[i]) || isDigit(src[i])) {
				i++
			}
			toks = append(toks, token{kind: tIdent, text: src[start:i], pos: start})
		case c == '$':
			i++
			s := i
			for i < len(src) && (isIdentStart(src[i]) || isDigit(src[i])) {
				i++
			}
			if s == i {
				return nil, &SyntaxError{start, "expected variable name after '$'"}
			}
			toks = append(toks, token{kind: tVar, text: src[s:i], pos: start})
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
				return nil, &SyntaxError{start, "invalid number"}
			}
			toks = append(toks, token{kind: tNum, num: f, pos: start})
		case c == '"':
			s, n, err := lexString(src, i)
			if err != nil {
				return nil, err
			}
			i = n
			toks = append(toks, token{kind: tStr, text: s, pos: start})
		default:
			op := ""
			if i+1 < len(src) {
				switch two := src[i : i+2]; two {
				case "==", "!=", "<=", ">=":
					op = two
				}
			}
			if op == "" {
				switch c {
				case '.', ',', '|', '(', ')', '[', ']', '{', '}', ':', ';', '?', '+', '-', '*', '/', '%', '<', '>':
					op = src[i : i+1]
				default:
					return nil, &SyntaxError{i, fmt.Sprintf("unexpected character %q", c)}
				}
			}
			i += len(op)
			toks = append(toks, token{kind: tPunct, text: op, pos: start})
		}
	}
}

// lexString decodes a double-quoted string starting at src[i] and returns the
// decoded text and the offset after the closing quote.
func lexString(src string, i int) (string, int, error) {
	start := i
	i++
	var buf []byte
	for i < len(src) {
		c := src[i]
		switch c {
		case '"':
			return string(buf), i + 1, nil
		case '\\':
			i++
			if i >= len(src) {
				return "", 0, &SyntaxError{start, "unterminated string"}
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
					return "", 0, &SyntaxError{i, "invalid \\u escape"}
				}
				i += 4
				if r >= 0xD800 && r < 0xDC00 && i+6 < len(src) && src[i+1] == '\\' && src[i+2] == 'u' {
					if r2, ok := hex4(src, i+3); ok && r2 >= 0xDC00 && r2 < 0xE000 {
						r = 0x10000 + (r-0xD800)<<10 + (r2 - 0xDC00)
						i += 6
					}
				}
				buf = utf8.AppendRune(buf, r)
			default:
				return "", 0, &SyntaxError{i, "invalid escape"}
			}
			i++
		default:
			buf = append(buf, c)
			i++
		}
	}
	return "", 0, &SyntaxError{start, "unterminated string"}
}

func hex4(s string, i int) (rune, bool) {
	if i+4 > len(s) {
		return 0, false
	}
	n, err := strconv.ParseUint(s[i:i+4], 16, 32)
	if err != nil {
		return 0, false
	}
	return rune(n), true
}
