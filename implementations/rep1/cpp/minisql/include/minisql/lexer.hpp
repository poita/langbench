/// @file lexer.hpp
/// @brief Tokenizer and statement splitter.
#pragma once

#include <cstddef>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

namespace minisql {

enum class TokenKind {
  Identifier,  ///< lower-cased name (includes COUNT/SUM/MIN/MAX/AVG)
  Keyword,     ///< upper-cased reserved word
  Integer,     ///< decimal digits
  String,      ///< unescaped contents of a string literal
  Symbol,      ///< operator or punctuation except ';'
  Semicolon,   ///< statement terminator
  Invalid,     ///< bad character or unterminated string literal
};

struct Token {
  TokenKind kind;
  std::string text;
  std::size_t offset;  ///< byte offset in the input
};

/// Tokenizes the whole input. Never throws: bad input yields `Invalid`
/// tokens (an unterminated string consumes the rest of the input).
std::vector<Token> tokenize(std::string_view input);

/// Half-open range `[begin, end)` of token indices forming one statement.
using TokenRange = std::pair<std::size_t, std::size_t>;

/// Splits at `;` tokens; empty statements are dropped and a final statement
/// without `;` is kept.
std::vector<TokenRange> split_statements(const std::vector<Token>& tokens);

/// True if `upper_case_word` is a reserved keyword.
bool is_keyword(const std::string& upper_case_word);

}  // namespace minisql
