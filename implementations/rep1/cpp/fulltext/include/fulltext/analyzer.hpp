/// @file analyzer.hpp
/// Text analysis: tokenise, fold, stem. Documents and queries go through the
/// same analysis.
///
/// Token characters are ASCII digits and letters, Latin-1/Latin Extended
/// letters, Greek and Cyrillic (see SPEC.md). A token is a run of token
/// characters optionally continued by single apostrophes (U+0027 or U+2019)
/// that sit between two token characters. Folding deletes apostrophes and
/// maps `A`-`Z` to `a`-`z` (nothing else). A token made only of `a`-`z` is
/// then Porter-stemmed to give its *term*.
#pragma once

#include <cstddef>
#include <string>
#include <string_view>
#include <vector>

namespace fulltext {

/// Half-open byte range `[begin, end)` of a token in the original text.
struct Span {
  std::size_t begin;
  std::size_t end;
};

/// A fully analysed token.
struct Token {
  Span span;         ///< Where the token sits in the source text.
  std::string text;  ///< Folded token text (apostrophes removed, A-Z lowered).
  std::string term;  ///< Stemmed term (or `text` when it is not pure a-z).
};

/// Returns the byte spans of all tokens in `text`, in order.
std::vector<Span> tokenize(std::string_view text);

/// Folds a raw token: removes apostrophes and lower-cases ASCII letters.
std::string fold(std::string_view raw_token);

/// True when `folded` is one of the 33 stop words.
bool is_stop_word(std::string_view folded);

/// The term for a folded token: its Porter stem if it is pure `a`-`z`,
/// otherwise the folded text itself.
std::string term_for(std::string_view folded);

/// Tokenises, folds and stems `text`.
std::vector<Token> analyze(std::string_view text);

}  // namespace fulltext
