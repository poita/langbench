// KBL lexing: comment stripping, logical lines, tokens.
#pragma once

#include <string>
#include <string_view>
#include <vector>

namespace kiln {

/// Thrown internally for any lexical or grammatical violation; the file-level
/// entry points convert it into `E_PARSE <file>:<line>`.
struct SyntaxError {};

struct Token {
  enum Kind { Ident, Int, Str, Sym };
  Kind kind = Sym;
  /// Identifier text, integer digits, symbol spelling, or (for strings) the raw
  /// text between the quotes.
  std::string text;
  bool doubleQuoted = false;  // Str only

  bool isSym(std::string_view s) const noexcept { return kind == Sym && text == s; }
  bool isIdent(std::string_view s) const noexcept { return kind == Ident && text == s; }
};

/// One logical line of a build file, tokenised.
struct LogicalLine {
  int line = 0;  // 1-based number of the first physical line
  std::vector<Token> tokens;
};

/// Runs stages 1-3 over a whole build file. Throws `Error("E_PARSE", "file:line")`
/// for the earliest lexical error.
std::vector<LogicalLine> lexBuildFile(std::string_view source, const std::string& file);

/// Tokenises a piece of text with no comment handling (used for interpolation
/// bodies). Throws `SyntaxError`.
std::vector<Token> tokenize(std::string_view text);

// Literal scanners shared by every stage. Each takes the index just after the
// opening delimiter and returns the index just past the closing one. They
// throw `SyntaxError` when the literal is unterminated.
std::size_t skipSingleQuoted(std::string_view s, std::size_t i);
std::size_t skipDoubleQuoted(std::string_view s, std::size_t i);
/// `i` is just after the `{` that opens an interpolation region.
std::size_t skipInterpolation(std::string_view s, std::size_t i);

}  // namespace kiln
