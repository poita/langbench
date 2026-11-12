package lexer

import (
	"strconv"

	"langvm/diag"
)

// Lex tokenizes the lines of one module body. The returned slice always ends
// with an EOF token whose position is the position "one past the end" used
// for parse errors on premature end of input. On failure it returns the first
// lexical diagnostic.
func Lex(lines []string) ([]Token, *diag.Error) {
	lx := &lexer{}
	for i, l := range lines {
		if i > 0 {
			lx.src = append(lx.src, '\n')
		}
		lx.src = append(lx.src, []rune(l)...)
	}
	nl := len(lines)
	if nl < 1 {
		nl = 1
	}
	lastLen := 0
	if len(lines) > 0 {
		lastLen = len([]rune(lines[len(lines)-1]))
	}
	lx.eof = diag.Pos{Line: nl, Col: lastLen + 1}
	lx.line, lx.col = 1, 1
	if err := lx.run(); err != nil {
		return nil, err
	}
	lx.toks = append(lx.toks, Token{Kind: EOF, Pos: lx.eof})
	return lx.toks, nil
}

type lexer struct {
	src       []rune
	i         int
	line, col int
	eof       diag.Pos
	toks      []Token
}

func (lx *lexer) pos() diag.Pos { return diag.Pos{Line: lx.line, Col: lx.col} }

func (lx *lexer) peek(off int) rune {
	if lx.i+off < len(lx.src) {
		return lx.src[lx.i+off]
	}
	return -1
}

func (lx *lexer) adv() rune {
	c := lx.src[lx.i]
	lx.i++
	if c == '\n' {
		lx.line++
		lx.col = 1
	} else {
		lx.col++
	}
	return c
}

func isDigit(c rune) bool { return c >= '0' && c <= '9' }
func isHex(c rune) bool {
	return isDigit(c) || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F')
}
func isIdentStart(c rune) bool {
	return c == '_' || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
}
func isIdentPart(c rune) bool { return isIdentStart(c) || isDigit(c) }

func (lx *lexer) emit(t Token) { lx.toks = append(lx.toks, t) }

