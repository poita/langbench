package syntax

import (
	"fmt"
	"strconv"

	"github.com/peter/jq/value"
)

type tokKind uint8

const (
	tEOF    tokKind = iota
	tIdent          // identifier or keyword
	tField          // .name
	tVar            // $name
	tNumber         // 12, 1.5
	tString         // "..."
	tPunct          // operators and brackets
)

type token struct {
	kind tokKind
	text string // identifier / field / var name, punctuation, decoded string
	num  float64
	pos  int // start offset
	end  int // end offset
}

// Error is a filter syntax error.
type Error struct {
	Pos int
	Msg string
}

func (e *Error) Error() string { return fmt.Sprintf("jq syntax error at offset %d: %s", e.Pos, e.Msg) }

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
		case c == ' ' || c == '\t' || c == '\n' || c == '\r':
			i++
		case c == '#':
			for i < len(src) && src[i] != '\n' {
				i++
			}
		case c == '.' && i+1 < len(src) && isIdentStart(src[i+1]):
			j := i + 1
			for j < len(src) && isIdentChar(src[j]) {
				j++
			}
			toks = append(toks, token{kind: tField, text: src[i+1 : j], pos: i, end: j})
			i = j
		case c == '$' && i+1 < len(src) && isIdentStart(src[i+1]):
			j := i + 1
			for j < len(src) && isIdentChar(src[j]) {
				j++
			}
			toks = append(toks, token{kind: tVar, text: src[i+1 : j], pos: i, end: j})
			i = j
		case isIdentStart(c):
			j := i
			for j < len(src) && isIdentChar(src[j]) {
				j++
			}
			toks = append(toks, token{kind: tIdent, text: src[i:j], pos: i, end: j})
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
				return nil, &Error{i, "invalid number"}
			}
			toks = append(toks, token{kind: tNumber, num: f, text: src[i:j], pos: i, end: j})
			i = j
		case c == '"':
			end, escaped, err := value.ScanString(src, i)
			if err != nil {
				return nil, &Error{i, err.Error()}
			}
			body := src[i+1 : end-1]
			if escaped {
				if body, err = value.Unquote(body); err != nil {
					return nil, &Error{i, err.Error()}
				}
			}
			toks = append(toks, token{kind: tString, text: body, pos: i, end: end})
			i = end
		default:
			n := 1
			if i+1 < len(src) {
				switch src[i : i+2] {
				case "==", "!=", "<=", ">=":
					n = 2
				}
			}
			switch src[i] {
			case '.', '(', ')', '[', ']', '{', '}', ',', '|', ':', ';', '?',
				'+', '-', '*', '/', '%', '<', '>', '=', '!':
			default:
				return nil, &Error{i, fmt.Sprintf("unexpected character %q", src[i])}
			}
			toks = append(toks, token{kind: tPunct, text: src[i : i+n], pos: i, end: i + n})
			i += n
		}
	}
	toks = append(toks, token{kind: tEOF, pos: len(src), end: len(src)})
	return toks, nil
}
