package jq

import (
	"fmt"
	"strconv"
	"unicode/utf8"
)

type tokKind uint8

const (
	tEOF tokKind = iota
	tIdent
	tNum
	tStr
	tVar // $name; text holds the name
	tOp  // punctuation and operators; text holds the symbol
)

type token struct {
	kind     tokKind
	text     string
	num      float64
	pos, end int
}

func isIdentStart(c byte) bool {
	return c == '_' || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
}

func isDigit(c byte) bool { return c >= '0' && c <= '9' }

func isIdentChar(c byte) bool { return isIdentStart(c) || isDigit(c) }

// lex splits src into tokens.
func lex(src string) ([]token, error) {
	var toks []token
	i := 0
	for i < len(src) {
		c := src[i]
		switch {
		case c == ' ' || c == '\t' || c == '\r' || c == '\n':
			i++
		case isIdentStart(c):
			j := i + 1
			for j < len(src) && isIdentChar(src[j]) {
				j++
			}
			toks = append(toks, token{kind: tIdent, text: src[i:j], pos: i, end: j})
			i = j
		case c == '$':
			j := i + 1
			if j >= len(src) || !isIdentStart(src[j]) {
				return nil, fmt.Errorf("jq: bad variable at offset %d", i)
			}
			for j < len(src) && isIdentChar(src[j]) {
				j++
			}
			toks = append(toks, token{kind: tVar, text: src[i+1 : j], pos: i, end: j})
			i = j
		case isDigit(c):
			j := i
			for j < len(src) && isDigit(src[j]) {
				j++
			}
			if j+1 < len(src) && src[j] == '.' && isDigit(src[j+1]) {
				j++
				for j < len(src) && isDigit(src[j]) {
					j++
				}
			}
			f, err := strconv.ParseFloat(src[i:j], 64)
			if err != nil {
				return nil, fmt.Errorf("jq: bad number %q", src[i:j])
			}
			toks = append(toks, token{kind: tNum, num: f, text: src[i:j], pos: i, end: j})
			i = j
		case c == '"':
			s, j, err := lexString(src, i)
			if err != nil {
				return nil, err
			}
			toks = append(toks, token{kind: tStr, text: s, pos: i, end: j})
			i = j
		default:
			if i+1 < len(src) {
				switch src[i : i+2] {
				case "==", "!=", "<=", ">=":
					toks = append(toks, token{kind: tOp, text: src[i : i+2], pos: i, end: i + 2})
					i += 2
					continue
				}
			}
			switch c {
			case '.', '[', ']', '(', ')', '{', '}', ',', ':', ';', '|', '?', '+', '-', '*', '/', '%', '<', '>':
				toks = append(toks, token{kind: tOp, text: src[i : i+1], pos: i, end: i + 1})
				i++
			default:
				return nil, fmt.Errorf("jq: unexpected character %q at offset %d", c, i)
			}
		}
	}
	toks = append(toks, token{kind: tEOF, pos: len(src), end: len(src)})
	return toks, nil
}

// lexString decodes the string literal starting at src[i] == '"'. It returns
// the decoded text and the offset just past the closing quote.
func lexString(src string, i int) (string, int, error) {
	buf := make([]byte, 0, 16)
	j := i + 1
	for j < len(src) {
		c := src[j]
		switch c {
		case '"':
			return string(buf), j + 1, nil
		case '\\':
			j++
			if j >= len(src) {
				return "", 0, fmt.Errorf("jq: unterminated string")
			}
			switch src[j] {
			case '"', '\\', '/':
				buf = append(buf, src[j])
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
				r, ok := hex4(src, j+1)
				if !ok {
					return "", 0, fmt.Errorf("jq: bad \\u escape")
				}
				j += 4
				if r >= 0xD800 && r < 0xDC00 && j+6 < len(src) && src[j+1] == '\\' && src[j+2] == 'u' {
					if r2, ok := hex4(src, j+3); ok && r2 >= 0xDC00 && r2 < 0xE000 {
						r = 0x10000 + (r-0xD800)<<10 + (r2 - 0xDC00)
						j += 6
					}
				}
				buf = utf8.AppendRune(buf, r)
			default:
				return "", 0, fmt.Errorf("jq: bad escape \\%c", src[j])
			}
			j++
		default:
			buf = append(buf, c)
			j++
		}
	}
	return "", 0, fmt.Errorf("jq: unterminated string")
}

func hex4(s string, i int) (rune, bool) {
	if i+4 > len(s) {
		return 0, false
	}
	var r rune
	for k := 0; k < 4; k++ {
		c := s[i+k]
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
