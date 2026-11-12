package syntax

import "fmt"

// TokenKind classifies a token.
type TokenKind uint8

// The token kinds.
const (
	TokEOF TokenKind = iota
	TokInt
	TokIdent
	TokLet
	TokRec
	TokIn
	TokFun
	TokIf
	TokThen
	TokElse
	TokTrue
	TokFalse
	TokDSemi  // ;;
	TokArrow  // ->
	TokCons   // ::
	TokLe     // <=
	TokGe     // >=
	TokAnd    // &&
	TokOr     // ||
	TokLParen // (
	TokRParen // )
	TokLBrack // [
	TokRBrack // ]
	TokSemi   // ;
	TokComma  // ,
	TokPlus   // +
	TokMinus  // -
	TokStar   // *
	TokSlash  // /
	TokEq     // =
	TokLt     // <
	TokGt     // >
)

var keywords = map[string]TokenKind{
	"let": TokLet, "rec": TokRec, "in": TokIn, "fun": TokFun, "if": TokIf,
	"then": TokThen, "else": TokElse, "true": TokTrue, "false": TokFalse,
}

// Token is a lexical token. Text is set for integers and identifiers.
type Token struct {
	Kind TokenKind
	Text string
	Pos  int // byte offset in the source
}

// Error is a syntax error.
type Error struct {
	Pos int // byte offset in the source
	Msg string
}

func (e *Error) Error() string { return fmt.Sprintf("syntax error at offset %d: %s", e.Pos, e.Msg) }

// Lexer splits source text into tokens.
type Lexer struct {
	src string
	pos int
}

// NewLexer returns a Lexer reading src.
func NewLexer(src string) *Lexer { return &Lexer{src: src} }

func isDigit(c byte) bool { return c >= '0' && c <= '9' }
func isLower(c byte) bool { return c >= 'a' && c <= 'z' }
func isIdentRest(c byte) bool {
	return isLower(c) || (c >= 'A' && c <= 'Z') || isDigit(c) || c == '_'
}

// Next returns the next token; at the end of input it returns TokEOF forever.
func (l *Lexer) Next() (Token, error) {
	s := l.src
	for l.pos < len(s) {
		switch s[l.pos] {
		case ' ', '\t', '\r', '\n':
			l.pos++
			continue
		}
		break
	}
	start := l.pos
	if start >= len(s) {
		return Token{Kind: TokEOF, Pos: start}, nil
	}
	c := s[start]
	switch {
	case isDigit(c):
		for l.pos < len(s) && isDigit(s[l.pos]) {
			l.pos++
		}
		return Token{Kind: TokInt, Text: s[start:l.pos], Pos: start}, nil
	case isLower(c):
		for l.pos < len(s) && isIdentRest(s[l.pos]) {
			l.pos++
		}
		text := s[start:l.pos]
		if k, ok := keywords[text]; ok {
			return Token{Kind: k, Pos: start}, nil
		}
		return Token{Kind: TokIdent, Text: text, Pos: start}, nil
	}
	var next byte
	if start+1 < len(s) {
		next = s[start+1]
	}
	two := func(k TokenKind) (Token, error) {
		l.pos += 2
		return Token{Kind: k, Pos: start}, nil
	}
	one := func(k TokenKind) (Token, error) {
		l.pos++
		return Token{Kind: k, Pos: start}, nil
	}
	switch c {
	case ';':
		if next == ';' {
			return two(TokDSemi)
		}
		return one(TokSemi)
	case '-':
		if next == '>' {
			return two(TokArrow)
		}
		return one(TokMinus)
	case ':':
		if next == ':' {
			return two(TokCons)
		}
	case '<':
		if next == '=' {
			return two(TokLe)
		}
		return one(TokLt)
	case '>':
		if next == '=' {
			return two(TokGe)
		}
		return one(TokGt)
	case '&':
		if next == '&' {
			return two(TokAnd)
		}
	case '|':
		if next == '|' {
			return two(TokOr)
		}
	case '(':
		return one(TokLParen)
	case ')':
		return one(TokRParen)
	case '[':
		return one(TokLBrack)
	case ']':
		return one(TokRBrack)
	case ',':
		return one(TokComma)
	case '+':
		return one(TokPlus)
	case '*':
		return one(TokStar)
	case '/':
		return one(TokSlash)
	case '=':
		return one(TokEq)
	}
	return Token{}, &Error{Pos: start, Msg: fmt.Sprintf("unexpected character %q", c)}
}