func (lx *lexer) run() *diag.Error {
	for lx.i < len(lx.src) {
		c := lx.src[lx.i]
		switch {
		case c == ' ' || c == '\t' || c == '\n' || c == '\r':
			lx.adv()
		case c == '/' && lx.peek(1) == '/':
			for lx.i < len(lx.src) && lx.src[lx.i] != '\n' {
				lx.adv()
			}
		case c == '/' && lx.peek(1) == '*':
			if err := lx.blockComment(); err != nil {
				return err
			}
		case isDigit(c):
			if err := lx.number(); err != nil {
				return err
			}
		case isIdentStart(c):
			if err := lx.ident(); err != nil {
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
	for depth > 0 {
		if lx.i >= len(lx.src) {
			return diag.New(diag.Unterminated, start)
		}
		if lx.src[lx.i] == '/' && lx.peek(1) == '*' {
			lx.adv()
			lx.adv()
			depth++
		} else if lx.src[lx.i] == '*' && lx.peek(1) == '/' {
			lx.adv()
			lx.adv()
			depth--
		} else {
			lx.adv()
		}
	}
	return nil
}

func (lx *lexer) ident() *diag.Error {
	start := lx.pos()
	b := lx.i
	for lx.i < len(lx.src) && isIdentPart(lx.src[lx.i]) {
		lx.adv()
	}
	text := string(lx.src[b:lx.i])
	if len(text) > 200 {
		return diag.New(diag.BadToken, start)
	}
	if text == "_" {
		lx.emit(Token{Kind: Underscore, Pos: start})
		return nil
	}
	if k, ok := keywordKinds[text]; ok {
		lx.emit(Token{Kind: k, Pos: start, Text: text})
		return nil
	}
	lx.emit(Token{Kind: Ident, Pos: start, Text: text})
	return nil
}

// digitRun consumes digit { digit | "_" } where the first character must be
// a digit accepted by ok. It returns the digits without underscores.
func (lx *lexer) digitRun(ok func(rune) bool, buf []byte) []byte {
	for lx.i < len(lx.src) {
		c := lx.src[lx.i]
		if c == '_' {
			lx.adv()
			continue
		}
		if !ok(c) {
			break
		}
		buf = append(buf, byte(c))
		lx.adv()
	}
	return buf
}

const maxInt = uint64(1)<<63 - 1

func (lx *lexer) number() *diag.Error {
	start := lx.pos()
	if lx.src[lx.i] == '0' && (lx.peek(1) == 'x' || lx.peek(1) == 'b') {
		base := uint64(16)
		ok := isHex
		if lx.peek(1) == 'b' {
			base = 2
			ok = func(c rune) bool { return c == '0' || c == '1' }
		}
		if !ok(lx.peek(2)) {
			return diag.New(diag.BadToken, start)
		}
		lx.adv()
		lx.adv()
		digits := lx.digitRun(ok, nil)
		var v uint64
		over := false
		for _, d := range digits {
			var dv uint64
			switch {
			case d >= '0' && d <= '9':
				dv = uint64(d - '0')
			case d >= 'a' && d <= 'f':
				dv = uint64(d-'a') + 10
			default:
				dv = uint64(d-'A') + 10
			}
			if v > (maxInt-dv)/base {
				over = true
				break
			}
			v = v*base + dv
		}
		if over {
			return diag.New(diag.IntRange, start)
		}
		lx.emit(Token{Kind: Int, Pos: start, Int: int64(v)})
		return nil
	}
	intDigits := lx.digitRun(isDigit, nil)
	isFloat := false
	text := append([]byte(nil), intDigits...)
	if lx.peek(0) == '.' && isDigit(lx.peek(1)) {
		isFloat = true
		lx.adv()
		text = append(text, '.')
		text = lx.digitRun(isDigit, text)
	}
	if c := lx.peek(0); c == 'e' || c == 'E' {
		n := 1
		if s := lx.peek(1); s == '+' || s == '-' {
			n = 2
		}
		if isDigit(lx.peek(n)) {
			isFloat = true
			text = append(text, 'e')
			lx.adv()
			if n == 2 {
				text = append(text, byte(lx.adv()))
			}
			text = lx.digitRun(isDigit, text)
		}
	}
	if isFloat {
		f, _ := strconv.ParseFloat(string(text), 64)
		lx.emit(Token{Kind: Float, Pos: start, Float: f})
		return nil
	}
	var v uint64
	for _, d := range intDigits {
		dv := uint64(d - '0')
		if v > (maxInt-dv)/10 {
			return diag.New(diag.IntRange, start)
		}
		v = v*10 + dv
	}
	lx.emit(Token{Kind: Int, Pos: start, Int: int64(v)})
	return nil
}

// escape decodes an escape sequence; the backslash is at lx.i.
func (lx *lexer) escape() (rune, *diag.Error) {
	bs := lx.pos()
	lx.adv()
	if lx.i >= len(lx.src) {
		return 0, diag.New(diag.BadEscape, bs)
	}
	c := lx.adv()
	switch c {
	case 'n':
		return '\n', nil
	case 't':
		return '\t', nil
	case 'r':
		return '\r', nil
	case '0':
		return 0, nil
	case '\\':
		return '\\', nil
	case '\'':
		return '\'', nil
	case '"':
		return '"', nil
	case 'u':
		if lx.peek(0) != '{' {
			return 0, diag.New(diag.BadEscape, bs)
		}
		lx.adv()
		n := 0
		var v uint32
		for lx.i < len(lx.src) && isHex(lx.src[lx.i]) {
			d := lx.src[lx.i]
			var dv uint32
			switch {
			case d >= '0' && d <= '9':
				dv = uint32(d - '0')
			case d >= 'a' && d <= 'f':
				dv = uint32(d-'a') + 10
			default:
				dv = uint32(d-'A') + 10
			}
			if n < 7 {
				v = v*16 + dv
			}
			n++
			lx.adv()
		}
		if n < 1 || n > 6 || lx.peek(0) != '}' {
			return 0, diag.New(diag.BadEscape, bs)
		}
		lx.adv()
		if v > 0x10FFFF || (v >= 0xD800 && v <= 0xDFFF) {
			return 0, diag.New(diag.BadEscape, bs)
		}
		return rune(v), nil
	}
	return 0, diag.New(diag.BadEscape, bs)
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
			if out == nil {
				out = []rune{}
			}
			lx.emit(Token{Kind: Str, Pos: start, Str: out})
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
	var v rune
	switch c {
	case '\'', '\n', '\r':
		return diag.New(diag.Unterminated, start)
	case '\\':
		r, err := lx.escape()
		if err != nil {
			return err
		}
		v = r
	default:
		v = c
		lx.adv()
	}
	if lx.peek(0) != '\'' {
		return diag.New(diag.Unterminated, start)
	}
	lx.adv()
	lx.emit(Token{Kind: Char, Pos: start, Int: int64(v)})
	return nil
}

func (lx *lexer) punct() *diag.Error {
	start := lx.pos()
	c := lx.src[lx.i]
	n := lx.peek(1)
	two := func(k Kind) *diag.Error {
		lx.adv()
		lx.adv()
		lx.emit(Token{Kind: k, Pos: start})
		return nil
	}
	one := func(k Kind) *diag.Error {
		lx.adv()
		lx.emit(Token{Kind: k, Pos: start})
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
			return two(LessEq)
		}
		if n == '<' {
			return two(Shl)
		}
		return one(Less)
	case '>':
		if n == '=' {
			return two(GreaterEq)
		}
		if n == '>' {
			return two(Shr)
		}
		return one(Greater)
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
