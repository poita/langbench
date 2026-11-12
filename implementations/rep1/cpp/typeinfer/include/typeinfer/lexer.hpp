// Tokeniser for the ML-like source language.
#pragma once

#include <cstddef>
#include <string_view>
#include <vector>

namespace typeinfer {

enum class TokenKind {
    End,
    Int,
    Ident,
    // keywords
    KwLet, KwRec, KwIn, KwFun, KwIf, KwThen, KwElse, KwTrue, KwFalse,
    // symbols
    SemiSemi, Arrow, ColonColon, Le, Ge, AndAnd, OrOr,
    LParen, RParen, LBracket, RBracket, Semi, Comma,
    Plus, Minus, Star, Slash, Eq, Lt, Gt,
};

struct Token {
    TokenKind kind;
    std::string_view text;  ///< View into the source text.
    std::size_t offset;     ///< Byte offset of the token in the source.
};

/// Splits `source` into tokens; the result always ends with a `TokenKind::End`
/// token. Throws `ParseError` on a character that starts no token.
/// The tokens refer to `source`, which must outlive them.
std::vector<Token> tokenize(std::string_view source);

}  // namespace typeinfer
