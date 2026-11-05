package lexer

import (
	"math"
	"strconv"
	"strings"

	"langvm/diag"
)

type lexer struct {
	src       []rune
	i         int
	line, col int
	toks      []Token
}

// Lex tokenises a module body (lines joined with LF, no header). The last
// token is always EOF and carries the end-of-input position used by parse
// errors. On failure it returns the first lexical error.
func Lex(src []rune) ([]Token, *diag.Error) {
	lx := &lexer{src: src, line: 1, col: 1}
	lx.toks = make([]Token, 0, len(src)/4+8)
	if err := lx.run(); err != nil {
		return nil, err
	}
	lx.toks = append(lx.toks, Token{Kind: EOF, Pos: diag.Pos{Line: lx.line, Col: lx.col}})
	return lx.toks, nil
}

func (lx *lexer) pos() diag.Pos { return diag.Pos{Line: lx.line, Col: lx.col} }

func (lx *lexer) adv() {
	if lx.src[lx.i] == '\n' {
		lx.line++
		lx.col = 1
	} else {
		lx.col++
	}
	lx.i++
}

func (lx *lexer) peekAt(k int) rune {
	if lx.i+k < len(lx.src) {
		return lx.src[lx.i+k]
	}
	return -1
}

func isDigit(c rune) bool    { return c >= '0' && c <= '9' }
func isHex(c rune) bool      { return isDigit(c) || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F') }
func isLetter(c rune) bool   { return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') }
func isIdentCh(c rune) bool  { return isLetter(c) || isDigit(c) || c == '_' }
func isIdentBeg(c rune) bool { return isLetter(c) || c == '_' }

func (lx *lexer) emit(k Kind, p diag.Pos) {
	lx.toks = append(lx.toks, Token{Kind: k, Pos: p})
}

func (lx *lexer) run() *diag.Error {
	for lx.i < len(lx.src) {
		c := lx.src[lx.i]
		switch {
		case c == ' ' || c == '\t' || c == '\n' || c == '\r':
			lx.adv()
		case c == '/' && lx.peekAt(1) == '/':
			for lx.i < len(lx.src) && lx.src[lx.i] != '\n' {
				lx.adv()
			}
		case c == '/' && lx.peekAt(1) == '*':
			if err := lx.blockComment(); err != nil {
				return err
			}
		case isIdentBeg(c):
			if err := lx.ident(); err != nil {
				return err
			}
		case isDigit(c):
			if err := lx.number(); err != nil {
				return err
			}
		case c == '"':
			if err := lx.str(); err != nil {
				return err
			}
		case c == '\'':
			if err := lx.char(); err != nil {
				return err
			}
		default:
			if err := lx.punct(); err != nil {
				return err
			}
		}
	}
	return nil
}

func (lx *lexer) blockComment() *diag.Error {
	start := lx.pos()
	lx.adv()
	lx.adv()
	depth := 1
	for lx.i < len(lx.src) {
		if lx.src[lx.i] == '/' && lx.peekAt(1) == '*' {
			depth++
			lx.adv()
			lx.adv()
		} else if lx.src[lx.i] == '*' && lx.peekAt(1) == '/' {
			depth--
			lx.adv()
			lx.adv()
			if depth == 0 {
				return nil
			}
		} else {
			lx.adv()
		}
	}
	return diag.New(diag.Unterminated, start)
}

func (lx *lexer) ident() *diag.Error {
	start := lx.pos()
	b := lx.i
	for lx.i < len(lx.src) && isIdentCh(lx.src[lx.i]) {
		lx.adv()
	}
	text := string(lx.src[b:lx.i])
	if lx.i-b > 200 {
		return diag.New(diag.BadToken, start)
	}
	if text == "_" {
		lx.emit(Underscore, start)
		return nil
	}
	if k, ok := keywords[text]; ok {
		lx.emit(k, start)
		lx.toks[len(lx.toks)-1].Text = text
		return nil
	}
	lx.emit(Ident, start)
	lx.toks[len(lx.toks)-1].Text = text
	return nil
}

func (lx *lexer) digitRun(sb *strings.Builder) {
	for lx.i < len(lx.src) && (isDigit(lx.src[lx.i]) || lx.src[lx.i] == '_') {
		if lx.src[lx.i] != '_' {
			sb.WriteRune(lx.src[lx.i])
		}
		lx.adv()
	}
}

func (lx *lexer) number() *diag.Error {
	start := lx.pos()
	c := lx.src[lx.i]
	if c == '0' && (lx.peekAt(1) == 'x' || lx.peekAt(1) == 'b') {
		base := uint64(16)
		ok := isHex
		if lx.peekAt(1) == 'b' {
			base = 2
			ok = func(r rune) bool { return r == '0' || r == '1' }
		}
		if !ok(lx.peekAt(2)) {
			return diag.New(diag.BadToken, start)
		}
		lx.adv()
		lx.adv()
		var v uint64
		over := false
		for lx.i < len(lx.src) && (ok(lx.src[lx.i]) || lx.src[lx.i] == '_') {
			ch := lx.src[lx.i]
			if ch != '_' {
				d := uint64(0)
				switch {
				case isDigit(ch):
					d = uint64(ch - '0')
				case ch >= 'a':
					d = uint64(ch-'a') + 10
				default:
					d = uint64(ch-'A') + 10
				}
				if v > (math.MaxInt64-d)/base {
					over = true
				} else {
					v = v*base + d
				}
			}
			lx.adv()
		}
		if over {
			return diag.New(diag.IntRange, start)
		}
		lx.emit(IntLit, start)
		lx.toks[len(lx.toks)-1].Int = int64(v)
		return nil
	}
	var sb strings.Builder
	lx.digitRun(&sb)
	isFloat := false
	if lx.peekAt(0) == '.' && isDigit(lx.peekAt(1)) {
		sb.WriteByte('.')
		lx.adv()
		lx.digitRun(&sb)
		isFloat = true
	}
	if c := lx.peekAt(0); c == 'e' || c == 'E' {
		j := 1
		if s := lx.peekAt(j); s == '+' || s == '-' {
			j++
		}
		if isDigit(lx.peekAt(j)) {
			sb.WriteByte('e')
			lx.adv()
			if s := lx.peekAt(0); s == '+' || s == '-' {
				sb.WriteRune(s)
				lx.adv()
			}
			lx.digitRun(&sb)
			isFloat = true
		}
	}
	text := sb.String()
	if isFloat {
		f, _ := strconv.ParseFloat(text, 64)
		lx.emit(FloatLit, start)
		lx.toks[len(lx.toks)-1].Float = f
		return nil
	}
	var v uint64
	for _, ch := range text {
		d := uint64(ch - '0')
		if v > (math.MaxInt64-d)/10 {
			return diag.New(diag.IntRange, start)
		}
		v = v*10 + d
	}
	lx.emit(IntLit, start)
	lx.toks[len(lx.toks)-1].Int = int64(v)
	return nil
}

// escape reads an escape sequence starting at the backslash.
func (lx *lexer) escape() (rune, *diag.Error) {
	bs := lx.pos()
	lx.adv() // backslash
	if lx.i >= len(lx.src) {
		return 0, diag.New(diag.BadEscape, bs)
	}
	c := lx.src[lx.i]
	var r rune
	switch c {
	case 'n':
		r = '\n'
	case 't':
		r = '\t'
	case 'r':
		r = '\r'
	case '0':
		r = 0
	case '\\':
		r = '\\'
	case '\'':
		r = '\''
	case '"':
		r = '"'
	case 'u':
		lx.adv()
		if lx.peekAt(0) != '{' {
			return 0, diag.New(diag.BadEscape, bs)
		}
		lx.adv()
		n := 0
		var v int64
		for lx.i < len(lx.src) && isHex(lx.src[lx.i]) {
			ch := lx.src[lx.i]
			var d int64
			switch {
			case isDigit(ch):
				d = int64(ch - '0')
			case ch >= 'a':
				d = int64(ch-'a') + 10
			default:
				d = int64(ch-'A') + 10
			}
			if n < 7 {
				v = v*16 + d
			}
			n++
			lx.adv()
		}
		if n < 1 || n > 6 || lx.peekAt(0) != '}' || v > 0x10FFFF || (v >= 0xD800 && v <= 0xDFFF) {
			return 0, diag.New(diag.BadEscape, bs)
		}
		lx.adv()
		return rune(v), nil
	default:
		return 0, diag.New(diag.BadEscape, bs)
	}
	lx.adv()
	return r, nil
}

func (lx *lexer) str() *diag.Error {
	start := lx.pos()
	lx.adv()
	var out []rune
	for {
		if lx.i >= len(lx.src) {
			return diag.New(diag.Unterminated, start)
		}
		c := lx.src[lx.i]
		switch c {
		case '"':
			lx.adv()
			lx.emit(StrLit, start)
			lx.toks[len(lx.toks)-1].Str = out
			return nil
		case '\n', '\r':
			return diag.New(diag.Unterminated, start)
		case '\\':
			r, err := lx.escape()
			if err != nil {
				return err
			}
			out = append(out, r)
		default:
			out = append(out, c)
			lx.adv()
		}
	}
}

func (lx *lexer) char() *diag.Error {
	start := lx.pos()
	lx.adv()
	if lx.i >= len(lx.src) {
		return diag.New(diag.Unterminated, start)
	}
	c := lx.src[lx.i]
	var r rune
	switch c {
	case '\'', '\n', '\r':
		return diag.New(diag.Unterminated, start)
	case '\\':
		var err *diag.Error
		r, err = lx.escape()
		if err != nil {
			return err
		}
	default:
		r = c
		lx.adv()
	}
	if lx.peekAt(0) != '\'' {
		return diag.New(diag.Unterminated, start)
	}
	lx.adv()
	lx.emit(CharLit, start)
	lx.toks[len(lx.toks)-1].Int = int64(r)
	return nil
}

func (lx *lexer) punct() *diag.Error {
	start := lx.pos()
	c := lx.src[lx.i]
	n := lx.peekAt(1)
	two := func(k Kind) *diag.Error {
		lx.adv()
		lx.adv()
		lx.emit(k, start)
		return nil
	}
	one := func(k Kind) *diag.Error {
		lx.adv()
		lx.emit(k, start)
		return nil
	}
	switch c {
	case '#':
		if n == '[' {
			return two(HashBracket)
		}
	case ':':
		if n == ':' {
			return two(ColonColon)
		}
		return one(Colon)
	case '.':
		if n == '.' {
			return two(DotDot)
		}
		return one(Dot)
	case '-':
		if n == '>' {
			return two(Arrow)
		}
		return one(Minus)
	case '=':
		if n == '=' {
			return two(EqEq)
		}
		return one(Assign)
	case '!':
		if n == '=' {
			return two(NotEq)
		}
		return one(Bang)
	case '<':
		if n == '=' {
			return two(Le)
		}
		if n == '<' {
			return two(Shl)
		}
		return one(Lt)
	case '>':
		if n == '=' {
			return two(Ge)
		}
		if n == '>' {
			return two(Shr)
		}
		return one(Gt)
	case '&':
		if n == '&' {
			return two(AndAnd)
		}
		return one(Amp)
	case '|':
		if n == '|' {
			return two(OrOr)
		}
		return one(Pipe)
	case '+':
		if n == '+' {
			return two(PlusPlus)
		}
		return one(Plus)
	case '(':
		return one(LParen)
	case ')':
		return one(RParen)
	case '[':
		return one(LBracket)
	case ']':
		return one(RBracket)
	case '{':
		return one(LBrace)
	case '}':
		return one(RBrace)
	case ',':
		return one(Comma)
	case ';':
		return one(Semi)
	case '*':
		return one(Star)
	case '/':
		return one(Slash)
	case '%':
		return one(Percent)
	case '~':
		return one(Tilde)
	case '^':
		return one(Caret)
	}
	return diag.New(diag.BadToken, start)
}
