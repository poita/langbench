// Pass 1: lexing one module body into tokens (SPEC.md section 3).
#pragma once

#include <cstdint>
#include <string>
#include <vector>

namespace langvm {

struct Pos {
  int line = 0;
  int col = 0;
};

enum class Tok : uint8_t {
  Eof, Ident, Int, Float, Str, Char, Underscore,
  // keywords
  KwAs, KwBreak, KwContinue, KwElse, KwEnum, KwFalse, KwFn, KwFor, KwIf, KwImpl, KwIn, KwLet,
  KwMatch, KwPub, KwReturn, KwSelf, KwStruct, KwTrait, KwTrue, KwUse, KwVar, KwWhen, KwWhile,
  // punctuation
  HashBracket, ColonColon, DotDot, Arrow, EqEq, NotEq, LessEq, GreaterEq, AndAnd, OrOr, Shl, Shr,
  PlusPlus, LParen, RParen, LBracket, RBracket, LBrace, RBrace, Comma, Semi, Colon, Dot, Pipe,
  Plus, Minus, Star, Slash, Percent, Bang, Tilde, Amp, Caret, Less, Greater, Assign
};

struct Token {
  Tok kind = Tok::Eof;
  Pos pos;
  std::string text;       // identifiers
  int64_t intVal = 0;     // integer literals; char literals (scalar value)
  double floatVal = 0;    // float literals
  std::u32string strVal;  // string literals
};

// Lexes `text`; the returned list ends with an Eof token positioned one past
// the last character. Throws CompileError on the first ill-formed token.
std::vector<Token> lex(const std::u32string& text);

}  // namespace langvm
