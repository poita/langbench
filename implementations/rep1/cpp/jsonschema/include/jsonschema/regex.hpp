// A small ECMA-262 style regular-expression engine for membership tests.
#pragma once

#include <memory>
#include <stdexcept>
#include <string>
#include <string_view>

namespace jsonschema {

/// Thrown by Regex::compile() for a pattern outside the supported syntax.
class RegexError : public std::runtime_error {
 public:
  using std::runtime_error::runtime_error;
};

/// A compiled regular expression that answers one question: does the pattern
/// match anywhere in a string?
///
/// Supported syntax: alternation, grouping `(...)` and `(?:...)`, the
/// quantifiers `* + ? {n} {n,} {n,m}` (and their lazy forms, which do not
/// change the answer), `.`, `^`, `$`, `\b`, `\B`, character classes with
/// ranges and the escapes `\d \D \w \W \s \S`, and the character escapes
/// `\n \r \t \f \v \0 \xHH \uHHHH \cX` plus escaped punctuation. Matching is
/// over Unicode code points and there are no flags.
///
/// The matcher simulates the pattern's NFA, so a search takes O(P * L) time for
/// a pattern of size P and a subject of L code points, with no backtracking.
/// A Regex is immutable and cheap to copy; concurrent searches are safe.
class Regex {
 public:
  /// Compiles `pattern` (UTF-8). Throws RegexError on a syntax error.
  static Regex compile(std::string_view pattern);

  /// True if the pattern matches somewhere in `subject` (UTF-8).
  bool search(std::string_view subject) const;
  /// Same, for a subject that is already decoded into code points.
  bool search(const std::u32string& subject) const;

  struct Program;  // implementation detail

 private:
  std::shared_ptr<const Program> program_;
};

}  // namespace jsonschema
