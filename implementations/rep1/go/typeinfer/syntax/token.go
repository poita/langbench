package syntax

// TokenKind identifies a lexical token. There is one kind per keyword and per
// symbol so the parser never compares strings.
type TokenKind uint8

// Token kinds.
const (
	EOF TokenKind = iota
	IntLit
	Ident
	KwLet
	KwRec
	KwIn
	KwFun
	KwIf
	KwThen
	KwElse
	KwTrue
	KwFalse
	SemiSemi   // ;;
	Arrow      // ->
	ColonColon // ::
	Le         // <=
	Ge         // >=
	AndAnd     // &&
	OrOr       // ||
	LParen
	RParen
	LBrack
	RBrack
	Semi
	Comma
	Plus
	Minus
	Star
	Slash
	Eq
	Lt
	Gt
)

var tokenNames = [...]string{
	EOF: "end of input", IntLit: "integer", Ident: "identifier",
	KwLet: "let", KwRec: "rec", KwIn: "in", KwFun: "fun", KwIf: "if",
	KwThen: "then", KwElse: "else", KwTrue: "true", KwFalse: "false",
	SemiSemi: ";;", Arrow: "->", ColonColon: "::", Le: "<=", Ge: ">=",
	AndAnd: "&&", OrOr: "||", LParen: "(", RParen: ")", LBrack: "[",
	RBrack: "]", Semi: ";", Comma: ",", Plus: "+", Minus: "-", Star: "*",
	Slash: "/", Eq: "=", Lt: "<", Gt: ">",
}

// String returns the source spelling (or a description) of the kind.
func (k TokenKind) String() string {
	if int(k) < len(tokenNames) {
		return tokenNames[k]
	}
	return "?"
}

// Token is one lexical token. For Ident tokens ID is the interned id of the
// name; integer literals carry no value.
type Token struct {
	Kind TokenKind
	ID   int32
	Pos  int32 // byte offset of the first byte of the token
}

// Error is a lexical or syntax error.
type Error struct {
	Pos int    // byte offset into the source
	Msg string // human-readable description
}

func (e *Error) Error() string {
	return "syntax error at byte " + itoa(e.Pos) + ": " + e.Msg
}

func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	var b [20]byte
	i := len(b)
	for n > 0 {
		i--
		b[i] = byte('0' + n%10)
		n /= 10
	}
	return string(b[i:])
}
