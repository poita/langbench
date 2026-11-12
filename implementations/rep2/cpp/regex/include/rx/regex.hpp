// Public entry point of the rx library.
//
//   rx::Regex re("(a|ab)(c|bcd)(d*)");
//   if (auto m = re.search("abcd")) {
//     m->begin, m->end;          // 0, 4
//     m->group(2);               // Span{1, 4}
//   }
//
// Semantics: Perl-style leftmost, greedy, ordered-choice backtracking over a
// small syntax (literals, `.`, `^`, `$`, classes, \d \w \s and complements,
// groups, `|`, `* + ? {n} {n,} {n,m}`); every group captures. The first match
// only is reported. See README.md for the full grammar.
#pragma once

#include <memory>
#include <optional>
#include <string_view>

#include "rx/error.hpp"
#include "rx/matcher.hpp"
#include "rx/parser.hpp"
#include "rx/program.hpp"

namespace rx {

/// A compiled regular expression. Immutable and cheap to copy (the program is
/// shared); safe to use from several threads as long as each thread uses its
/// own Matcher (Regex::search creates a temporary one per call).
class Regex {
 public:
  /// \throws ParseError if `pattern` is invalid; Error if it expands to too
  /// many instructions.
  explicit Regex(std::string_view pattern);

  /// Number of capture groups in the pattern.
  std::size_t group_count() const { return program_->group_count; }

  /// Finds the first match in `subject`, or std::nullopt.
  /// For many subjects, prefer a long-lived Matcher built from program().
  std::optional<Match> search(std::string_view subject) const;

  const Program& program() const { return *program_; }

 private:
  std::shared_ptr<const Program> program_;
};

}  // namespace rx
