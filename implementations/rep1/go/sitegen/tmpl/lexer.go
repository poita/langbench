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
	s    string // name, string contents or operator text
	i    int64
	f    float64
}

type rawKind uint8

const (
	rawText rawKind = iota
	rawVar          // {{ ... }}
	rawStmt         // {% ... %}
)

// rawItem is a lexed chunk of a template: text or the tokens of one tag.
type rawItem struct {
	kind rawKind
	text string
	toks []token
}

func isWS(c byte) bool {
	return c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\f' || c == '\v'
}

func trimLeftWS(s string) string {
	i := 0
	for i < len(s) && isWS(s[i]) {
		i++
	}
	return s[i:]
}

func trimRightWS(s string) string {
	j := len(s)
	for j > 0 && isWS(s[j-1]) {
		j--
	}
	return s[:j]
}

// nextTag finds the first "{{", "{%" or "{#" at or after pos.
func nextTag(src string, pos int) int {
	for {
		i := strings.IndexByte(src[pos:], '{')
		if i < 0 {
			return -1
		}
		i += pos
		if i+1 < len(src) {
			if c := src[i+1]; c == '{' || c == '%' || c == '#' {
				return i
			}
		}
		pos = i + 1
	}
}

// lex splits a template source into text and tag items, applying whitespace
// control. Problems raise a syntax error.
func lex(src string) []rawItem {
	var items []rawItem
	pos := 0
	stripNext := false // the previous tag ended with "-"
	for {
		i := nextTag(src, pos)
		end := i
		if i < 0 {
			end = len(src)
		}
		text := src[pos:end]
		if stripNext {
			text = trimLeftWS(text)
		}
		if i < 0 {
			if text != "" {
				items = append(items, rawItem{kind: rawText, text: text})
			}
			return items
		}
		kindCh := src[i+1]
		contentStart := i + 2
		trimLeft := contentStart < len(src) && src[contentStart] == '-'
		if trimLeft {
			contentStart++
			text = trimRightWS(text)
		}
		if text != "" {
			items = append(items, rawItem{kind: rawText, text: text})
		}
		switch kindCh {
		case '#':
			j := strings.Index(src[contentStart:], "#}")
			if j < 0 {
				fail(SyntaxError, "unterminated comment")
			}
			j += contentStart
			stripNext = j > contentStart && src[j-1] == '-'
			pos = j + 2
		case '{':
			toks, next, trim := lexTag(src, contentStart, '}')
			items = append(items, rawItem{kind: rawVar, toks: toks})
			pos, stripNext = next, trim
		default:
			toks, next, trim := lexTag(src, contentStart, '%')
			items = append(items, rawItem{kind: rawStmt, toks: toks})
			pos, stripNext = next, trim
		}
	}
}

func isNameStart(c byte) bool { return c == '_' || c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' }
func isNameChar(c byte) bool  { return isNameStart(c) || c >= '0' && c <= '9' }
func isDigitByte(c byte) bool { return c >= '0' && c <= '9' }

// lexTag tokenizes tag content from pos up to the closer ("}}" or "%}",
// optionally preceded by '-'). close is '}' or '%'.
func lexTag(src string, pos int, close byte) (toks []token, next int, trim bool) {
	for {
		for pos < len(src) && isWS(src[pos]) {
			pos++
		}
		if pos >= len(src) {
			fail(SyntaxError, "unterminated tag")
		}
		c := src[pos]
		if c == '-' && pos+2 < len(src) && src[pos+1] == close && src[pos+2] == '}' {
			return toks, pos + 3, true
		}
		if c == close && pos+1 < len(src) && src[pos+1] == '}' {
			return toks, pos + 2, false
		}
		switch {
		case isNameStart(c):
			j := pos + 1
			for j < len(src) && isNameChar(src[j]) {
				j++
			}
			toks = append(toks, token{kind: tName, s: src[pos:j]})
			pos = j
		case isDigitByte(c):
			j := pos
			for j < len(src) && isDigitByte(src[j]) {
				j++
			}
			if j+1 < len(src) && src[j] == '.' && isDigitByte(src[j+1]) {
				k := j + 1
				for k < len(src) && isDigitByte(src[k]) {
					k++
				}
				f, err := strconv.ParseFloat(src[pos:k], 64)
				if err != nil {
					fail(SyntaxError, "invalid number %q", src[pos:k])
				}
				toks = append(toks, token{kind: tFloat, f: f})
				pos = k
			} else {
				n, err := strconv.ParseInt(src[pos:j], 10, 64)
				if err != nil {
					fail(SyntaxError, "integer literal out of range")
				}
				toks = append(toks, token{kind: tInt, i: n})
				pos = j
			}
		case c == '"' || c == '\'':
			s, j := lexString(src, pos)
			toks = append(toks, token{kind: tString, s: s})
			pos = j
		default:
			op := lexOperator(src, pos)
			if op == "" {
				fail(SyntaxError, "unexpected character %q in tag", c)
			}
			toks = append(toks, token{kind: tOp, s: op})
			pos += len(op)
		}
	}
}

func lexString(src string, pos int) (string, int) {
	quote := src[pos]
	var sb strings.Builder
	for i := pos + 1; i < len(src); i++ {
		c := src[i]
		switch c {
		case quote:
			return sb.String(), i + 1
		case '\\':
			i++
			if i >= len(src) {
				fail(SyntaxError, "unterminated string")
			}
			switch src[i] {
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
				fail(SyntaxError, "invalid escape in string")
			}
		default:
			sb.WriteByte(c)
		}
	}
	fail(SyntaxError, "unterminated string")
	return "", 0
}

func lexOperator(src string, pos int) string {
	if pos+1 < len(src) {
		switch two := src[pos : pos+2]; two {
		case "**", "//", "==", "!=", "<=", ">=":
			return two
		}
	}
	switch src[pos] {
	case '~', '+', '-', '*', '/', '%', '<', '>', '(', ')', '[', ']', ',', '|', '.', '=':
		return src[pos : pos+1]
	}
	return ""
}
