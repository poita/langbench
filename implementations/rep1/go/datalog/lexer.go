package datalog

import "strconv"

type tokKind uint8

const (
	tEOF tokKind = iota
	tIdent
	tVar
	tAnon
	tInt
	tNot
	tLParen
	tRParen
	tComma
	tDot
	tImplies // :-
	tQuery   // ?-
	tLT
	tLE
	tGT
	tGE
	tEQ
	tNE
)

var tokNames = [...]string{
	tEOF: "end of input", tIdent: "identifier", tVar: "variable", tAnon: "_",
	tInt: "integer", tNot: "not", tLParen: "(", tRParen: ")", tComma: ",",
	tDot: ".", tImplies: ":-", tQuery: "?-", tLT: "<", tLE: "<=", tGT: ">",
	tGE: ">=", tEQ: "=", tNE: "!=",
}

func (k tokKind) String() string { return tokNames[k] }

type token struct {
	kind      tokKind
	text      string // identifiers and variables
	num       int64  // integers
	line, col int
}

// lex splits src into tokens. Whitespace and %-comments are skipped.
func lex(src []byte) ([]token, error) {
	var toks []token
	line, lineStart := 1, 0
	i, n := 0, len(src)
	for i < n {
		c := src[i]
		switch {
		case c == '\n':
			i++
			line++
			lineStart = i
			continue
		case c == ' ' || c == '\t' || c == '\r':
			i++
			continue
		case c == '%':
			for i < n && src[i] != '\n' {
				i++
			}
			continue
		}
		t := token{line: line, col: i - lineStart + 1}
		bad := func(msg string) ([]token, error) {
			return nil, &SyntaxError{Line: t.line, Col: t.col, Msg: msg}
		}
		start := i
		switch {
		case c >= 'a' && c <= 'z':
			for i < n && isIdentChar(src[i]) {
				i++
			}
			t.text = string(src[start:i])
			t.kind = tIdent
			if t.text == "not" {
				t.kind = tNot
			}
		case c >= 'A' && c <= 'Z':
			for i < n && isIdentChar(src[i]) {
				i++
			}
			t.kind, t.text = tVar, string(src[start:i])
		case c == '_':
			for i < n && isIdentChar(src[i]) {
				i++
			}
			if i-start != 1 {
				return bad("variable names may not start with '_'")
			}
			t.kind = tAnon
		case c >= '0' && c <= '9', c == '-' && i+1 < n && src[i+1] >= '0' && src[i+1] <= '9':
			i++
			for i < n && src[i] >= '0' && src[i] <= '9' {
				i++
			}
			v, err := strconv.ParseInt(string(src[start:i]), 10, 64)
			if err != nil {
				return bad("invalid integer " + string(src[start:i]))
			}
			t.kind, t.num = tInt, v
		case c == '(':
			t.kind = tLParen
			i++
		case c == ')':
			t.kind = tRParen
			i++
		case c == ',':
			t.kind = tComma
			i++
		case c == '.':
			t.kind = tDot
			i++
		case c == '=':
			t.kind = tEQ
			i++
		case c == ':' && i+1 < n && src[i+1] == '-':
			t.kind = tImplies
			i += 2
		case c == '?' && i+1 < n && src[i+1] == '-':
			t.kind = tQuery
			i += 2
		case c == '!' && i+1 < n && src[i+1] == '=':
			t.kind = tNE
			i += 2
		case c == '<':
			t.kind = tLT
			i++
			if i < n && src[i] == '=' {
				t.kind = tLE
				i++
			}
		case c == '>':
			t.kind = tGT
			i++
			if i < n && src[i] == '=' {
				t.kind = tGE
				i++
			}
		default:
			return bad("unexpected character " + strconv.QuoteRune(rune(c)))
		}
		toks = append(toks, t)
	}
	toks = append(toks, token{kind: tEOF, line: line, col: n - lineStart + 1})
	return toks, nil
}

func isIdentChar(c byte) bool {
	return c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '_'
}
