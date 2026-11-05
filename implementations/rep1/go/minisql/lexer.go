package minisql

import (
	"strings"
	"unicode/utf8"
)

type tokKind uint8

const (
	tEOF          tokKind = iota
	tIdent                // non-reserved identifier (lower-cased)
	tKeyword              // reserved keyword (lower-cased)
	tInt                  // integer literal
	tString               // string literal (unescaped)
	tOp                   // operator or punctuation
	tInvalid              // any character that cannot start a token
	tUnterminated         // string literal without closing quote
)

type token struct {
	kind tokKind
	text string // lower-cased word, operator, or string contents
	ival int64  // value of an integer literal
}

var keywords = func() map[string]bool {
	m := map[string]bool{}
	for _, k := range strings.Fields(`SELECT FROM WHERE AND OR NOT NULL IS LIKE AS
		INSERT INTO VALUES DELETE UPDATE SET CREATE TABLE INTEGER TEXT INNER JOIN
		ON GROUP BY HAVING ORDER ASC DESC LIMIT OFFSET LEFT RIGHT FULL OUTER
		CROSS NATURAL`) {
		m[strings.ToLower(k)] = true
	}
	return m
}()

func isIdentStart(c byte) bool {
	return c == '_' || c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z'
}

func isDigit(c byte) bool { return c >= '0' && c <= '9' }

// lower returns s lower-cased, without allocating when it has no capitals.
func lower(s string) string {
	for i := 0; i < len(s); i++ {
		if s[i] >= 'A' && s[i] <= 'Z' {
			return strings.ToLower(s)
		}
	}
	return s
}

// tokenize splits src into tokens. Characters that cannot start a token
// become tInvalid tokens and an unclosed string becomes a single
// tUnterminated token that runs to the end of the input. Comments are
// dropped. Tokenizing never fails; errors surface when a statement is parsed.
func tokenize(src string) []token {
	toks := make([]token, 0, len(src)/3+1)
	i, n := 0, len(src)
	for i < n {
		c := src[i]
		switch {
		case c == ' ' || c == '\t' || c == '\r' || c == '\n' || c == '\f' || c == '\v':
			i++
		case c == '-' && i+1 < n && src[i+1] == '-':
			for i < n && src[i] != '\n' {
				i++
			}
		case isIdentStart(c):
			j := i + 1
			for j < n && (isIdentStart(src[j]) || isDigit(src[j])) {
				j++
			}
			w := lower(src[i:j])
			k := tIdent
			if keywords[w] {
				k = tKeyword
			}
			toks = append(toks, token{kind: k, text: w})
			i = j
		case isDigit(c):
			j := i
			var v uint64
			overflow := false
			for j < n && isDigit(src[j]) {
				d := uint64(src[j] - '0')
				if v > (1<<63-1-d)/10 {
					overflow = true
				}
				v = v*10 + d
				j++
			}
			if overflow {
				toks = append(toks, token{kind: tInvalid, text: src[i:j]})
			} else {
				toks = append(toks, token{kind: tInt, text: src[i:j], ival: int64(v)})
			}
			i = j
		case c == '\'':
			j := i + 1
			escaped := false
			closed := false
			for j < n {
				if src[j] == '\'' {
					if j+1 < n && src[j+1] == '\'' {
						escaped = true
						j += 2
						continue
					}
					closed = true
					break
				}
				j++
			}
			if !closed {
				toks = append(toks, token{kind: tUnterminated})
				i = n
				break
			}
			s := src[i+1 : j]
			if escaped {
				s = strings.ReplaceAll(s, "''", "'")
			}
			toks = append(toks, token{kind: tString, text: s})
			i = j + 1
		default:
			if op, ok := lexOp(src[i:]); ok {
				toks = append(toks, token{kind: tOp, text: op})
				i += len(op)
				break
			}
			_, size := utf8.DecodeRuneInString(src[i:])
			toks = append(toks, token{kind: tInvalid, text: src[i : i+size]})
			i += size
		}
	}
	return toks
}

func lexOp(s string) (string, bool) {
	switch s[0] {
	case '+', '-', '*', '/', '%', '(', ')', ',', '.', ';', '=':
		if s[0] == '=' && len(s) > 1 && s[1] == '=' {
			return "==", true
		}
		return s[:1], true
	case '!':
		if len(s) > 1 && s[1] == '=' {
			return "!=", true
		}
	case '<':
		if len(s) > 1 && (s[1] == '=' || s[1] == '>') {
			return s[:2], true
		}
		return "<", true
	case '>':
		if len(s) > 1 && s[1] == '=' {
			return ">=", true
		}
		return ">", true
	}
	return "", false
}

// splitStatements groups tokens into statements on ';' tokens, dropping the
// separators and empty statements. A trailing statement without ';' is kept.
func splitStatements(toks []token) [][]token {
	var out [][]token
	start := 0
	for i, t := range toks {
		if t.kind == tOp && t.text == ";" {
			if i > start {
				out = append(out, toks[start:i])
			}
			start = i + 1
		}
	}
	if start < len(toks) {
		out = append(out, toks[start:])
	}
	return out
}
