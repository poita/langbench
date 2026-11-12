// KBL lexical analysis: comment stripping, logical lines, tokens.
#pragma once

#include <cstdint>
#include <string>
#include <string_view>
#include <vector>

namespace kiln {

enum class TokenKind { Ident, Int, Str, Punct, Op };

struct Token {
  TokenKind kind = TokenKind::Punct;
  /// Identifier / punctuation / operator spelling; for `Str` the raw literal
  /// including its quotes; for `Int` the digits.
  std::string text;
  std::int64_t int_value = 0;

  bool is_punct(std::string_view s) const { return kind == TokenKind::Punct && text == s; }
  bool is_op(std::string_view s) const { return kind == TokenKind::Op && text == s; }
  bool is_ident(std::string_view s) const { return kind == TokenKind::Ident && text == s; }
};

/// A logical line: physical lines joined by bracket depth, tokenised.
struct LogicalLine {
  int line = 0;  ///< 1-based number of the first physical line
  std::vector<Token> tokens;
};

/// Thrown by the token-level routines; the caller attributes it to a line.
struct SyntaxError {};

/// Lexes a whole build file (stages 1-3). Throws `Error(E_PARSE)` for the first
/// lexical error, reported as `<file>:<line>`.
std::vector<LogicalLine> lex(std::string_view source, std::string_view file);

/// Tokenises a fragment (an interpolation body). Throws `SyntaxError`.
std::vector<Token> tokenize(std::string_view text);

/// Given `s[pos]` is a quote, returns the index just past the literal's closing
/// quote, or `npos` when the literal is unterminated.
std::size_t scan_literal(std::string_view s, std::size_t pos);

/// Given `s[pos]` is the `{` that opens an interpolation, returns the index of
/// its closing `}`, or `npos` when unterminated.
std::size_t scan_interpolation(std::string_view s, std::size_t pos);

bool is_reserved_word(std::string_view s);

}  // namespace kiln
