package syntax

import (
	"strconv"
	"strings"

	"example.com/template/tplerr"
)

// TokenKind is the kind of a token inside a tag.
type TokenKind int

// Token kinds.
const (
	TokEOF TokenKind = iota
	TokName
	TokInt
	TokFloat
	TokString
	TokOp
)

// Token is a lexical token of a tag's content. For strings Text is the
// decoded value.
type Token struct {
	Kind  TokenKind
	Text  string
	Int   int64
	Float float64
}

const whitespace = " \t\n\r\f\v"

func isWS(c byte) bool {
	switch c {
	case ' ', '\t', '\n', '\r', '\f', '\v':
		return true
	}
	return false
}

func isNameStart(c byte) bool {
	return c == '_' || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
}

func isDigit(c byte) bool { return c >= '0' && c <= '9' }

var keywords = map[string]bool{
	"and": true, "or": true, "not": true, "in": true, "is": true,
	"true": true, "false": true, "none": true,
}

// IsKeyword reports whether name is a reserved word.
func IsKeyword(name string) bool { return keywords[name] }

func syntaxError(format string, args ...any) error {
	return tplerr.New(tplerr.Syntax, format, args...)
}

type itemKind int

const (
	itemText itemKind = iota
	itemPrint
	itemStmt
)

// item is a piece of a template: literal text or a tokenized tag.
type item struct {
	kind itemKind
	text string
	toks []Token // ends with a TokEOF
}

// lex splits src into text and tag items, applying whitespace control and
// dropping comments.
func lex(src string) ([]item, error) {
	var items []item
	pos := 0
	trimNext := false // the previous tag ended with '-': strip leading whitespace of the next text
	for {
		idx := findOpener(src, pos)
		end := idx
		if idx < 0 {
			end = len(src)
		}
		text := src[pos:end]
		if trimNext {
			text = strings.TrimLeft(text, whitespace)
			trimNext = false
		}
		if idx < 0 {
			if text != "" {
				items = append(items, item{kind: itemText, text: text})
			}
			return items, nil
		}
		kind := src[idx+1]
		p := idx + 2
		if p < len(src) && src[p] == '-' {
			text = strings.TrimRight(text, whitespace)
			p++
		}
		if text != "" {
			items = append(items, item{kind: itemText, text: text})
		}
		if kind == '#' {
			c := strings.Index(src[p:], "#}")
			if c < 0 {
				return nil, syntaxError("unclosed comment")
			}
			c += p
			trimNext = c > p && src[c-1] == '-'
			pos = c + 2
			continue
		}
		closer := byte('}')
		if kind == '%' {
			closer = '%'
		}
		toks, next, rtrim, err := lexTag(src, p, closer)
		if err != nil {
			return nil, err
		}
		trimNext = rtrim
		pos = next
		k := itemPrint
		if kind == '%' {
			k = itemStmt
		}
		items = append(items, item{kind: k, toks: toks})
	}
}

// findOpener returns the index of the first "{{", "{%" or "{#" at or after
// pos, or -1.
func findOpener(src string, pos int) int {
	for {
		i := strings.IndexByte(src[pos:], '{')
		if i < 0 || pos+i+1 >= len(src) {
			return -1
		}
		i += pos
		switch src[i+1] {
		case '{', '%', '#':
			return i
		}
		pos = i + 1
	}
}

// lexTag tokenizes tag content starting at pos until the closer (`}}` or
// `%}`, optionally preceded by `-`). It returns the tokens (with a trailing
// EOF), the position after the closer and whether the closer had a `-`.
func lexTag(src string, pos int, closer byte) ([]Token, int, bool, error) {
	var toks []Token
	for {
		for pos < len(src) && isWS(src[pos]) {
			pos++
		}
		if pos >= len(src) {
			return nil, 0, false, syntaxError("unclosed tag")
		}
		c := src[pos]
		if c == closer && pos+1 < len(src) && src[pos+1] == '}' {
			return append(toks, Token{Kind: TokEOF}), pos + 2, false, nil
		}
		if c == '-' && pos+2 < len(src) && src[pos+1] == closer && src[pos+2] == '}' {
			return append(toks, Token{Kind: TokEOF}), pos + 3, true, nil
		}
		switch {
		case isNameStart(c):
			s := pos
			for pos < len(src) && (isNameStart(src[pos]) || isDigit(src[pos])) {
				pos++
			}
			toks = append(toks, Token{Kind: TokName, Text: src[s:pos]})
		case isDigit(c):
			s := pos
			for pos < len(src) && isDigit(src[pos]) {
				pos++
			}
			if pos+1 < len(src) && src[pos] == '.' && isDigit(src[pos+1]) {
				pos++
				for pos < len(src) && isDigit(src[pos]) {
					pos++
				}
				f, err := strconv.ParseFloat(src[s:pos], 64)
				if err != nil {
					return nil, 0, false, syntaxError("bad float %q", src[s:pos])
				}
				toks = append(toks, Token{Kind: TokFloat, Text: src[s:pos], Float: f})
			} else {
				n, err := strconv.ParseInt(src[s:pos], 10, 64)
				if err != nil {
					return nil, 0, false, syntaxError("integer literal %q out of range", src[s:pos])
				}
				toks = append(toks, Token{Kind: TokInt, Text: src[s:pos], Int: n})
			}
		case c == '"' || c == '\'':
			str, next, err := lexString(src, pos)
			if err != nil {
				return nil, 0, false, err
			}
			toks = append(toks, Token{Kind: TokString, Text: str})
			pos = next
		default:
			op := lexOperator(src[pos:])
			if op == "" {
				return nil, 0, false, syntaxError("unexpected character %q in tag", c)
			}
			toks = append(toks, Token{Kind: TokOp, Text: op})
			pos += len(op)
		}
	}
}

func lexOperator(s string) string {
	if len(s) >= 2 {
		switch s[:2] {
		case "**", "//", "==", "!=", "<=", ">=":
			return s[:2]
		}
	}
	if strings.IndexByte("~+-*/%<>()[],|.=", s[0]) >= 0 {
		return s[:1]
	}
	return ""
}

// lexString decodes the string literal starting at src[pos] (a quote).
func lexString(src string, pos int) (string, int, error) {
	quote := src[pos]
	pos++
	start := pos
	var b *strings.Builder
	for pos < len(src) {
		c := src[pos]
		switch {
		case c == quote:
			if b == nil {
				return src[start:pos], pos + 1, nil
			}
			return b.String(), pos + 1, nil
		case c == '\\':
			if b == nil {
				b = &strings.Builder{}
				b.WriteString(src[start:pos])
			}
			if pos+1 >= len(src) {
				return "", 0, syntaxError("unterminated string")
			}
			switch src[pos+1] {
			case '\\', '"', '\'':
				b.WriteByte(src[pos+1])
			case 'n':
				b.WriteByte('\n')
			case 't':
				b.WriteByte('\t')
			default:
				return "", 0, syntaxError("invalid escape \\%c in string", src[pos+1])
			}
			pos += 2
		default:
			if b != nil {
				b.WriteByte(c)
			}
			pos++
		}
	}
	return "", 0, syntaxError("unterminated string")
}
