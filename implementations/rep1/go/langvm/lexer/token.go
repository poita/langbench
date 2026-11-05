// Package lexer turns the body of one Vellum module into a token array
// (SPEC section 3).
package lexer

import "langvm/diag"

// Kind is a token kind.
type Kind uint8

// Token kinds. Keywords and punctuation each have their own kind.
const (
	EOF Kind = iota
	Ident
	IntLit
	FloatLit
	StrLit
	CharLit
	Underscore

	// keywords
	KwAs
	KwBreak
	KwContinue
	KwElse
	KwEnum
	KwFalse
	KwFn
	KwFor
	KwIf
	KwImpl
	KwIn
	KwLet
	KwMatch
	KwPub
	KwReturn
	KwSelf
	KwStruct
	KwTrait
	KwTrue
	KwUse
	KwVar
	KwWhen
	KwWhile

	// punctuation
	HashBracket // #[
	ColonColon  // ::
	DotDot      // ..
	Arrow       // ->
	EqEq        // ==
	NotEq       // !=
	Le          // <=
	Ge          // >=
	AndAnd      // &&
	OrOr        // ||
	Shl         // <<
	Shr         // >>
	PlusPlus    // ++
	LParen
	RParen
	LBracket
	RBracket
	LBrace
	RBrace
	Comma
	Semi
	Colon
	Dot
	Pipe
	Plus
	Minus
	Star
	Slash
	Percent
	Bang
	Tilde
	Amp
	Caret
	Lt
	Gt
	Assign
)

var keywords = map[string]Kind{
	"as": KwAs, "break": KwBreak, "continue": KwContinue, "else": KwElse,
	"enum": KwEnum, "false": KwFalse, "fn": KwFn, "for": KwFor, "if": KwIf,
	"impl": KwImpl, "in": KwIn, "let": KwLet, "match": KwMatch, "pub": KwPub,
	"return": KwReturn, "self": KwSelf, "struct": KwStruct, "trait": KwTrait,
	"true": KwTrue, "use": KwUse, "var": KwVar, "when": KwWhen, "while": KwWhile,
}

// IsKeyword reports whether s is a reserved word.
func IsKeyword(s string) bool { _, ok := keywords[s]; return ok }

// Token is one lexical token. Text holds identifier names; Int holds an
// integer literal's value or a character literal's scalar; Float holds a float
// literal's value; Str holds a string literal's scalars.
type Token struct {
	Kind  Kind
	Pos   diag.Pos
	Text  string
	Int   int64
	Float float64
	Str   []rune
}
