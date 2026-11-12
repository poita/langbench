package schema

import "strings"

type tokKind uint8

const (
	tokWord   tokKind = iota // [A-Za-z0-9_$] run (and any non-ASCII bytes)
	tokQuoted                // "..." `...` or [...]; text is unquoted
	tokString                // '...'
	tokPunct                 // ( ) , . ; or any other single character
)

type token struct {
	kind tokKind
	text string
}

// isKeyword reports whether t is the unquoted word kw (ASCII case-insensitive).
func (t token) isKeyword(kw string) bool {
	return t.kind == tokWord && strings.EqualFold(t.text, kw)
}

func (t token) isPunct(c byte) bool {
	return t.kind == tokPunct && len(t.text) == 1 && t.text[0] == c
}

func isWordByte(c byte) bool {
	return c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' ||
		c == '_' || c == '$' || c >= 0x80
}

// tokenize splits a CREATE statement into tokens, dropping whitespace and
// comments. Unterminated quotes or comments run to the end of the text.
func tokenize(s string) []token {
	var toks []token
	for i := 0; i < len(s); {
		c := s[i]
		switch {
		case c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\f' || c == '\v':
			i++
		case c == '-' && i+1 < len(s) && s[i+1] == '-':
			for i < len(s) && s[i] != '\n' {
				i++
			}
		case c == '/' && i+1 < len(s) && s[i+1] == '*':
			end := strings.Index(s[i+2:], "*/")
			if end < 0 {
				i = len(s)
			} else {
				i += end + 4
			}
		case isWordByte(c):
			j := i
			for j < len(s) && isWordByte(s[j]) {
				j++
			}
			toks = append(toks, token{tokWord, s[i:j]})
			i = j
		case c == '"' || c == '`' || c == '\'':
			text, next := readQuoted(s, i, c)
			kind := tokQuoted
			if c == '\'' {
				kind = tokString
			}
			toks = append(toks, token{kind, text})
			i = next
		case c == '[':
			j := strings.IndexByte(s[i+1:], ']')
			if j < 0 {
				toks = append(toks, token{tokQuoted, s[i+1:]})
				i = len(s)
			} else {
				toks = append(toks, token{tokQuoted, s[i+1 : i+1+j]})
				i += j + 2
			}
		default:
			toks = append(toks, token{tokPunct, s[i : i+1]})
			i++
		}
	}
	return toks
}

// readQuoted reads a quoted item starting at s[i] (the quote character q),
// where a doubled q stands for a literal q. It returns the unquoted text and
// the index after the closing quote.
func readQuoted(s string, i int, q byte) (string, int) {
	var sb strings.Builder
	for j := i + 1; j < len(s); j++ {
		if s[j] == q {
			if j+1 < len(s) && s[j+1] == q {
				sb.WriteByte(q)
				j++
				continue
			}
			return sb.String(), j + 1
		}
		sb.WriteByte(s[j])
	}
	return sb.String(), len(s)
}

// name returns the identifier text of a word or quoted token.
func (t token) isName() bool { return t.kind == tokWord || t.kind == tokQuoted }
