#pragma once
/// \file lexer.hpp
/// Tokeniser for the command language (spec 6.1).

#include <string>
#include <string_view>
#include <vector>

namespace tessera {

struct Token {
  enum class Type { Word, Int, String, Punct, Op };
  Type type = Type::Word;
  /// Word: its spelling. Int: the digits with an optional leading `-`.
  /// String: the decoded UTF-8 bytes. Punct / Op: the symbol.
  std::string text;
  /// String only: an unpaired surrogate escape; reported as `bad-utf8` when the
  /// parser actually consumes the token.
  bool bad_utf8 = false;

  bool is_punct(char c) const { return type == Type::Punct && text.size() == 1 && text[0] == c; }
  bool is_word(std::string_view w) const { return type == Type::Word && text == w; }
};

/// Tokenises a whole line. Throws `Error(Syntax)` on any lexical problem.
std::vector<Token> lex(std::string_view line);

}  // namespace tessera
