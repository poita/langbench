#pragma once
/// \file regex.hpp
/// Public API of the regex engine: a backtracking matcher for a Perl-like
/// subset (literals, `.`, classes, `\d\w\s` and complements, `^` `$`,
/// capturing groups, alternation and greedy quantifiers `* + ? {n} {n,}
/// {n,m}`), with leftmost, greedy, ordered-choice semantics.
///
/// \code
///   regex::Regex re("(a|ab)(c|bcd)(d*)");
///   if (auto m = re.search("abcd")) {
///     // m->span == {0,4}; m->groups[0] == Span{0,1}; ...
///   }
/// \endcode

#include <memory>
#include <optional>
#include <string_view>

#include "regex/error.hpp"
#include "regex/matcher.hpp"

namespace regex {

/// A compiled pattern. Immutable after construction, cheap to copy and safe
/// to share between threads (searching through Regex::search allocates its
/// own scratch space).
class Regex {
 public:
  /// Compiles \p pattern. Throws ParseError for invalid syntax and Error if
  /// the pattern is too large once counted quantifiers are expanded.
  explicit Regex(std::string_view pattern);

  /// Number of capture groups in the pattern.
  int group_count() const noexcept;

  /// Finds the first match in \p subject: the leftmost start position at
  /// which the pattern matches, with the match chosen by greedy,
  /// ordered-choice backtracking. Returns nullopt if there is none.
  std::optional<Match> search(std::string_view subject) const;

  /// The compiled program (for Matcher).
  const Program& program() const noexcept { return *program_; }

 private:
  std::shared_ptr<const Program> program_;
};

}  // namespace regex
