#pragma once
/// \file lexer.hpp
/// Splits template source into text, `{{ }}` and `{% %}` items, applying
/// whitespace control and tokenizing the tag contents.

#include <cstdint>
#include <string>
#include <string_view>
#include <vector>

namespace jinjalite {

enum class TokenKind { Name, Int, Float, String, Op };

/// A token inside a tag. For strings `text` holds the unescaped contents.
struct Token {
  TokenKind kind = TokenKind::Op;
  std::string text;
  int64_t int_value = 0;
  double float_value = 0;

  bool is_op(std::string_view op) const { return kind == TokenKind::Op && text == op; }
  bool is_name(std::string_view n) const { return kind == TokenKind::Name && text == n; }
};

/// One top-level piece of a template.
struct Item {
  enum class Kind { Text, Print, Statement };
  Kind kind = Kind::Text;
  std::string text;            ///< Text items: the (whitespace-trimmed) text
  std::vector<Token> tokens;   ///< Print/Statement items: the tag's tokens
};

/// Lexes a whole template. Comments are dropped (their whitespace control
/// still applies) and empty text items are omitted. Throws `Error(Syntax)`.
std::vector<Item> lex_template(std::string_view source);

/// True for the six whitespace characters of the language
/// (space, TAB, LF, CR, FF, VT).
inline bool is_template_space(char c) {
  return c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\f' || c == '\v';
}

}  // namespace jinjalite
