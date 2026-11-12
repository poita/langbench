package tmpl

import (
	"strconv"
	"strings"
)

type tokKind uint8

const (
	tName tokKind = iota
	tInt
	tFloat
	tString
	tOp
)

type token struct {
	kind tokKind
	s    string // name, operator or decoded string
	i    int64
	f    float64
}

type itemKind uint8

const (
	itText itemKind = iota
	itVar
	itStmt
)

// An item is a piece of a template: literal text, or the tokens of a {{ }}
// or {% %} tag.
type item struct {
	kind itemKind
	text string
	toks []token
}

const wsChars = " \t\n\r\f\v"

func isWS(c byte) bool {
	return c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\f' || c == '\v'
}

func isNameStart(c byte) bool {
	return c == '_' || c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z'
}

func isDigit(c byte) bool { return c >= '0' && c <= '9' }

// findOpener returns the index of the next "{{", "{%" or "{#" at or after i.
func findOpener(src string, i int) int {
	for {
		j := strings.IndexByte(src[i:], '{')
		if j < 0 {
			return -1
		}
		i += j
		if i+1 < len(src) {
			if c := src[i+1]; c == '{' || c == '%' || c == '#' {
				return i
			}
		}
		i++
	}
}

// lex splits a template source into items, applying whitespace control.
func lex(src string) []item {
	var items []item
	pos := 0
	trimNext := false
	for pos <= len(src) {
		i := findOpener(src, pos)
		end := i
		if i < 0 {
			end = len(src)
		}
		text := src[pos:end]
		if trimNext {
			text = strings.TrimLeft(text, wsChars)
			trimNext = false
		}
		if i < 0 {
			if text != "" {
				items = append(items, item{kind: itText, text: text})
			}
			break
		}
		kind := src[i+1]
		j := i + 2
		if j < len(src) && src[j] == '-' {
			text = strings.TrimRight(text, wsChars)
			j++
		}
		if text != "" {
			items = append(items, item{kind: itText, text: text})
		}
		if kind == '#' {
			k := strings.Index(src[j:], "#}")
			if k < 0 {
				throw(KindSyntax, "unclosed comment")
			}
			e := j + k
			trimNext = e > j && src[e-1] == '-'
			pos = e + 2
			continue
		}
		toks, rstrip, next := lexTag(src, j, kind == '{')
		trimNext = rstrip
		pos = next
		if kind == '{' {
			items = append(items, item{kind: itVar, toks: toks})
		} else {
			items = append(items, item{kind: itStmt, toks: toks})
		}
	}
	return items
}

// lexTag tokenizes tag content starting at i up to the closing "}}" (when
// variable is true) or "%}". It returns the tokens, whether the closer had a
// leading '-', and the index after the closer.
func lexTag(src string, i int, variable bool) (toks []token, rstrip bool, next int) {
	closer := "%}"
	if variable {
		closer = "}}"
	}
	for {
		for i < len(src) && isWS(src[i]) {
			i++
		}
		if i >= len(src) {
			throw(KindSyntax, "unclosed tag")
		}
		if strings.HasPrefix(src[i:], closer) {
			return toks, false, i + 2
		}
		if src[i] == '-' && strings.HasPrefix(src[i+1:], closer) {
			return toks, true, i + 3
		}
		c := src[i]
		switch {
		case isNameStart(c):
			j := i + 1
			for j < len(src) && (isNameStart(src[j]) || isDigit(src[j])) {
				j++
			}
			toks = append(toks, token{kind: tName, s: src[i:j]})
			i = j
		case isDigit(c):
			j := i
			for j < len(src) && isDigit(src[j]) {
				j++
			}
			if j+1 < len(src) && src[j] == '.' && isDigit(src[j+1]) {
				k := j + 1
				for k < len(src) && isDigit(src[k]) {
					k++
				}
				f, _ := strconv.ParseFloat(src[i:k], 64)
				toks = append(toks, token{kind: tFloat, f: f})
				i = k
			} else {
				n, err := strconv.ParseInt(src[i:j], 10, 64)
				if err != nil {
					throw(KindSyntax, "integer literal out of range")
				}
				toks = append(toks, token{kind: tInt, i: n})
				i = j
			}
		case c == '"' || c == '\'':
			s, j := lexString(src, i)
			toks = append(toks, token{kind: tString, s: s})
			i = j
		default:
			op := ""
			if i+1 < len(src) {
				switch two := src[i : i+2]; two {
				case "**", "//", "==", "!=", "<=", ">=":
					op = two
				}
			}
			if op == "" && strings.IndexByte("~+-*/%<>()[],|.=", c) >= 0 {
				op = src[i : i+1]
			}
			if op == "" {
				throw(KindSyntax, "unexpected character %q in tag", c)
			}
			toks = append(toks, token{kind: tOp, s: op})
			i += len(op)
		}
	}
}

// lexString decodes the string literal whose opening quote is at src[i].
func lexString(src string, i int) (string, int) {
	q := src[i]
	j := i + 1
	for j < len(src) && src[j] != q && src[j] != '\\' {
		j++
	}
	if j < len(src) && src[j] == q {
		return src[i+1 : j], j + 1
	}
	var b strings.Builder
	b.WriteString(src[i+1 : j])
	for j < len(src) {
		c := src[j]
		switch c {
		case q:
			return b.String(), j + 1
		case '\\':
			if j+1 >= len(src) {
				throw(KindSyntax, "unterminated string")
			}
			switch e := src[j+1]; e {
			case '\\', '"', '\'':
				b.WriteByte(e)
			case 'n':
				b.WriteByte('\n')
			case 't':
				b.WriteByte('\t')
			default:
				throw(KindSyntax, "invalid escape \\%c in string", e)
			}
			j += 2
		default:
			b.WriteByte(c)
			j++
		}
	}
	throw(KindSyntax, "unterminated string")
	return "", 0
}
