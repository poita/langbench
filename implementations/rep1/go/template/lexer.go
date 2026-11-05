package template

import (
	"strconv"
	"strings"
)

type tokKind uint8

const (
	tkName tokKind = iota
	tkInt
	tkFloat
	tkString
	tkOp
)

// token is one lexical token inside a {{ }} or {% %} tag.
type token struct {
	kind tokKind
	s    string // name, operator text or decoded string
	i    int64
	f    float64
}

type itemKind uint8

const (
	itText itemKind = iota
	itPrint
	itStmt
)

// item is one top-level piece of a template: literal text, a {{ }} tag or a
// {% %} tag (comments are dropped by the lexer).
type item struct {
	kind itemKind
	text string
	toks []token
}

// lex splits a template body into items in one left-to-right pass,
// applying whitespace control to neighbouring text items.
func lex(src string) []item {
	var items []item
	pos := 0
	trimNext := false
	for pos < len(src) {
		// Find the next tag opener.
		found := -1
		for i := pos; ; {
			j := strings.IndexByte(src[i:], '{')
			if j < 0 {
				break
			}
			k := i + j
			if k+1 < len(src) {
				if c := src[k+1]; c == '{' || c == '%' || c == '#' {
					found = k
					break
				}
			}
			i = k + 1
		}
		textEnd := len(src)
		if found >= 0 {
			textEnd = found
		}
		text := src[pos:textEnd]
		if trimNext {
			text = strings.TrimLeft(text, wsChars)
			trimNext = false
		}
		if found < 0 {
			if text != "" {
				items = append(items, item{kind: itText, text: text})
			}
			break
		}
		kind := src[found+1]
		p := found + 2
		if p < len(src) && src[p] == '-' {
			p++
			text = strings.TrimRight(text, wsChars)
		}
		if text != "" {
			items = append(items, item{kind: itText, text: text})
		}
		if kind == '#' {
			end := strings.Index(src[p:], "#}")
			if end < 0 {
				throw(ErrSyntax, "unclosed comment")
			}
			trimNext = strings.HasSuffix(src[p:p+end], "-")
			pos = p + end + 2
			continue
		}
		toks, np, rtrim := lexTag(src, p, kind)
		ik := itPrint
		if kind == '%' {
			ik = itStmt
		}
		items = append(items, item{kind: ik, toks: toks})
		pos = np
		trimNext = rtrim
	}
	return items
}

// lexTag tokenizes tag content starting at p until the closer. It returns
// the tokens, the position after the closer and whether the closer carried
// a '-' (whitespace control).
func lexTag(src string, p int, kind byte) (toks []token, next int, rtrim bool) {
	closeCh := byte('}')
	if kind == '%' {
		closeCh = '%'
	}
	for {
		for p < len(src) && isWS(src[p]) {
			p++
		}
		if p >= len(src) {
			throw(ErrSyntax, "unclosed tag")
		}
		c := src[p]
		// The closer is checked before operators.
		if c == closeCh && p+1 < len(src) && src[p+1] == '}' {
			return toks, p + 2, false
		}
		if c == '-' && p+2 < len(src) && src[p+1] == closeCh && src[p+2] == '}' {
			return toks, p + 3, true
		}
		switch {
		case c == '_' || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z'):
			q := p + 1
			for q < len(src) && (src[q] == '_' || (src[q] >= 'a' && src[q] <= 'z') || (src[q] >= 'A' && src[q] <= 'Z') || (src[q] >= '0' && src[q] <= '9')) {
				q++
			}
			toks = append(toks, token{kind: tkName, s: src[p:q]})
			p = q
		case c >= '0' && c <= '9':
			q := p
			for q < len(src) && src[q] >= '0' && src[q] <= '9' {
				q++
			}
			if q+1 < len(src) && src[q] == '.' && src[q+1] >= '0' && src[q+1] <= '9' {
				q += 2
				for q < len(src) && src[q] >= '0' && src[q] <= '9' {
					q++
				}
				f, err := strconv.ParseFloat(src[p:q], 64)
				if err != nil && f == 0 {
					throw(ErrSyntax, "bad float literal")
				}
				toks = append(toks, token{kind: tkFloat, f: f})
			} else {
				n, err := strconv.ParseInt(src[p:q], 10, 64)
				if err != nil {
					throw(ErrSyntax, "integer literal out of range")
				}
				toks = append(toks, token{kind: tkInt, i: n})
			}
			p = q
		case c == '"' || c == '\'':
			s, np := lexString(src, p)
			toks = append(toks, token{kind: tkString, s: s})
			p = np
		default:
			op := ""
			if p+1 < len(src) {
				switch src[p : p+2] {
				case "**", "//", "==", "!=", "<=", ">=":
					op = src[p : p+2]
				}
			}
			if op == "" {
				if strings.IndexByte("~+-*/%<>()[],|.=", c) < 0 {
					throw(ErrSyntax, "unexpected character %q in tag", c)
				}
				op = src[p : p+1]
			}
			toks = append(toks, token{kind: tkOp, s: op})
			p += len(op)
		}
	}
}

// lexString decodes the string literal starting at src[p] (a quote).
func lexString(src string, p int) (string, int) {
	quote := src[p]
	p++
	start := p
	// Fast path: no escapes.
	for p < len(src) && src[p] != quote && src[p] != '\\' {
		p++
	}
	if p < len(src) && src[p] == quote {
		return src[start:p], p + 1
	}
	var sb strings.Builder
	sb.WriteString(src[start:p])
	for p < len(src) {
		c := src[p]
		switch {
		case c == quote:
			return sb.String(), p + 1
		case c == '\\':
			if p+1 >= len(src) {
				throw(ErrSyntax, "unterminated string")
			}
			switch src[p+1] {
			case '\\':
				sb.WriteByte('\\')
			case '"':
				sb.WriteByte('"')
			case '\'':
				sb.WriteByte('\'')
			case 'n':
				sb.WriteByte('\n')
			case 't':
				sb.WriteByte('\t')
			default:
				throw(ErrSyntax, "invalid escape sequence in string")
			}
			p += 2
		default:
			sb.WriteByte(c)
			p++
		}
	}
	throw(ErrSyntax, "unterminated string")
	return "", p
}
