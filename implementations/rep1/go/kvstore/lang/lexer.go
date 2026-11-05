package lang

import (
	"unicode/utf8"

	"example.com/kvstore/kverr"
)

type tokKind uint8

const (
	tWord tokKind = iota
	tInt
	tString
	tPunct
	tOp
)

// token is one lexical element of a command line.
type token struct {
	kind tokKind
	text string // word, integer digits (with sign), punctuation or operator
	str  string // decoded value of a string token
	bad  bool   // string token containing an unpaired surrogate escape
}

func isWordStart(c byte) bool {
	return c == '_' || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
}

func isDigit(c byte) bool { return c >= '0' && c <= '9' }

func isWordChar(c byte) bool { return isWordStart(c) || isDigit(c) }

// lex tokenises a whole command line. Any lexical problem is kverr.Syntax.
// Unpaired surrogate escapes are not an error here; they are flagged on the
// token and resolved when the parser consumes it.
func lex(line string) ([]token, error) {
	var toks []token
	i := 0
	for i < len(line) {
		c := line[i]
		switch {
		case c == ' ' || c == '\t':
			i++
		case isWordStart(c):
			j := i + 1
			for j < len(line) && isWordChar(line[j]) {
				j++
			}
			toks = append(toks, token{kind: tWord, text: line[i:j]})
			i = j
		case isDigit(c) || c == '-':
			j := i
			if c == '-' {
				j++
			}
			start := j
			for j < len(line) && isDigit(line[j]) {
				j++
			}
			if j == start {
				return nil, kverr.Syntax // bare '-'
			}
			digits := line[start:j]
			if digits[0] == '0' && (len(digits) > 1 || c == '-') {
				return nil, kverr.Syntax // leading zero or "-0"
			}
			toks = append(toks, token{kind: tInt, text: line[i:j]})
			i = j
		case c == '"':
			t, n, err := lexString(line, i)
			if err != nil {
				return nil, err
			}
			toks = append(toks, t)
			i = n
		case c == '{' || c == '}' || c == '[' || c == ']' || c == '(' || c == ')' ||
			c == ',' || c == ':' || c == '.':
			toks = append(toks, token{kind: tPunct, text: line[i : i+1]})
			i++
		case c == '<' || c == '>':
			if i+1 < len(line) && line[i+1] == '=' {
				toks = append(toks, token{kind: tOp, text: line[i : i+2]})
				i += 2
			} else {
				toks = append(toks, token{kind: tOp, text: line[i : i+1]})
				i++
			}
		case c == '=' || c == '!':
			if i+1 < len(line) && line[i+1] == '=' {
				toks = append(toks, token{kind: tOp, text: line[i : i+2]})
				i += 2
			} else {
				return nil, kverr.Syntax
			}
		default:
			return nil, kverr.Syntax
		}
	}
	return toks, nil
}

func hexVal(c byte) int {
	switch {
	case c >= '0' && c <= '9':
		return int(c - '0')
	case c >= 'a' && c <= 'f':
		return int(c-'a') + 10
	case c >= 'A' && c <= 'F':
		return int(c-'A') + 10
	}
	return -1
}

// lexString lexes the string literal starting at line[start] == '"'. It
// returns the token and the index just past the closing quote.
func lexString(line string, start int) (token, int, error) {
	var out []byte
	bad := false
	pending := rune(-1) // high surrogate awaiting its low half
	flush := func() {   // a high surrogate not followed by a low-surrogate escape
		if pending >= 0 {
			bad = true
			pending = -1
		}
	}
	i := start + 1
	for {
		if i >= len(line) {
			return token{}, 0, kverr.Syntax // unterminated
		}
		c := line[i]
		switch {
		case c == '"':
			flush()
			t := token{kind: tString, str: string(out), bad: bad}
			if bad {
				t.str = ""
			}
			return t, i + 1, nil
		case c < 0x20:
			return token{}, 0, kverr.Syntax
		case c == '\\':
			if i+1 >= len(line) {
				return token{}, 0, kverr.Syntax
			}
			e := line[i+1]
			if e == 'u' {
				if i+6 > len(line) {
					return token{}, 0, kverr.Syntax
				}
				u := 0
				for k := 0; k < 4; k++ {
					h := hexVal(line[i+2+k])
					if h < 0 {
						return token{}, 0, kverr.Syntax
					}
					u = u<<4 | h
				}
				i += 6
				r := rune(u)
				switch {
				case pending >= 0 && r >= 0xDC00 && r <= 0xDFFF:
					out = utf8.AppendRune(out, 0x10000+(pending-0xD800)<<10+(r-0xDC00))
					pending = -1
				case r >= 0xD800 && r <= 0xDBFF:
					flush()
					pending = r
				case r >= 0xDC00 && r <= 0xDFFF:
					flush()
					bad = true
				default:
					flush()
					out = utf8.AppendRune(out, r)
				}
				continue
			}
			var b byte
			switch e {
			case '"', '\\', '/':
				b = e
			case 'b':
				b = '\b'
			case 'f':
				b = '\f'
			case 'n':
				b = '\n'
			case 'r':
				b = '\r'
			case 't':
				b = '\t'
			default:
				return token{}, 0, kverr.Syntax
			}
			flush()
			out = append(out, b)
			i += 2
		default:
			flush()
			out = append(out, c)
			i++
		}
	}
}
