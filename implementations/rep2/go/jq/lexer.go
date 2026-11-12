package jq

import (
	"fmt"
	"strconv"
	"unicode/utf8"
)

type tokKind int

const (
	tEOF tokKind = iota
	tNum
	tStr
	tIdent
	tVar
	tPunct
)

type token struct {
	kind  tokKind
	s     string  // identifier / string value / punctuation / variable name
	num   float64 // for tNum
	space bool    // whitespace precedes the token
	pos   int
}

// FilterError describes a malformed filter.
type FilterError struct {
	Pos int
	Msg string
}

func (e *FilterError) Error() string {
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
		space := false
		for i < len(src) && (src[i] == ' ' || src[i] == '\t' || src[i] == '\n' || src[i] == '\r') {
			i++
			space = true
		}
		if i >= len(src) {
			toks = append(toks, token{kind: tEOF, space: space, pos: i})
			return toks, nil
		}
		c := src[i]
		start := i
		switch {
		case isIdentStart(c):
			for i < len(src) && (isIdentStart(src[i]) || isDigit(src[i])) {
				i++
			}
			toks = append(toks, token{kind: tIdent, s: src[start:i], space: space, pos: start})
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
				return nil, &FilterError{start, "bad number"}
			}
			toks = append(toks, token{kind: tNum, num: f, space: space, pos: start})
		case c == '"':
			s, n, err := lexString(src, i)
			if err != nil {
				return nil, err
			}
			i = n
			toks = append(toks, token{kind: tStr, s: s, space: space, pos: start})
		case c == '$':
			i++
			j := i
			for i < len(src) && (isIdentStart(src[i]) || isDigit(src[i])) {
				i++
			}
			if i == j {
				return nil, &FilterError{start, "expected variable name"}
			}
			toks = append(toks, token{kind: tVar, s: src[j:i], space: space, pos: start})
		default:
			if i+1 < len(src) {
				switch src[i : i+2] {
				case "==", "!=", "<=", ">=":
					toks = append(toks, token{kind: tPunct, s: src[i : i+2], space: space, pos: start})
					i += 2
					continue
				}
			}
			switch c {
			case '.', '|', ',', '(', ')', '[', ']', '{', '}', ':', ';', '?', '+', '-', '*', '/', '%', '<', '>':
				toks = append(toks, token{kind: tPunct, s: string(c), space: space, pos: start})
				i++
			default:
				return nil, &FilterError{start, fmt.Sprintf("unexpected character %q", c)}
			}
		}
	}
}

// lexString decodes a double-quoted literal starting at src[i] and returns the
// value and the index after the closing quote.
func lexString(src string, i int) (string, int, error) {
	start := i
	i++
	var buf []byte
	for i < len(src) {
		c := src[i]
		switch {
		case c == '"':
			return string(buf), i + 1, nil
		case c != '\\':
			buf = append(buf, c)
			i++
		default:
			i++
			if i >= len(src) {
				return "", 0, &FilterError{start, "unterminated string"}
			}
			e := src[i]
			i++
			switch e {
			case '"', '\\', '/':
				buf = append(buf, e)
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
				r, n, ok := lexHex4(src, i)
				if !ok {
					return "", 0, &FilterError{i, "bad \\u escape"}
				}
				i = n
				if r >= 0xD800 && r < 0xDC00 && i+1 < len(src) && src[i] == '\\' && src[i+1] == 'u' {
					if lo, n2, ok := lexHex4(src, i+2); ok && lo >= 0xDC00 && lo < 0xE000 {
						r = 0x10000 + (r-0xD800)<<10 + (lo - 0xDC00)
						i = n2
					}
				}
				buf = utf8.AppendRune(buf, r)
			default:
				return "", 0, &FilterError{i - 1, "bad escape"}
			}
		}
	}
	return "", 0, &FilterError{start, "unterminated string"}
}

func lexHex4(s string, i int) (rune, int, bool) {
	if i+4 > len(s) {
		return 0, 0, false
	}
	v, err := strconv.ParseUint(s[i:i+4], 16, 32)
	if err != nil {
		return 0, 0, false
	}
	return rune(v), i + 4, true
}
