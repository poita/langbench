package tessera

import (
	"unicode/utf8"
)

type tokKind uint8

const (
	tkWord   tokKind = iota // [A-Za-z_][A-Za-z0-9_]*
	tkInt                   // -?[0-9]+ in canonical form
	tkString                // quoted string; text holds the raw body (escapes unresolved)
	tkPunct                 // { } [ ] ( ) , : .
	tkOp                    // == != <= >= < >
)

type token struct {
	kind tokKind
	text string
}

func (t token) is(kind tokKind, text string) bool { return t.kind == kind && t.text == text }

func isDigit(c byte) bool { return c >= '0' && c <= '9' }

func isWordStart(c byte) bool {
	return c == '_' || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
}

func isHex(c byte) bool {
	return isDigit(c) || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F')
}

// lex tokenises a command line (SPEC §6.1). Any lexical problem is a syntax
// error; surrogate pairs are not resolved here.
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
			for j < len(line) && (isWordStart(line[j]) || isDigit(line[j])) {
				j++
			}
			toks = append(toks, token{tkWord, line[i:j]})
			i = j
		case isDigit(c) || c == '-':
			j := i
			if c == '-' {
				j++
				if j >= len(line) || !isDigit(line[j]) {
					return nil, newErr(ErrSyntax)
				}
			}
			d := j
			for j < len(line) && isDigit(line[j]) {
				j++
			}
			if line[d] == '0' && (j-d > 1 || d > i) {
				return nil, newErr(ErrSyntax) // leading zero, or -0
			}
			toks = append(toks, token{tkInt, line[i:j]})
			i = j
		case c == '"':
			j := i + 1
			for {
				if j >= len(line) {
					return nil, newErr(ErrSyntax)
				}
				b := line[j]
				if b == '"' {
					break
				}
				if b < 0x20 {
					return nil, newErr(ErrSyntax)
				}
				if b != '\\' {
					j++
					continue
				}
				j++
				if j >= len(line) {
					return nil, newErr(ErrSyntax)
				}
				switch line[j] {
				case '"', '\\', '/', 'b', 'f', 'n', 'r', 't':
					j++
				case 'u':
					if j+4 >= len(line) {
						return nil, newErr(ErrSyntax)
					}
					for k := 1; k <= 4; k++ {
						if !isHex(line[j+k]) {
							return nil, newErr(ErrSyntax)
						}
					}
					j += 5
				default:
					return nil, newErr(ErrSyntax)
				}
			}
			toks = append(toks, token{tkString, line[i+1 : j]})
			i = j + 1
		case c == '{' || c == '}' || c == '[' || c == ']' || c == '(' || c == ')' || c == ',' || c == ':' || c == '.':
			toks = append(toks, token{tkPunct, line[i : i+1]})
			i++
		case c == '<' || c == '>' || c == '=' || c == '!':
			if i+1 < len(line) && line[i+1] == '=' {
				toks = append(toks, token{tkOp, line[i : i+2]})
				i += 2
			} else if c == '<' || c == '>' {
				toks = append(toks, token{tkOp, line[i : i+1]})
				i++
			} else {
				return nil, newErr(ErrSyntax)
			}
		default:
			return nil, newErr(ErrSyntax)
		}
	}
	return toks, nil
}

func hexVal(c byte) rune {
	switch {
	case c >= '0' && c <= '9':
		return rune(c - '0')
	case c >= 'a' && c <= 'f':
		return rune(c-'a') + 10
	}
	return rune(c-'A') + 10
}

// decodeString resolves the escapes of a lexically valid string body into
// UTF-8 bytes. An unpaired surrogate is a bad-utf8 error.
func decodeString(raw string) (string, error) {
	simple := true
	for i := 0; i < len(raw); i++ {
		if raw[i] == '\\' {
			simple = false
			break
		}
	}
	if simple {
		return raw, nil
	}
	out := make([]byte, 0, len(raw))
	for i := 0; i < len(raw); {
		c := raw[i]
		if c != '\\' {
			out = append(out, c)
			i++
			continue
		}
		switch raw[i+1] {
		case '"':
			out = append(out, '"')
		case '\\':
			out = append(out, '\\')
		case '/':
			out = append(out, '/')
		case 'b':
			out = append(out, '\b')
		case 'f':
			out = append(out, '\f')
		case 'n':
			out = append(out, '\n')
		case 'r':
			out = append(out, '\r')
		case 't':
			out = append(out, '\t')
		case 'u':
			u := hexVal(raw[i+2])<<12 | hexVal(raw[i+3])<<8 | hexVal(raw[i+4])<<4 | hexVal(raw[i+5])
			i += 6
			switch {
			case u >= 0xD800 && u <= 0xDBFF:
				if i+5 < len(raw) && raw[i] == '\\' && raw[i+1] == 'u' {
					lo := hexVal(raw[i+2])<<12 | hexVal(raw[i+3])<<8 | hexVal(raw[i+4])<<4 | hexVal(raw[i+5])
					if lo >= 0xDC00 && lo <= 0xDFFF {
						u = 0x10000 + (u-0xD800)<<10 + (lo - 0xDC00)
						i += 6
						out = utf8.AppendRune(out, u)
						continue
					}
				}
				return "", newErr(ErrBadUTF8)
			case u >= 0xDC00 && u <= 0xDFFF:
				return "", newErr(ErrBadUTF8)
			}
			out = utf8.AppendRune(out, u)
			continue
		}
		i += 2
	}
	return string(out), nil
}
