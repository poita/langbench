// Tokeniser for Datalog source text.
#pragma once

#include <cstdint>
#include <string>
#include <string_view>
#include <vector>

namespace datalog {

enum class TokenKind {
  Identifier,  // [a-z][a-z0-9_]*
  Variable,    // [A-Z][A-Za-z0-9_]*
  Anonymous,   // _
  Integer,     // -?[0-9]+
  Not,         // keyword `not`
  LParen, RParen, Comma, Dot,
  Implies,     // :-
  QueryMark,   // ?-
  Lt, Le, Gt, Ge, Eq, Ne,
  End
};

struct Token {
  TokenKind kind = TokenKind::End;
  std::string text;          // Identifier / Variable spelling
  std::int64_t integer = 0;  // Integer value
  int line = 1;
  int column = 1;
};

/// Splits `source` into tokens (the last one is always `End`), skipping
/// whitespace and `%` comments. Throws ParseError on an illegal character.
std::vector<Token> tokenize(std::string_view source);

/// Human-readable token name for error messages.
std::string describe(const Token& token);

}  // namespace datalog
