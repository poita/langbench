// Package lexer turns the body of one Vellum module into tokens
// (SPEC.md section 3).
package lexer

import "langvm/diag"

// Kind is the class of a token.
type Kind uint8

// Token kinds. Keywords and punctuation each have their own kind.
const (
	EOF Kind = iota
	Ident
	Int
	Float
	Str
	Char
	Underscore // the lone `_` wildcard

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

	// punctuation and operators
	HashBracket // #[
	ColonColon  // ::
	DotDot      // ..
	Arrow       // ->
	EqEq        // ==
	NotEq       // !=
	LessEq      // <=
	GreaterEq   // >=
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
	Less
	Greater
	Assign
)

var kindNames = map[Kind]string{
	EOF: "end of input", Ident: "identifier", Int: "integer", Float: "float",
	Str: "string", Char: "character", Underscore: "_",
	KwAs: "as", KwBreak: "break", KwContinue: "continue", KwElse: "else",
	KwEnum: "enum", KwFalse: "false", KwFn: "fn", KwFor: "for", KwIf: "if",
	KwImpl: "impl", KwIn: "in", KwLet: "let", KwMatch: "match", KwPub: "pub",
	KwReturn: "return", KwSelf: "self", KwStruct: "struct", KwTrait: "trait",
	KwTrue: "true", KwUse: "use", KwVar: "var", KwWhen: "when", KwWhile: "while",
	HashBracket: "#[", ColonColon: "::", DotDot: "..", Arrow: "->", EqEq: "==",
	NotEq: "!=", LessEq: "<=", GreaterEq: ">=", AndAnd: "&&", OrOr: "||",
	Shl: "<<", Shr: ">>", PlusPlus: "++", LParen: "(", RParen: ")",
	LBracket: "[", RBracket: "]", LBrace: "{", RBrace: "}", Comma: ",",
	Semi: ";", Colon: ":", Dot: ".", Pipe: "|", Plus: "+", Minus: "-",
	Star: "*", Slash: "/", Percent: "%", Bang: "!", Tilde: "~", Amp: "&",
	Caret: "^", Less: "<", Greater: ">", Assign: "=",
}

// String returns a human-readable name for the kind.
func (k Kind) String() string { return kindNames[k] }

var keywordKinds = map[string]Kind{
	"as": KwAs, "break": KwBreak, "continue": KwContinue, "else": KwElse,
	"enum": KwEnum, "false": KwFalse, "fn": KwFn, "for": KwFor, "if": KwIf,
	"impl": KwImpl, "in": KwIn, "let": KwLet, "match": KwMatch, "pub": KwPub,
	"return": KwReturn, "self": KwSelf, "struct": KwStruct, "trait": KwTrait,
	"true": KwTrue, "use": KwUse, "var": KwVar, "when": KwWhen, "while": KwWhile,
}

// Token is one lexical token with its position.
type Token struct {
	Kind  Kind
	Pos   diag.Pos
	Text  string  // Ident: the name
	Int   int64   // Int: the value; Char: the scalar value
	Float float64 // Float: the value
	Str   []rune  // Str: the decoded scalar values
}
