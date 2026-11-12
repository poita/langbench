package spreadsheet

import "fmt"

type tokKind uint8

const (
	tokEOF   tokKind = iota
	tokNum           // 12.5
	tokStr           // "text" (text holds the contents without quotes)
	tokRef           // A1 (letters followed by digits)
	tokIdent         // SUM, IF, ...
	tokOp            // operators and punctuation
)

type token struct {
	kind tokKind
	text string
	pos  int
}

func isUpper(c byte) bool { return c >= 'A' && c <= 'Z' }
func isDigit(c byte) bool { return c >= '0' && c <= '9' }

// lex splits a formula body (without the leading '=') into tokens.
func lex(src string) ([]token, error) {
	var toks []token
	i := 0
	for i < len(src) {
		c := src[i]
		start := i
		switch {
		case c == ' ':
			i++
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
			toks = append(toks, token{tokNum, src[start:i], start})
		case isUpper(c):
			for i < len(src) && isUpper(src[i]) {
				i++
			}
			if i < len(src) && isDigit(src[i]) {
				for i < len(src) && isDigit(src[i]) {
					i++
				}
				toks = append(toks, token{tokRef, src[start:i], start})
			} else {
				toks = append(toks, token{tokIdent, src[start:i], start})
			}
		case c == '"':
			end := i + 1
			for end < len(src) && src[end] != '"' {
				end++
			}
			if end >= len(src) {
				return nil, fmt.Errorf("unterminated string at offset %d", i)
			}
			toks = append(toks, token{tokStr, src[i+1 : end], start})
			i = end + 1
		case c == '<' && i+1 < len(src) && (src[i+1] == '>' || src[i+1] == '='):
			i += 2
			toks = append(toks, token{tokOp, src[start:i], start})
		case c == '>' && i+1 < len(src) && src[i+1] == '=':
			i += 2
			toks = append(toks, token{tokOp, src[start:i], start})
		case c == '=' || c == '<' || c == '>' || c == '&' || c == '+' || c == '-' ||
			c == '*' || c == '/' || c == '(' || c == ')' || c == ',' || c == ':':
			i++
			toks = append(toks, token{tokOp, src[start:i], start})
		default:
			return nil, fmt.Errorf("unexpected character %q at offset %d", c, i)
		}
	}
	toks = append(toks, token{tokEOF, "", len(src)})
	return toks, nil
}
