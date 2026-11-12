// Package syntax turns minisql source text into abstract syntax trees. It
// contains the lexer, the statement splitter, the AST definitions and a
// recursive-descent parser.
package syntax

import (
	"strconv"
	"strings"
	"unicode/utf8"
)

// TokenKind classifies a Token.
type TokenKind uint8

// Token kinds.
const (
	TokEOF          TokenKind = iota // returned by the parser past the last token
	TokIdent                         // non-reserved identifier (Text is lower-cased)
	TokKeyword                       // reserved keyword (Text is upper-cased)
	TokInt                           // non-negative integer literal (Int holds the value)
	TokString                        // string literal (Text holds the unquoted contents)
	TokPunct                         // operator or punctuation (Text holds it verbatim)
	TokInvalid                       // a character or literal that is not a valid token
	TokUnterminated                  // a string literal that is never closed
)

// Token is a lexical token.
type Token struct {
	Kind TokenKind
	Text string
	Int  int64
}

var keywords = map[string]bool{}

func init() {
	for _, k := range strings.Fields(`SELECT FROM WHERE AND OR NOT NULL IS LIKE AS INSERT INTO
		VALUES DELETE UPDATE SET CREATE TABLE INTEGER TEXT INNER JOIN ON GROUP BY HAVING ORDER
		ASC DESC LIMIT OFFSET LEFT RIGHT FULL OUTER CROSS NATURAL`) {
		keywords[k] = true
	}
}

// IsKeyword reports whether name (in any case) is a reserved keyword.
func IsKeyword(name string) bool { return keywords[strings.ToUpper(name)] }

func isSpace(c byte) bool {
	return c == ' ' || c == '\t' || c == '\r' || c == '\n' || c == '\f' || c == '\v'
}

func isIdentStart(c byte) bool {
	return c == '_' || 'a' <= c && c <= 'z' || 'A' <= c && c <= 'Z'
}

func isDigit(c byte) bool { return '0' <= c && c <= '9' }

// Lex splits src into tokens. It never fails: characters that cannot start a
// token become TokInvalid tokens, and an unclosed string literal becomes a
// final TokUnterminated token (lexing stops there, as the rest of the input
// belongs to that string).
func Lex(src string) []Token {
	var toks []Token
	i := 0
	for i < len(src) {
		c := src[i]
		switch {
		case isSpace(c):
			i++
		case c == '-' && i+1 < len(src) && src[i+1] == '-':
			for i < len(src) && src[i] != '\n' {
				i++
			}
		case isIdentStart(c):
			j := i + 1
			for j < len(src) && (isIdentStart(src[j]) || isDigit(src[j])) {
				j++
			}
			word := src[i:j]
			if up := strings.ToUpper(word); keywords[up] {
				toks = append(toks, Token{Kind: TokKeyword, Text: up})
			} else {
				toks = append(toks, Token{Kind: TokIdent, Text: strings.ToLower(word)})
			}
			i = j
		case isDigit(c):
			j := i + 1
			for j < len(src) && isDigit(src[j]) {
				j++
			}
			n, err := strconv.ParseInt(src[i:j], 10, 64)
			if err != nil {
				toks = append(toks, Token{Kind: TokInvalid, Text: src[i:j]})
			} else {
				toks = append(toks, Token{Kind: TokInt, Int: n, Text: src[i:j]})
			}
			i = j
		case c == '\'':
			var sb strings.Builder
			j := i + 1
			closed := false
			for j < len(src) {
				if src[j] == '\'' {
					if j+1 < len(src) && src[j+1] == '\'' {
						sb.WriteByte('\'')
						j += 2
						continue
					}
					closed = true
					j++
					break
				}
				sb.WriteByte(src[j])
				j++
			}
			if !closed {
				toks = append(toks, Token{Kind: TokUnterminated})
				return toks
			}
			toks = append(toks, Token{Kind: TokString, Text: sb.String()})
			i = j
		default:
			if op := punct(src[i:]); op != "" {
				toks = append(toks, Token{Kind: TokPunct, Text: op})
				i += len(op)
				break
			}
			_, w := utf8.DecodeRuneInString(src[i:])
			toks = append(toks, Token{Kind: TokInvalid, Text: src[i : i+w]})
			i += w
		}
	}
	return toks
}

// punct returns the longest operator or punctuation token at the start of s.
func punct(s string) string {
	if len(s) >= 2 {
		switch s[:2] {
		case "<=", ">=", "==", "!=", "<>":
			return s[:2]
		}
	}
	switch s[0] {
	case '+', '-', '*', '/', '%', '=', '<', '>', '(', ')', ',', '.', ';':
		return s[:1]
	}
	return ""
}

// SplitStatements groups toks into statements at ';' tokens. Empty statements
// are dropped; a final statement without a terminating ';' is kept.
func SplitStatements(toks []Token) [][]Token {
	var stmts [][]Token
	start := 0
	for i, t := range toks {
		if t.Kind == TokPunct && t.Text == ";" {
			if i > start {
				stmts = append(stmts, toks[start:i])
			}
			start = i + 1
		}
	}
	if start < len(toks) {
		stmts = append(stmts, toks[start:])
	}
	return stmts
}
