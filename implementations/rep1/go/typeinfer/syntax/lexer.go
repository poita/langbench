package syntax

// Lex splits src into tokens in a single pass. Identifiers are interned in in.
// The returned slice always ends with an EOF token. On a lexical error the
// tokens produced so far (terminated by EOF) are returned along with the
// error.
func Lex(src []byte, in *Interner) ([]Token, error) {
	toks := make([]Token, 0, len(src)/3+8)
	n := len(src)
	i := 0
	emit := func(k TokenKind, pos, width int) {
		toks = append(toks, Token{Kind: k, Pos: int32(pos)})
		i = pos + width
	}
	for i < n {
		c := src[i]
		switch {
		case c == ' ' || c == '\t' || c == '\n' || c == '\r':
			i++
		case c >= '0' && c <= '9':
			j := i + 1
			for j < n && src[j] >= '0' && src[j] <= '9' {
				j++
			}
			emit(IntLit, i, j-i)
		case c >= 'a' && c <= 'z':
			j := i + 1
			for j < n && isIdentByte(src[j]) {
				j++
			}
			word := src[i:j]
			if k, ok := keyword(word); ok {
				emit(k, i, j-i)
			} else {
				toks = append(toks, Token{Kind: Ident, ID: in.internBytes(word), Pos: int32(i)})
				i = j
			}
		default:
			var next byte
			if i+1 < n {
				next = src[i+1]
			}
			switch c {
			case ';':
				if next == ';' {
					emit(SemiSemi, i, 2)
				} else {
					emit(Semi, i, 1)
				}
			case '-':
				if next == '>' {
					emit(Arrow, i, 2)
				} else {
					emit(Minus, i, 1)
				}
			case ':':
				if next != ':' {
					return finish(toks, n), &Error{Pos: i, Msg: "unexpected ':'"}
				}
				emit(ColonColon, i, 2)
			case '<':
				if next == '=' {
					emit(Le, i, 2)
				} else {
					emit(Lt, i, 1)
				}
			case '>':
				if next == '=' {
					emit(Ge, i, 2)
				} else {
					emit(Gt, i, 1)
				}
			case '&':
				if next != '&' {
					return finish(toks, n), &Error{Pos: i, Msg: "unexpected '&'"}
				}
				emit(AndAnd, i, 2)
			case '|':
				if next != '|' {
					return finish(toks, n), &Error{Pos: i, Msg: "unexpected '|'"}
				}
				emit(OrOr, i, 2)
			case '(':
				emit(LParen, i, 1)
			case ')':
				emit(RParen, i, 1)
			case '[':
				emit(LBrack, i, 1)
			case ']':
				emit(RBrack, i, 1)
			case ',':
				emit(Comma, i, 1)
			case '+':
				emit(Plus, i, 1)
			case '*':
				emit(Star, i, 1)
			case '/':
				emit(Slash, i, 1)
			case '=':
				emit(Eq, i, 1)
			default:
				return finish(toks, n), &Error{Pos: i, Msg: "unexpected character " + quote(c)}
			}
		}
	}
	return finish(toks, n), nil
}

func finish(toks []Token, n int) []Token {
	return append(toks, Token{Kind: EOF, Pos: int32(n)})
}

func quote(c byte) string {
	if c >= 0x20 && c < 0x7f {
		return "'" + string(rune(c)) + "'"
	}
	return "0x" + string("0123456789abcdef"[c>>4]) + string("0123456789abcdef"[c&15])
}

func isIdentByte(c byte) bool {
	return c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '_'
}

func keyword(w []byte) (TokenKind, bool) {
	switch string(w) {
	case "let":
		return KwLet, true
	case "rec":
		return KwRec, true
	case "in":
		return KwIn, true
	case "fun":
		return KwFun, true
	case "if":
		return KwIf, true
	case "then":
		return KwThen, true
	case "else":
		return KwElse, true
	case "true":
		return KwTrue, true
	case "false":
		return KwFalse, true
	}
	return 0, false
}
